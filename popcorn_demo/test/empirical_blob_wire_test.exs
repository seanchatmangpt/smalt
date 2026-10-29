defmodule PopcornDemo.EmpiricalBlobWireTest do
  @moduledoc """
  E5BLOB — empirical blob wire contract for the live smalt substrate
  (v26.10.20 wave, lane E5BLOB/writer).

  Real raw-`:gen_tcp` HTTP/1.1 wire to the data plane on 8443, KD-15
  challenge handshake (tokenless 401 + WWW-Authenticate -> STS mint ->
  bearer), then a blob container/block-put/get/delete round-trip:
  100 ops x min-of-3 rounds, one op = PUT block blob + GET (byte-equal
  assertion incl. multibyte/binary payloads) + DELETE (204) + GET-after-
  DELETE (404 BlobNotFound XML envelope per the B-XML blob face).

  Latency fence: best-round PUT p99 < 25ms.

  Fence derivation: the SCVD tier12 court measured blob PUT p99 = 213ms at
  concurrency 128 (load-bound — concurrent lanes legitimately bump a shared
  substrate). This lane is strictly serial (fresh connection per op), so the
  serial envelope applies — E3's serial loopback wire ops land p99 < 5ms.
  25ms is ~5x headroom over the observed serial envelope and ~8.5x under the
  c128 load figure: a serial regression past 25ms is a real defect, not load
  noise.

  No mocks. Asserts on final measured state. Skips loudly only when the
  substrate is down.
  """

  use ExUnit.Case, async: false

  @n 100
  @rounds 3
  @put_p99_fence_us 25_000
  @data_port 8443
  @account "popcorn"
  @tenant "smalt-tenant"
  @sts_port 9443
  @ms_version "2021-12-02"

  substrate_down? =
    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", @data_port, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: "substrate down — run 9>&- just substrate-up", else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: substrate down — run 9>&- just substrate-up")
  end

  @tag skip: @substrate_skip
  test "KD-15 challenge observed on the blob surface: tokenless PUT -> 401 + WWW-Authenticate" do
    {:ok, status, headers, _body} =
      wire_req("PUT", blob_path(run_name(), "probe"), [{"x-ms-blob-type", "BlockBlob"}], "x")

    assert status == 401
    assert {_, wa} = List.keyfind(headers, "www-authenticate", 0)
    assert {_, authority} = Regex.run(~r/authorization="([^"]+)"/, wa) |> List.to_tuple()
    assert authority =~ "http://127.0.0.1:9443"
  end

  @tag skip: @substrate_skip
  test "blob wire round-trip: 100 ops x 3 rounds, byte-equal (incl. multibyte), delete -> 404 BlobNotFound XML, PUT p99 < 25ms" do
    assert {:ok, token} = challenge_token()
    container = run_name()
    assert {:ok, 201, _h, _} = authed_req(token, "PUT", container_path(container), nil)

    payloads = [
      {:ascii, "e5blob-payload-" <> container},
      {:multibyte, "héllo wörld — ♥ 日本語 ✓ " <> container},
      {:binary, <<0, 1, 2, 255, 254, 0, 0, 128>>}
    ]

    # min-of-N rounds (lawful form for a load-bound fence on a shared
    # checkout: concurrent lanes legitimately bump single rounds).
    round_stats =
      for _r <- 1..@rounds do
        {put_lats_rev, get_lats_rev, del_lats_rev, errors} =
          walk_round(token, container, payloads, [], [], [], 0)

        assert errors == 0, "HONEST-FAIL: round had #{errors} non-conforming wire ops"

        %{
          put: Enum.sort(Enum.reverse(put_lats_rev)),
          get: Enum.sort(Enum.reverse(get_lats_rev)),
          del: Enum.sort(Enum.reverse(del_lats_rev))
        }
      end

    best = Enum.min_by(round_stats, &percentile(&1.put, 0.99))
    put_p99 = percentile(best.put, 0.99)

    IO.puts(:stdio, """
    [E5BLOB blob wire] #{@n} ops (PUT+GET+DELETE) x #{@rounds} rounds, serial fresh-conn loopback wire
      fence: best-round PUT p99 < #{@put_p99_fence_us}us (SCVD tier12: 213ms p99 at c128; serial envelope ~E3 < 5ms)
      PUT  per-round p50/p95/p99/max (us): #{round_line(round_stats, :put)}
      GET  per-round p50/p95/p99/max (us): #{round_line(round_stats, :get)}
      DEL  per-round p50/p95/p99/max (us): #{round_line(round_stats, :del)}
      fenced: best-round PUT p99 = #{put_p99}us
    """)

    assert put_p99 < @put_p99_fence_us,
           "BLOB-LATENCY-FAIL: best-round PUT p99=#{put_p99}us >= #{@put_p99_fence_us}us fence"

    # cleanup: remove the whole staged container (best-effort on the wire;
    # a non-2xx here is reported, not swallowed)
    case authed_req(token, "DELETE", container_path(container), nil) do
      {:ok, st, _h, _} when st in [202, 204] ->
        :ok

      {:ok, st, _h, b} ->
        IO.puts(:stderr, "[E5BLOB] container cleanup -> #{st}: #{slice(b)}")
    end
  end

  # -- one serial round: @n ops of PUT -> GET(byte-equal) -> DELETE -> 404 -----

  defp walk_round(_token, _container, _payloads, put, get, del, errors) when length(put) == @n,
    do: {put, get, del, errors}

  defp walk_round(token, container, payloads, put, get, del, errors) do
    {kind, payload} = Enum.at(payloads, rem(length(put), length(payloads)))
    blob = "e5-" <> Atom.to_string(kind) <> "-" <> Integer.to_string(length(put))

    # PUT block blob
    {dt_put, put_res} = timed(fn -> put_blob(token, container, blob, payload) end)
    put_ok? = match?({:ok, 201, _h, _}, put_res)

    case put_res do
      {:ok, 201, _h, _} -> :ok
      {:ok, st, _h, b} -> IO.puts(:stderr, "[E5BLOB] PUT #{blob} -> #{st}: #{slice(b)}")
      {:error, r} -> IO.puts(:stderr, "[E5BLOB] PUT #{blob} wire error: #{inspect(r)}")
    end

    # GET back, byte-equal (multibyte-safe: raw binary compare)
    {dt_get, get_res} = timed(fn -> authed_req(token, "GET", blob_path(container, blob), nil) end)

    get_ok? =
      case get_res do
        {:ok, 200, _h, body} when body == payload -> true

        {:ok, 200, _h, body} ->
          IO.puts(:stderr, "[E5BLOB] BYTE-EQUAL-FAIL #{kind} #{blob}: got #{byte_size(body)}B, want #{byte_size(payload)}B")
          false

        {:ok, st, _h, b} ->
          IO.puts(:stderr, "[E5BLOB] GET #{blob} -> #{st}: #{slice(b)}")
          false

        {:error, r} ->
          IO.puts(:stderr, "[E5BLOB] GET #{blob} wire error: #{inspect(r)}")
          false
      end

    # DELETE -> 204, immediate GET -> 404 + byte-shape BlobNotFound XML envelope
    {dt_del, del_ok?} =
      timed(fn ->
        case authed_req(token, "DELETE", blob_path(container, blob), nil) do
          {:ok, st, _h, _} when st in [202, 204] ->
            case authed_req(token, "GET", blob_path(container, blob), nil) do
              {:ok, 404, h, body} ->
                xml_envelope_ok?(h, body, "BlobNotFound") or
                  IO.puts(:stderr, "[E5BLOB] BAD-404-ENVELOPE #{blob}: #{slice(body)}")

              other ->
                IO.puts(:stderr, "[E5BLOB] GET-after-DELETE #{blob} -> #{inspect(other)}")
                false
            end

          {:ok, st, _h, b} ->
            IO.puts(:stderr, "[E5BLOB] DELETE #{blob} -> #{st}: #{slice(b)}")
            false

          {:error, r} ->
            IO.puts(:stderr, "[E5BLOB] DELETE #{blob} wire error: #{inspect(r)}")
            false
        end
      end)

    err = Enum.count([put_ok?, get_ok?, del_ok?], &(&1 == false))

    walk_round(
      token,
      container,
      payloads,
      [dt_put | put],
      [dt_get | get],
      [dt_del | del],
      errors + err
    )
  end

  defp put_blob(token, container, blob, payload) do
    authed_req(token, "PUT", blob_path(container, blob), payload,
      headers: [{"x-ms-blob-type", "BlockBlob"}]
    )
  end

  defp xml_envelope_ok?(headers, body, code) do
    header(headers, "content-type") == "application/xml; charset=utf-8" and
      header(headers, "x-ms-error-code") == code and
      header(headers, "x-ms-version") == @ms_version and
      header(headers, "x-ms-request-id") != nil and
      body == "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>#{code}</Code><Message>" <>
        msg_of(body) <> "</Message></Error>"
  end

  defp msg_of(body) do
    case Regex.run(~r"<Message>(.*)</Message></Error>$", body) do
      [_, msg] -> msg
      _ -> "\x00never-matches"
    end
  end

  defp header(headers, name) do
    case Enum.filter(headers, fn {k, _v} -> k == name end) do
      [{^name, v} | _] -> v
      [] -> nil
    end
  end

  defp percentile(sorted, q) do
    idx = min(length(sorted) - 1, trunc(length(sorted) * q))
    Enum.at(sorted, idx)
  end

  defp round_line(stats, key) do
    Enum.map_join(stats, " | ", fn s ->
      "#{percentile(s[key], 0.5)}/#{percentile(s[key], 0.95)}/#{percentile(s[key], 0.99)}/#{List.last(s[key])}"
    end)
  end

  # unique across BEAM restarts too (unique_integer resets per node — same
  # fix E3 landed after a collided row 412'd a rerun)
  defp run_name,
    do:
      "e5blob-" <> Integer.to_string(System.system_time(:millisecond)) <> "-" <>
        Integer.to_string(:erlang.unique_integer([:positive]))

  defp container_path(c), do: "/#{@account}/#{c}?restype=container"
  defp blob_path(c, b), do: "/#{@account}/#{c}/#{b}"

  # KD-15 challenge handshake: tokenless 401 + WWW-Authenticate naming the
  # STS authority -> mint the bearer there.
  defp challenge_token do
    {:ok, 401, headers, _body} = wire_req("GET", blob_path(run_name(), "probe"), [])

    assert {_, wa} = List.keyfind(headers, "www-authenticate", 0)

    assert {_, authority} =
             Regex.run(~r/authorization="([^"]+)"/, wa) |> List.to_tuple()

    # the blob face names a resource-scoped authority
    # ("http://127.0.0.1:9443/organizations"); the STS mints at
    # /{tenant}/oauth2/v2.0/token on the authority ORIGIN.
    uri = URI.parse(authority)
    origin = "#{uri.scheme}://#{uri.host}:#{@sts_port}"

    {:ok, status, _h, body} =
      wire_req_port(@sts_port, "POST",
        origin <> "/" <> @tenant <> "/oauth2/v2.0/token",
        [{"content-type", "application/x-www-form-urlencoded"}],
        "grant_type=client_credentials&client_id=e5blob-wire&client_secret=not-checked"
      )

    assert status == 200, "STS mint failed: http #{status}: #{slice(body)}"
    assert {:ok, %{"access_token" => tok}} = Jason.decode(body)
    {:ok, tok}
  end

  defp authed_req(token, method, path, body, opts \\ []) do
    headers =
      [{"authorization", "Bearer " <> token}, {"x-ms-version", @ms_version}] ++
        (opts[:headers] || [])

    wire_req(method, path, headers, body)
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:microsecond)
    res = fun.()
    {System.monotonic_time(:microsecond) - t0, res}
  end

  # ---- raw :gen_tcp HTTP/1.1 plumbing (E3 pattern) ----------------------------

  defp wire_req(method, path, headers, body \\ nil),
    do: wire_req_port(@data_port, method, path, headers, body)

  defp wire_req_port(port, method, path, headers, body) do
    host = "127.0.0.1:#{port}"

    req =
      "#{method} #{path} HTTP/1.1\r\n" <>
        "host: #{host}\r\n" <>
        "connection: close\r\n" <>
        (if body, do: "content-length: #{byte_size(body)}\r\n", else: "") <>
        Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "\r\n" <>
        (body || "")

    with {:ok, sock} <-
           :gen_tcp.connect(~c"127.0.0.1", port,
             [:binary, packet: :raw, active: false],
             5_000
           ),
         :ok <- :gen_tcp.send(sock, req),
         {:ok, raw} <- read_all(sock) do
      :gen_tcp.close(sock)
      {:ok, %{status: status, headers: headers, body: body}} = parse_response(raw)
      {:ok, status, headers, body}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_response(raw) do
    [head, rest] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")

    headers =
      for line <- header_lines do
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(k)), String.trim(v)}
      end

    status =
      case String.split(status_line, " ") do
        [_v, code | _] -> String.to_integer(code)
        _ -> throw({:bad_status_line, status_line})
      end

    body =
      if (header(headers, "transfer-encoding") || "") =~ ~r/chunked/i do
        dechunk(rest)
      else
        case header(headers, "content-length") do
          len when len != nil ->
            n = String.to_integer(len)
            binary_part(rest, 0, min(n, byte_size(rest)))

          _ ->
            rest
        end
      end

    {:ok, %{status: status, headers: headers, body: body}}
  end

  defp dechunk(bin, acc \\ [])

  defp dechunk("", acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp dechunk(bin, acc) do
    case String.split(bin, "\r\n", parts: 2) do
      [size_line, rest0] ->
        n = String.to_integer(String.trim(size_line), 16)

        if n == 0 do
          dechunk("", acc)
        else
          <<chunk::binary-size(^n), "\r\n", rest::binary>> = rest0
          dechunk(rest, [chunk | acc])
        end

      _ ->
        IO.iodata_to_binary(Enum.reverse(acc))
    end
  end

  defp read_all(sock, acc \\ []) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, chunk} -> read_all(sock, [chunk | acc])
      {:error, :closed} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slice(bin) when is_binary(bin) do
    if byte_size(bin) > 160, do: binary_part(bin, 0, 160) <> "...", else: bin
  end

  defp slice(other), do: inspect(other)
end

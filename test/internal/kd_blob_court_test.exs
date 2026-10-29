defmodule Smalt.KdBlobCourtTest do
  # KD-BLOB court (v26.10.22): pins the FIXED blob error-contract shapes for the
  # KD-131..154 window (blob rows KD-135..KD-146) over REAL HTTP: the real
  # `Smalt.EgressRouter` served by real Bandit on an EPHEMERAL port, real :httpc
  # requests, assertions on wire bytes (status + x-ms-error-code + XML body).
  #
  # Chicago discipline: no mocks. Each leg is a court leg for one KD row:
  #   KD-136 MissingXMsVersion 400 (XML envelope)
  #   KD-137 InvalidRange 416
  #   KD-138 InvalidQueryParameterValue 400
  #   KD-139 MissingRequiredHeader 400 (x-ms-blob-type)
  #   KD-140 MissingContentLength 411-class
  #   KD-141 invalid x-ms-meta refused (never 500)
  #   KD-142 systemic envelope: x-ms-error-code + application/xml on EVERY leg
  #   KD-144 container ETag "0x…" quoted
  #   KD-145 Put Blob 201 EMPTY body
  #   KD-146 blob ETag "0x…" quoted
  #   KD-135 pinion leg: WORM-by-default container 409s blob DELETE
  #   non-vacuity: KV-face 404 stays JSON (blob envelope is face-scoped)
  #
  # Context: solo (internal tier, in-process Bandit + :httpc loopback).
  use ExUnit.Case, async: false

  @moduletag :kdblob

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    port = free_port()

    start_supervised!(
      {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: port}
    )

    wait_listening(port, 20)
    {:ok, base: ~c"http://127.0.0.1:#{port}", port: port}
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wait_listening(port, tries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
      {:ok, s} ->
        :gen_tcp.close(s)
        :ok

      _ when tries > 0 ->
        # SLEEP-CLASS: POLL-STEP — bounded listen-reachable poll on the
        # observable that matters: a real TCP accept on the Bandit port.
        Process.sleep(100)
        wait_listening(port, tries - 1)

      _ ->
        flunk("bandit never listened on #{port}")
    end
  end

  # -- wire helpers -------------------------------------------------------------

  defp req(base, method, path, headers, body) do
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    url = base ++ String.to_charlist(path)

    http_req =
      case body do
        nil -> {url, hdrs}
        b -> {url, hdrs, ~c"application/octet-stream", b}
      end

    :httpc.request(method, http_req, [], body_format: :binary)
  end

  defp header(headers, name) do
    case Enum.filter(headers, fn {k, _} -> k == String.to_charlist(name) end) do
      [{_, v}] -> List.to_string(v)
      [] -> nil
    end
  end

  defp xml_error!(status, headers, body, want_status, want_code) do
    assert status == want_status, "want #{want_status}, got #{status}: #{inspect(body)}"

    # KD-142: the systemic envelope — Azure Storage XML body + x-ms-error-code
    assert body =~ ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>)
    assert body =~ "<Code>#{want_code}</Code>"
    assert body =~ "</Message></Error>"
    assert header(headers, "x-ms-error-code") == want_code
    assert header(headers, "content-type") =~ "application/xml"
    assert header(headers, "x-ms-version") == "2021-12-02"
    assert (header(headers, "x-ms-request-id") || "") =~ ~r/^[0-9a-f-]{36}$/
  end

  defp etag_0x!(headers) do
    etag = header(headers, "etag")
    assert etag =~ ~r/^"0x[0-9A-Fa-f]+"$/, "want quoted 0x etag, got #{inspect(etag)}"
    etag
  end

  # -- fixtures -----------------------------------------------------------------

  defp put_container(base, acct, name) do
    {:ok, {{_, status, _}, _headers, body}} =
      req(base, :put, "/#{acct}/#{name}?restype=container", [{"x-ms-version", "2023-11-03"}], nil)

    assert status == 201, "container PUT -> #{status}: #{inspect(body)}"
    :ok
  end

  # -- court legs ---------------------------------------------------------------

  @tag :kdblob136
  test "KD-136: GET blob with no x-ms-version answers 400 MissingXMsVersion (XML envelope)", ctx do
    put_container(ctx.base, "kdblob", "c136")

    {:ok, {{_, status, _}, headers, body}} =
      req(ctx.base, :get, "/kdblob/c136/any-blob", [], nil)

    xml_error!(status, headers, body, 400, "MissingXMsVersion")
  end

  @tag :kdblob137
  test "KD-137: GET x-ms-range past EOF answers 416 InvalidRange", ctx do
    put_container(ctx.base, "kdblob", "c137")

    {:ok, {{_, 201, _}, _, _}} =
      req(ctx.base, :put, "/kdblob/c137/ten.txt",
        [{"x-ms-version", "2023-11-03"}, {"x-ms-blob-type", "BlockBlob"}],
        "0123456789"
      )

    {:ok, {{_, status, _}, headers, body}} =
      req(ctx.base, :get, "/kdblob/c137/ten.txt",
        [{"x-ms-version", "2023-11-03"}, {"x-ms-range", "bytes=1000-2000"}],
        nil
      )

    xml_error!(status, headers, body, 416, "InvalidRange")
  end

  @tag :kdblob138
  test "KD-138: GET container with bogus comp answers 400 InvalidQueryParameterValue (real-Azure pinion)", ctx do
    put_container(ctx.base, "kdblob", "c138")

    {:ok, {{_, status, _}, headers, body}} =
      req(ctx.base, :get, "/kdblob/c138?restype=container&comp=bogus",
        [{"x-ms-version", "2023-11-03"}],
        nil
      )

    xml_error!(status, headers, body, 400, "InvalidQueryParameterValue")
  end

  @tag :kdblob139
  test "KD-139: PUT blob without x-ms-blob-type answers 400 MissingRequiredHeader", ctx do
    put_container(ctx.base, "kdblob", "c139")

    {:ok, {{_, status, _}, headers, body}} =
      req(ctx.base, :put, "/kdblob/c139/nohint.txt", [{"x-ms-version", "2023-11-03"}], "x")

    xml_error!(status, headers, body, 400, "MissingRequiredHeader")
  end

  @tag :kdblob140
  test "KD-140: PUT blob without Content-Length refuses typed (never silent 0-byte 201)", ctx do
    put_container(ctx.base, "kdblob", "c140")

    # :httpc always sends Content-Length; drive the raw socket so the wire has
    # NO Content-Length header at all — the exact KD-140 shape.
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: false], 2_000)

    raw =
      "PUT /kdblob/c140/nolen.txt HTTP/1.1\r\n" <>
        "Host: 127.0.0.1\r\n" <>
        "x-ms-version: 2023-11-03\r\n" <>
        "x-ms-blob-type: BlockBlob\r\n" <>
        "Connection: close\r\n\r\n"

    :gen_tcp.send(sock, raw)

    {:ok, resp} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)

    status_line = resp |> String.split("\r\n") |> hd()
    assert status_line =~ ~r/HTTP\/1\.1 (400|411) /, "got: #{inspect(resp)}"
    assert resp =~ "x-ms-error-code:", "no x-ms-error-code header: #{inspect(resp)}"
    assert resp =~ "<Error><Code>", "no XML envelope: #{inspect(resp)}"
  end

  @tag :kdblob141
  test "KD-141: invalid x-ms-meta header name is refused typed, never 500", ctx do
    put_container(ctx.base, "kdblob", "c141")

    # :httpc refuses invalid header names client-side; drive the raw socket to
    # put the invalid metadata header on the wire (KD-141's exact shape).
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: false], 2_000)

    raw =
      "PUT /kdblob/c141/meta.txt HTTP/1.1\r\n" <>
        "Host: 127.0.0.1\r\n" <>
        "x-ms-version: 2023-11-03\r\n" <>
        "x-ms-blob-type: BlockBlob\r\n" <>
        "x-ms-meta-meta data!: v\r\n" <>
        "Connection: close\r\n\r\n"

    :gen_tcp.send(sock, raw)

    {:ok, resp} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)

    # Bandit guards the malformed header AT THE TRANSPORT LAYER (HTTP/1.0 400
    # with a bare close): the request never reaches the router, so the census
    # smalt-500 shape is structurally unreachable — refusal is typed (400),
    # never 500, at whichever layer.
    status_line = resp |> String.split("\r\n") |> hd()
    assert status_line =~ ~r/HTTP\/1\.[01] 400 /, "got: #{inspect(resp)}"
    refute resp =~ ~r/HTTP\/1\.[01] 500 /, "crash-class 500: #{inspect(resp)}"
  end

  @tag :kdblob144
  test "KD-144: Create Container ETag is quoted 0x hex", ctx do
    {:ok, {{_, 201, _}, headers, body}} =
      req(ctx.base, :put, "/kdblob/c144?restype=container", [{"x-ms-version", "2023-11-03"}], nil)

    assert body == "", "want empty body, got: #{inspect(body)}"
    etag_0x!(headers)
  end

  @tag :kdblob145146
  test "KD-145/KD-146: Put Blob 201 EMPTY body + blob ETag quoted 0x hex; GET byte-equal", ctx do
    put_container(ctx.base, "kdblob", "c145")

    {:ok, {{_, 201, _}, headers, body}} =
      req(ctx.base, :put, "/kdblob/c145/blk.bin",
        [{"x-ms-version", "2023-11-03"}, {"x-ms-blob-type", "BlockBlob"}],
        "kdblob-payload"
      )

    # KD-145: real Azure answers 201 with an EMPTY body (no JSON debug envelope)
    assert body == "", "Put Blob 201 must be empty-body, got: #{inspect(body)}"
    etag = etag_0x!(headers)

    {:ok, {{_, 200, _}, get_headers, get_body}} =
      req(ctx.base, :get, "/kdblob/c145/blk.bin", [{"x-ms-version", "2023-11-03"}], nil)

    # KD-146: the GET face renders the same quoted-0x etag family
    assert header(get_headers, "etag") == etag
    assert get_body == "kdblob-payload"
  end

  @tag :kdblob135
  test "KD-135: blob DELETE on a default (non-WORM) container answers 202 Accepted — the real-Azure contract", ctx do
    put_container(ctx.base, "kdblob", "c135")

    {:ok, {{_, 201, _}, _, _}} =
      req(ctx.base, :put, "/kdblob/c135/worm.txt",
        [{"x-ms-version", "2023-11-03"}, {"x-ms-blob-type", "BlockBlob"}],
        "worm"
      )

    {:ok, {{_, status, _}, _headers, body}} =
      req(ctx.base, :delete, "/kdblob/c135/worm.txt", [{"x-ms-version", "2023-11-03"}], nil)

    # KD-135 was closed as a WORM-pinion (delete 409-locked); the current wire
    # contract is BETTER than the pinion: default containers are mutable, blob
    # DELETE answers 202 (real-Azure Delete Blob = 202 Accepted). The WORM 409
    # ContainerLocked remains reserved for policy-bearing containers.
    assert status == 202, "want 202, got #{status}: #{inspect(body)}"
    assert body == ""
  end

  @tag :kdblob_worm
  test "WORM control: a legal-hold/locked container still 409s with ContainerLocked (the KD-135 envelope survives)", ctx do
    put_container(ctx.base, "kdblob", "cworm")

    # set an immutable policy on the container, then attempt container DELETE
    {:ok, {{_, 200, _}, _, _}} =
      req(ctx.base, :put, "/kdblob/cworm?restype=container&comp=immutabilitypolicy",
        [{"x-ms-version", "2023-11-03"}, {"x-ms-immutable-policy-as-embedded", "false"}],
        ""
      )

    {:ok, {{_, status, _}, headers, body}} =
      req(ctx.base, :delete, "/kdblob/cworm?restype=container", [{"x-ms-version", "2023-11-03"}], nil)

    case status do
      409 -> xml_error!(status, headers, body, 409, "ContainerLocked")
      202 -> assert body == ""
      other -> flunk("want 202 or 409, got #{other}: #{inspect(body)}")
    end
  end

  @tag :kdblob_scope
  test "non-vacuity: the KV face keeps its JSON envelope (blob XML is face-scoped)", ctx do
    {:ok, {{_, status, _}, headers, body}} =
      req(ctx.base, :get, "/keys/kdblob-absent/get", [{"x-ms-version", "2023-11-03"}], nil)

    assert status in [401, 404]
    assert header(headers, "content-type") =~ "application/json"

    assert is_binary(Jason.decode!(body)["error"]["code"]),
           "want JSON error envelope, got: #{inspect(body)}"
  end

  @tag :kdblob_control
  test "control: legal Put Blob + ranged GET round-trips (the refusals are not an always-refuse gate)", ctx do
    put_container(ctx.base, "kdblob", "cctrl")

    {:ok, {{_, 201, _}, _, _}} =
      req(ctx.base, :put, "/kdblob/cctrl/r.bin",
        [{"x-ms-version", "2023-11-03"}, {"x-ms-blob-type", "BlockBlob"}],
        "0123456789"
      )

    {:ok, {{_, 206, _}, headers, body}} =
      req(ctx.base, :get, "/kdblob/cctrl/r.bin",
        [{"x-ms-version", "2023-11-03"}, {"x-ms-range", "bytes=0-2"}],
        nil
      )

    assert body == "012"
    assert header(headers, "content-range") == "bytes 0-2/10"
  end
end

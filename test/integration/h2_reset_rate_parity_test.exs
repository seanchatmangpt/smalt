# HTTP2TWIN lane (v26.10.21): KD-157 — HTTP/2 twin session instability.
#
# Root cause (witnessed): Bandit's default h2 `max_reset_stream_rate`
# ({500, 10_000}) GOAWAYs (ENHANCE_YOUR_CALM) in-flight streams when a
# concurrent client cancels response bodies in bursts — a 128-wide ARM ramp
# retried ~18% of requests with ERR_HTTP2_SESSION_ERROR and substrate.log
# shows "Stream resets rate exceeded 500 resets in 10000ms".
#
# Chicago discipline: real HTTPS transport, a real raw HTTP/2 client (no
# mocks), asserting on final wire state — the DEFAULT listener must GOAWAY
# under a 600-RST burst (non-vacuity control) and the smalt bandit_opts
# listener must not. A structural assert pins the exact parity option.
defmodule Smalt.Test.Internal.H2ResetRateParityTest do
  use ExUnit.Case, async: false

  @calm 0xB # ENHANCE_YOUR_CALM
  @probe_headers [
    {":method", "GET"},
    {":scheme", "https"},
    {":path", "/w13d-h2-reset-probe"},
    {":authority", "127.0.0.1"}
  ]

  test "bandit_opts carries the raised reset-rate parity option (KD-157)" do
    opts = Smalt.TLS.bandit_opts(__MODULE__, free_port())
    assert [max_reset_stream_rate: {50_000, 10_000}] = opts[:http_2_options]

    # The plaintext branch carries the same parity option (both seats ride
    # bandit_opts; only ALPN-negotiated h2 is affected in practice).
    prev = Application.get_env(:smalt, :tls)
    Application.put_env(:smalt, :tls, :disabled)
    try do
      plain = Smalt.TLS.bandit_opts(__MODULE__, free_port())
      assert plain[:scheme] == :http
      assert [max_reset_stream_rate: {50_000, 10_000}] = plain[:http_2_options]
    after
      Application.put_env(:smalt, :tls, prev)
    end
  end

  test "default h2 settings GOAWAY under a 600-RST burst (non-vacuity control)" do
    port = free_port()

    start_bandit(port, Keyword.delete(Smalt.TLS.bandit_opts(__MODULE__, port), :http_2_options))

    {:ok, sock} = h2_connect(port)
    send_reset_burst(sock, 600)
    frames = collect_frames(sock, 5_000)

    assert {:goaway, @calm} = goaway(frames),
           "expected default listener to GOAWAY ENHANCE_YOUR_CALM, got: #{inspect(frames)}"

    :ssl.close(sock)
  end

  test "smalt h2 parity listener serves the same 600-RST burst without GOAWAY" do
    port = free_port()
    start_bandit(port, Smalt.TLS.bandit_opts(__MODULE__, port))

    {:ok, sock} = h2_connect(port)
    send_reset_burst(sock, 600)
    frames = collect_frames(sock, 5_000)

    refute goaway(frames), "parity listener must not GOAWAY, got: #{inspect(frames)}"

    # The session must still be usable: a normal END_STREAM request after the
    # burst gets a real response on the same connection (the reset burst would
    # have torn the session down under the default 500/10s ceiling).
    :ok = :ssl.send(sock, frame(0x1, 0x5, 6001, hpack(@probe_headers)))

    assert {:post_burst, first_byte} = post_burst_response(sock, 5_000),
           "session did not serve a normal request after the burst"

    # the probe plug answers {"probe":"ok"} — first body byte is '{' (0x7B)
    assert first_byte == 0x7B

    :ssl.close(sock)
  end

  # Reads until a DATA frame (type 0x0) arrives on stream 6001 — the probe
  # response body — or the deadline passes.
  defp post_burst_response(sock, budget_ms), do: loop_response(sock, now() + budget_ms)

  defp loop_response(sock, deadline) do
    if now() >= deadline do
      nil
    else
      frames = collect_frames(sock, min(500, max(deadline - now(), 1)))
      body = Enum.find(frames, fn {type, _f, sid, _p} -> type == 0x0 and sid == 6001 end)

      case body do
        {0x0, _f, 6001, <<body_byte, _::binary>>} -> {:post_burst, body_byte}
        _ -> loop_response(sock, deadline)
      end
    end
  end

  # -- bandit boot -------------------------------------------------------------

  defmodule Probe do
    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"probe":"ok"}))
    end
  end

  defp start_bandit(port, opts) do
    start_supervised!({Bandit, Keyword.merge(opts, plug: Probe)})
    wait_listening(port, 20)
    :ok
  end

  defp wait_listening(port, tries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
      {:ok, s} ->
        :gen_tcp.close(s)
        :ok

      _ when tries > 0 ->
        # SLEEP-CLASS: POLL-STEP — bounded (20 tries) listen-reachable poll on
        # the observable that matters: a real TCP accept on the bandit port.
        Process.sleep(100)
        wait_listening(port, tries - 1)

      _ ->
        flunk("bandit never listened on #{port}")
    end
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end

  # -- raw h2 client over TLS --------------------------------------------------

  defp h2_connect(port) do
    :ssl.start()

    {:ok, sock} =
      :ssl.connect(~c"127.0.0.1", port, [
        verify: :verify_none,
        alpn_advertised_protocols: [<<"h2">>],
        active: false,
        nodelay: true
      ], 5_000)

    :ok = :ssl.send(sock, client_preface())
    {:ok, sock}
  end

  defp client_preface, do: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" <> frame(0x4, 0x0, 0, <<>>)

  # One probe stream per odd id: HEADERS (open, no END_STREAM — the client is
  # abandoning the request) followed immediately by RST_STREAM(CANCEL). This
  # is the wire shape undici emits when fetch cancels a response body.
  defp send_reset_burst(sock, n) do
    blob =
      1..n
      |> Enum.map(fn i ->
        sid = 2 * i - 1
        headers = hpack(@probe_headers)
        [frame(0x1, 0x4, sid, headers), frame(0x3, 0x0, sid, <<8::32>>)]
      end)
      |> IO.iodata_to_binary()

    :ok = :ssl.send(sock, blob)
  end

  # Reads frames until the deadline passes; ACKs server SETTINGS; returns
  # [{type, flags, stream_id}]. Exact-length recvs (passive :ssl recv/0
  # returns a charlist on this OTP; exact-length returns a binary).
  defp collect_frames(sock, budget_ms), do: collect_frames(sock, now() + budget_ms, [])

  defp collect_frames(sock, deadline, acc) do
    if now() >= deadline do
      Enum.reverse(acc)
    else
      remaining = max(deadline - now(), 1)

      case recv_bin(sock, 9, remaining) do
        :closed ->
          Enum.reverse(acc)

        <<len::24, type, flags, _::1, sid::31>> ->
          payload = recv_bin(sock, len, max(deadline - now(), 1))

          acc =
            case {type, flags} do
              {0x4, 0x0} ->
                :ok = :ssl.send(sock, frame(0x4, 0x1, 0, <<>>))
                acc

              _ ->
                [{type, flags, sid, payload} | acc]
            end

          collect_frames(sock, deadline, acc)

        {:error, _} ->
          Enum.reverse(acc)
      end
    end
  end

  defp recv_bin(sock, len, timeout) do
    case :ssl.recv(sock, len, timeout) do
      {:ok, d} -> IO.iodata_to_binary(d)
      _ -> :closed
    end
  end

  defp goaway(frames) do
    case Enum.find(frames, fn {type, _f, _sid, _pay} -> type == 0x7 end) do
      # GOAWAY payload: last stream id (32) + error code (32).
      {0x7, _f, _sid, <<_last::32, err::32>>} -> {:goaway, err}
      _ -> nil
    end
  end

  defp responses(frames), do: Enum.count(frames, fn {type, _f, sid, _p} -> type == 0x1 and sid > 0 end)

  defp now, do: System.monotonic_time(:millisecond)

  # -- minimal HPACK: literal header field without indexing, new name ----------
  defp hpack(pairs) do
    Enum.reduce(pairs, <<>>, fn {k, v}, acc ->
      acc <> <<0x00, byte_size(k), k::binary, byte_size(v), v::binary>>
    end)
  end

  defp frame(type, flags, sid, payload) do
    IO.iodata_to_binary([<<byte_size(payload)::24, type, flags, 0::1, sid::31>>, payload])
  end
end

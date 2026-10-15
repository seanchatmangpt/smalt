# AMQP max-throughput driver: raw FrameCodec client over :gen_tcp.
#
# One connection per sender/receiver pair; single-pair mode uses 1 pair,
# 4-pair mode uses 4 connections on 4 distinct queues. Each pair:
#   sender link (handle 0)  -> 1KB transfers, settled:true, timestamp embedded
#                              in application-properties ("ts")
#   receiver link (handle 1) -> credit window 100, replenished +1 per
#                              disposition(accepted) after each delivery
# Round trip = send -> receive -> complete (receiver disposition accepted,
# which the broker maps to QueueStore.complete via LockManager).
#
# Env:
#   SMALT_AMQP_PORT       broker AMQP port
#   SMALT_SB_SHARED_KEY   base64 shared key (CBS put-token)
#   SMALT_TPUT_DURATION   seconds (default 60)
#   SMALT_TPUT_PAYLOAD    payload bytes (default 1024)
#   SMALT_TPUT_PAIRS      parallel pairs (default 1)
#   SMALT_TPUT_LABEL      queue label
#
# Final stdout line: `TPUT_JSON {…}` (parsed by the python harness).

defmodule Stress.AmqpTput do
  @sasl_header "AMQP\x03\x01\x00\x00"
  @header "AMQP\x00\x01\x00\x00"
  @cbs_type "servicebus.windows.net:sastoken"

  alias Smalt.Amqp.FrameCodec

  defstruct [:sock, :buf, :queue, :payload, :sent, :completed, :outstanding, :next_dlv, :rx_seen, :latencies, :errs]

  def main do
    duration = env_int("SMALT_TPUT_DURATION", 60) * 1000
    payload_bytes = env_int("SMALT_TPUT_PAYLOAD", 1024)
    pairs = env_int("SMALT_TPUT_PAIRS", 1)
    port = String.to_integer(System.fetch_env!("SMALT_AMQP_PORT"))
    label = System.get_env("SMALT_TPUT_LABEL", "solo")
    Application.put_env(:smalt, :sb_shared_key, System.fetch_env!("SMALT_SB_SHARED_KEY"))

    payload = :crypto.strong_rand_bytes(payload_bytes)
    started = System.monotonic_time(:millisecond)

    results =
      Enum.map(1..pairs, fn p ->
        task =
          Task.async(fn ->
            queue = "stress-#{label}-#{p}-#{System.unique_integer([:positive])}"
            run_pair(port, queue, started, duration, payload)
          end)

        Task.await(task, duration + 120_000)
      end)

    totals = Enum.reduce(results, %{sent: 0, completed: 0, lat: [], errs: %{}}, fn r, acc ->
      %{
        sent: acc.sent + r.sent,
        completed: acc.completed + r.completed,
        lat: acc.lat ++ r.latencies,
        errs: Map.merge(acc.errs, r.errs, fn _k, a, b -> a + b end)
      }
    end)

    lat = Enum.sort(totals.lat)

    %{
      pairs: pairs,
      payload_bytes: payload_bytes,
      duration_s: div(duration, 1000),
      sent: totals.sent,
      completed: totals.completed,
      send_rate_mps: rate(totals.sent, duration),
      roundtrip_rate_mps: rate(totals.completed, duration),
      latency_ms: pct(lat),
      errors: totals.errs,
      receive_path: if(totals.completed > 0, do: "ok", else: "RECEIVE-PATH-PENDING")
    }
    |> json_line()
  end

  defp run_pair(port, queue, started, duration, payload) do
    audience = Smalt.Amqp.SasVerifier.endpoint() <> "/" <> queue
    c = connect(port) |> handshake() |> authorize(audience)

    # sender link
    c = send_frame(c, {:attach, %{name: "tx", handle: 0, role: false, target: %{address: queue}}})
    c = await_sender_ready(c)

    # receiver link
    c = send_frame(c, {:attach, %{name: "rx", handle: 1, role: true, source: %{address: queue}}})
    c = await_rx_attach(c)
    c = send_frame(c, {:flow, %{handle: 1, link_credit: @credit_window}})

    st =
      %__MODULE__{
        sock: c.sock,
        buf: c.buf,
        queue: queue,
        payload: payload,
        sent: 0,
        completed: 0,
        outstanding: 0,
        next_dlv: 1,
        rx_seen: 0,
        latencies: [],
        errs: %{}
      }

    st = pump(st, started + duration)
    drain(st, 2_000)
  end

  # Send while outstanding < cap; drain inbound (dispositions decrement
  # outstanding, transfers complete + replenish credit) between bursts.
  defp pump(%__MODULE__{} = st, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      st
    else
      st = send_burst(st, deadline)

      case recv_frame(st, 1) do
        {:ok, frame, st} -> pump(handle_frame(frame, st), deadline)
        {:timeout, st} -> pump(credit_refresh(st), deadline)
        {:closed, st} -> st
      end
    end
  end

  @cap 500
  @credit_window 100

  defp credit_refresh(%__MODULE__{sock: sock} = st) do
    :ok =
      :gen_tcp.send(
        sock,
        FrameCodec.encode_frame(:amqp, 0, {:flow, %{handle: 1, link_credit: @credit_window}})
      )

    st
  end
  defp send_burst(%__MODULE__{outstanding: o} = st, _deadline) when o >= @cap, do: st

  defp send_burst(%__MODULE__{} = st, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      st
    else
      # burst up to 64 per socket write to amortize syscall cost
      n = min(@cap - st.outstanding, 64)
      {frames, st} = build_transfers(st, n, [])

      # credit refresh: the broker dispatches queued messages only inside
      # deliver_available/1, which currently runs on client flow frames only
      # (ingest_message does not trigger a dispatch after enqueue). Each
      # refresh flow gives the broker a dispatch pass, so sends are delivered
      # back while the run is in flight.
      refresh = FrameCodec.encode_frame(:amqp, 0, {:flow, %{handle: 1, link_credit: @credit_window}})
      :ok = :gen_tcp.send(st.sock, [frames, refresh])
      send_burst(st, deadline)
    end
  end

  defp build_transfers(%__MODULE__{} = st, 0, acc), do: {acc, st}

  defp build_transfers(%__MODULE__{} = st, n, acc) do
    ts = System.system_time(:microsecond)
    id = st.next_dlv

    frame =
      FrameCodec.encode_frame(:amqp, 0, {
        :transfer,
        %{handle: 0, delivery_id: id, delivery_tag: <<id::unsigned-64>>, message_format: 0, settled: true, more: false},
        {:sections, [{:application_properties, %{"ts" => ts}}, {:body_data, st.payload}]}
      })

    build_transfers(
      %{st | sent: st.sent + 1, outstanding: st.outstanding + 1, next_dlv: id + 1},
      n - 1,
      [frame | acc]
    )
  end

  defp handle_frame(%{performative: %{performative: :disposition}} = _f, st) do
    # broker settled our pred-settled send: one less in flight
    %{st | outstanding: max(st.outstanding - 1, 0)}
  end

  defp handle_frame(%{performative: %{performative: :transfer}, payload: p} = f, st) do
    ts = extract_ts(p)
    now = System.system_time(:microsecond)

    lat = if is_integer(ts), do: [max(now - ts, 0) / 1000 | st.latencies], else: st.latencies

    :ok =
      :gen_tcp.send(st.sock, [
        FrameCodec.encode_frame(:amqp, 0, {
          :disposition,
          %{role: true, first: f.performative.delivery_id, last: f.performative.delivery_id, settled: true, state: :accepted}
        }),
        FrameCodec.encode_frame(:amqp, 0, {:flow, %{handle: 1, link_credit: 1}})
      ])

    %{st | completed: st.completed + 1, latencies: lat}
  end

  defp handle_frame(_f, st), do: st

  # after the send deadline: keep completing inbound deliveries briefly
  defp drain(%__MODULE__{completed: c} = st, budget) do
    if c >= st.sent or budget <= 0 do
      st
    else
      case recv_frame(st, 50) do
        {:ok, frame, st} -> drain(handle_frame(frame, st), budget - 1)
        {:timeout, st} -> drain(credit_refresh(st), budget - 20)
        {:closed, st} -> st
      end
    end
  end

  defp recv_frame(%__MODULE__{buf: buf} = st, timeout) do
    case pop(buf) do
      {:ok, frame, rest} -> {:ok, frame, %{st | buf: rest}}
      :incomplete ->
        case :gen_tcp.recv(st.sock, 0, timeout) do
          {:ok, data} -> recv_frame(%{st | buf: <<buf::binary, data::binary>>}, timeout)
          {:error, :timeout} -> {:timeout, %{st | buf: buf}}
          {:error, _} -> {:closed, st}
        end
    end
  end

  defp pop(buf) do
    case FrameCodec.decode_frame(buf) do
      {:ok, frame} ->
        <<size::unsigned-integer-size(32), _::binary>> = buf
        {:ok, frame, binary_part(buf, size, byte_size(buf) - size)}

      {:more, _} -> :incomplete
      {:error, reason} -> raise "frame decode error: #{inspect(reason)}"
    end
  end

  defp extract_ts(payload) do
    case FrameCodec.decode_message(payload) do
      {:ok, sections} ->
        find_ts(sections) || nested_ts(sections)

      _ -> nil
    end
  end

  defp find_ts(sections) do
    Enum.find_value(sections, fn
      {:application_properties, %{"ts" => ts}} -> ts
      _ -> nil
    end)
  end

  # delivered body_data wraps the original message; unwrap one level
  defp nested_ts(sections) do
    Enum.find_value(sections, fn
      {:body_data, raw} ->
        case FrameCodec.decode_message(raw) do
          {:ok, inner} -> find_ts(inner)
          _ -> nil
        end

      _ -> nil
    end)
  end

  # --- connection setup -----------------------------------------------------------

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)
    %{sock: sock, buf: <<>>}
  end

  defp authorize(c, audience) do
    key = Application.fetch_env!(:smalt, :sb_shared_key)
    se = System.system_time(:second) + 600

    enc_sr = URI.encode_www_form(audience)

    sig =
      :crypto.mac(:hmac, :sha256, key, "#{enc_sr}\n#{se}")
      |> Base.encode64()
      |> URI.encode_www_form()

    token =
      "SharedAccessSignature sr=#{enc_sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    c = send_frame(c, {:attach, %{name: "cbs-tx", handle: 2, role: false, target: %{address: "$cbs"}}})
    c = send_frame(c, {:attach, %{name: "cbs-rx", handle: 3, role: true, source: %{address: "$cbs"}}})

    c =
      send_frame(c, {
        :transfer,
        %{handle: 2, delivery_id: 100, delivery_tag: <<100>>, message_format: 0, settled: true, more: false},
        {:sections, [
          {:application_properties, %{"operation" => "put-token", "type" => @cbs_type, "name" => audience}},
          {:body_amqp_value, token}
        ]}
      })

    wait_cbs_reply(c, 60)
  end

  defp wait_cbs_reply(c, 0), do: raise("no $cbs put-token reply arrived")

  defp wait_cbs_reply(c, n) do
    case pop(c.buf) do
      {:ok, %{performative: %{performative: :transfer}} = f, rest} ->
        {:ok, sections} = FrameCodec.decode_message(f.payload)

        case Enum.find_value(sections, fn
               {:application_properties, %{"statusCode" => code}} -> code
               {:message_annotations, %{"x-opt-status-code" => code}} -> code
               _ -> nil
             end) do
          200 -> %{c | buf: rest}
          code -> raise("cbs put-token rejected: #{inspect(code)}")
        end

      {:ok, _other, rest} ->
        wait_cbs_reply(%{c | buf: rest}, n)

      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, 5_000)
        wait_cbs_reply(%{c | buf: <<c.buf::binary, data::binary>>}, n)
    end
  end

  defp await_sender_ready(c), do: do_await_sender(c, false, false)

  defp do_await_sender(c, attach_seen?, flow_seen?) do
    cond do
      attach_seen? and flow_seen? -> c

      true ->
        case pop(c.buf) do
          {:ok, %{performative: %{performative: :attach}}, rest} ->
            do_await_sender(%{c | buf: rest}, true, flow_seen?)

          {:ok, %{performative: %{performative: :flow}}, rest} ->
            do_await_sender(%{c | buf: rest}, attach_seen?, true)

          {:ok, _other, rest} ->
            do_await_sender(%{c | buf: rest}, attach_seen?, flow_seen?)

          :incomplete ->
            {:ok, data} = :gen_tcp.recv(c.sock, 0, 5_000)
            do_await_sender(%{c | buf: <<c.buf::binary, data::binary>>}, attach_seen?, flow_seen?)
        end
    end
  end

  defp await_rx_attach(c), do: do_await_rx(c, 50)

  defp do_await_rx(c, 0), do: raise("no receiver attach echo")

  defp do_await_rx(c, n) do
    case pop(c.buf) do
      {:ok, %{performative: %{performative: :attach}}, rest} -> %{c | buf: rest}
      {:ok, _other, rest} -> do_await_rx(%{c | buf: rest}, n - 1)
      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, 5_000)
        do_await_rx(%{c | buf: <<c.buf::binary, data::binary>>}, n)
    end
  end

  defp send_frame(%{sock: sock} = c, {name, fields}) do
    layer = if name in [:sasl_init, :sasl_mechanisms, :sasl_outcome], do: :sasl, else: :amqp
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(layer, 0, {name, fields}))
    c
  end

  defp send_frame(%{sock: sock} = c, {:transfer, fields, {:sections, _} = sections}) do
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(:amqp, 0, {:transfer, fields, sections}))
    c
  end

  # --- handshake: SASL ANONYMOUS -> AMQP open/begin ---------------------------------

  defp handshake(c) do
    :ok = :gen_tcp.send(c.sock, @sasl_header)
    {:ok, @sasl_header, c} = recv_exact(c, 8)

    {%{performative: %{performative: :sasl_mechanisms}}, c} = next_frame(c)
    c = send_frame(c, {:sasl_init, %{mechanism: "ANONYMOUS"}})
    {%{performative: %{performative: :sasl_outcome, code: 0}}, c} = next_frame(c)

    :ok = :gen_tcp.send(c.sock, @header)
    {:ok, @header, c} = recv_exact(c, 8)

    c = send_frame(c, {:open, %{container_id: "smalt-tput-driver", max_frame_size: 65_536, channel_max: 65_535}})
    {%{performative: %{performative: :open}}, c} = next_frame(c)

    c =
      send_frame(c, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})

    {%{performative: %{performative: :begin}}, c} = next_frame(c)

    c
  end

  defp next_frame(c, timeout \\ 5_000) do
    case pop(c.buf) do
      {:ok, frame, rest} -> {frame, %{c | buf: rest}}
      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, timeout)
        next_frame(%{c | buf: <<c.buf::binary, data::binary>>}, timeout)
    end
  end

  defp recv_exact(%{buf: buf} = c, n) when byte_size(buf) >= n do
    <<data::binary-size(n), rest::binary>> = buf
    {:ok, data, %{c | buf: rest}}
  end

  defp recv_exact(c, n) do
    {:ok, data} = :gen_tcp.recv(c.sock, n - byte_size(c.buf), 5_000)
    recv_exact(%{c | buf: <<c.buf::binary, data::binary>>}, n)
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      v -> String.to_integer(v)
    end
  end

  defp rate(n, duration_ms), do: Float.round(n / (duration_ms / 1000), 1)

  defp pct([]), do: %{}

  defp pct(sorted) do
    n = length(sorted)

    %{
      n: n,
      p50: at(sorted, round(n * 0.5)),
      p90: at(sorted, round(n * 0.9)),
      p99: at(sorted, round(n * 0.99)),
      max: at(sorted, n - 1)
    }
    |> Map.new(fn {k, v} -> {k, if(is_float(v), do: Float.round(v, 3), else: v)} end)
  end

  defp at(list, i) when i >= 1, do: Enum.at(list, i - 1)
  defp at(list, _), do: Enum.at(list, 0)

  defp json_line(res) do
    json =
      res
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Jason.encode!()

    IO.puts("TPUT_JSON #{json}")
  end
end

Stress.AmqpTput.main()

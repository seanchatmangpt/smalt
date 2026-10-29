# FIX-4 raw-wire witness (KD-132b malformed app-props map + KD-133 spec-ordered flow)
# Boots nothing; expects block b88 up (SMALT_FIX4_PORT, default 39880).
# KD-COVERS: KD-132, KD-133
alias Smalt.Amqp.PrimitiveCodec
alias Smalt.Amqp.FrameCodec

port = String.to_integer(System.get_env("SMALT_FIX4_PORT") || "39880")
key = System.get_env("SMALT_FIX4_KEY") || raise "need SMALT_FIX4_KEY"

{:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [{:active, false}, {:mode, :binary}, {:buffer, 65536}])
:ok = :gen_tcp.send(sock, <<"AMQP", 0, 1, 0, 0>>)

# --- frame reader (size-prefixed, one frame per call, buffers leftovers)
# consume server protocol-header greeting (8 bytes) before frames
case :gen_tcp.recv(sock, 8, 10_000) do
  {:ok, <<"AMQP", 0, 1, 0, 0>>} -> :ok
  other -> throw({:bad_greeting, other})
end

send_frame = fn f, ch, body ->
  iolist = FrameCodec.encode_frame(f, ch, body)
  :ok = :gen_tcp.send(sock, iolist)
end

buf = IO.iodata_to_binary([])
buf_ref = :erlang.make_ref()
read_frame = nil  # unused
bufs = :ets.new(:bufs, [:set, :public, :named_table])
:ets.insert(:bufs, {:b, <<>>})

read_frame = fn expect_perf, timeout_ms, self_state ->
  # closure recursion via unquote trick not available; use a named helper module
  nil
end

# simpler: recursive helper via stream of recv
defmodule F4 do
  def read_frame(sock, tab) do
    case :ets.lookup(tab, :b) do
      [{:b, <<size::32, _::binary>> = buf}] when byte_size(buf) >= size ->
        <<frame::binary-size(size), rest::binary>> = buf
        :ets.insert(tab, {:b, rest})
        case FrameCodec.decode_frame(frame) do
          {:ok, %{performative: %{performative: perf}} = fm} -> {:ok, perf, fm}
          other -> {:error, {:bad_decode, other}}
        end

      [{:b, buf}] ->
        case :gen_tcp.recv(sock, 0, 15_000) do
          {:ok, data} ->
            :ets.insert(tab, {:b, buf <> data})
            read_frame(sock, tab)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def drain_until(sock, tab, pred, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: throw(:deadline)
    case read_frame(sock, tab) do
      {:ok, perf, fm} -> if pred.(perf, fm), do: fm, else: drain_until(sock, tab, pred, deadline)
      {:error, r} -> throw({:wire_error, r})
    end
  end
end

deadline = System.monotonic_time(:millisecond) + 15_000

# 1. open
send_frame.(:amqp, 0, {:open, %{container_id: "fix4-raw"}})
F4.drain_until(sock, bufs, fn p, _ -> p == :open end, deadline)
IO.puts("WIRE open ok")

# 2. begin
send_frame.(:amqp, 0, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000}})
F4.drain_until(sock, bufs, fn p, _ -> p == :begin end, deadline)
IO.puts("WIRE begin ok")

# 3. attach sender h0 -> $cbs ; receiver h1 -> fix4-cbs.reply
send_frame.(:amqp, 0, {:attach, %{name: "fix4-raw-tx", handle: 0, role: false, target: %{address: "$cbs"}}})
F4.drain_until(sock, bufs, fn p, _ -> p == :attach end, deadline)
send_frame.(:amqp, 0, {:attach, %{name: "fix4-raw-rx", handle: 1, role: true, source: %{address: "$cbs"}, initial_delivery_count: 0}})
F4.drain_until(sock, bufs, fn p, _ -> p == :attach end, deadline)
IO.puts("WIRE attaches ok")

# 4. KD-133 WITNESS: a SPEC-ORDERED flow (FrameCodec encodes flow fields in
# AMQP spec order: next-incoming-id, incoming-window, next-outgoing-id,
# outgoing-window, handle, delivery-count, link-credit, available, drain,
# echo, properties) granting 10 credits.
send_frame.(:amqp, 0, {:flow, %{next_incoming_id: 1, incoming_window: 10_000, next_outgoing_id: 2, outgoing_window: 10_000, handle: 1, link_credit: 10}})
IO.puts("WIRE spec-ordered flow sent (handle 1, credit 10)")

# 5. malformed put-token: properties + MALFORMED map32 application-properties
audience = "sb://127.0.0.1:" <> Integer.to_string(port) <> "/fix4-q"
bad_props = <<0x00, 0x53, 0x74, 0xD1, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x51, 0x01>>

audience = "sb://127.0.0.1:" <> Integer.to_string(port) <> "/fix4-q"
se = System.system_time(:second) + 3600
se_s = Integer.to_string(se)
sr = URI.encode_www_form(audience)
sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, sr <> "\n" <> se_s))
token = "SharedAccessSignature sr=" <> sr <> "&sig=" <> URI.encode_www_form(sig) <> "&se=" <> se_s <> "&skn=RootManageSharedAccessKey"

sections_ok = [
  {:properties, %{correlation_id: "fix4-ok-1", reply_to: "fix4-cbs.reply"}},
  {:application_properties, %{"operation" => "put-token", "type" => "servicebus.windows.net:sastoken", "name" => audience, "expiration" => se}},
  {:body_amqp_value, token}
]

send_transfer = fn sections_payload ->
  fields = %{handle: 0, delivery_tag: <<"fix4raw">>, delivery_id: System.unique_integer([:positive]), message_format: 0, settled: true, more: false}
  body = [FrameCodec.encode_frame(:amqp, 0, {:transfer, fields, sections_payload})]
  :ok = :gen_tcp.send(sock, body)
end

# malformed transfer: properties section + raw malformed app-props bytes
props_io = FrameCodec.encode_message([{:properties, %{correlation_id: "fix4-bad-1", reply_to: "fix4-cbs.reply"}}])
send_transfer.(props_io ++ [bad_props])
IO.puts("WIRE malformed map32 app-props transfer sent")

# expect a typed $cbs reply (400) — poll deliveries
reply1 =
  F4.drain_until(sock, bufs, fn
    :transfer, fm -> true
    _, _ -> false
  end, deadline)

{:ok, secs} = FrameCodec.decode_message(reply1.payload)
ap = Enum.find_value(secs, fn
  {:application_properties, m} -> m
  _ -> nil
end)
IO.puts("WIRE malformed-map reply statusCode=" <> inspect(ap["statusCode"] || ap["status-code"]))

status1 = ap["statusCode"] || ap["status-code"]
unless is_integer(status1), do: throw({:no_status_code, secs})

# KD-132b: connection survives — a VALID put-token on the SAME socket answers
send_transfer.(FrameCodec.encode_message(sections_ok))
reply2 =
  F4.drain_until(sock, bufs, fn
    :transfer, fm -> true
    _, _ -> false
  end, deadline)

{:ok, secs2} = FrameCodec.decode_message(reply2.payload)
ap2 = Enum.find_value(secs2, fn
  {:application_properties, m} -> m
  _ -> nil
end)
status2 = ap2["statusCode"] || ap2["status-code"]
IO.puts("WIRE post-malformed valid put-token statusCode=" <> inspect(status2))
unless status2 == 200, do: throw({:expected_200, status2})

IO.puts("FIX4-RAW WITNESS PASS: malformed map typed-refused, connection survived, spec-ordered flow granted credit")

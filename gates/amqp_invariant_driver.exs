# Raw FrameCodec AMQP client for the invariant gates (pattern from
# scripts/stress/amqp_tput_driver.exs).
#
# Modes (SMALT_GATE_MODE):
#   "capacity"  — fill one queue to its 4096-message capacity with settled
#                 transfers, then send the 4097th and read the broker's close
#                 frame. Prints GATE_JSON {"condition": .., "description": ..}.
#   "lockclamp" — for each "queue:expected_ms" pair in SMALT_LOCK_QUEUES,
#                 attach sender+receiver, send 1 message, receive it, and read
#                 x-opt-locked-until off the delivery. Prints GATE_JSON with a
#                 list of observed lock deltas (locked_until - now, ms).
#
# Env: SMALT_AMQP_PORT, SMALT_GATE_MODE, SMALT_CAP_QUEUE, SMALT_LOCK_QUEUES.
# Final stdout line: `GATE_JSON {…}` (parsed by gates/common.py).

defmodule Gates.AmqpInvariantDriver do
  @sasl_header "AMQP\x03\x01\x00\x00"
  @header "AMQP\x00\x01\x00\x00"

  alias Smalt.Amqp.FrameCodec

  defstruct [:sock, :buf]

  @cbs_type "servicebus.windows.net:sastoken"

  def main do
    Application.put_env(:smalt, :sb_shared_key, System.fetch_env!("SMALT_SB_SHARED_KEY"))
    port = String.to_integer(System.fetch_env!("SMALT_AMQP_PORT"))

    case System.fetch_env!("SMALT_GATE_MODE") do
      "capacity" -> capacity(port)
      "lockclamp" -> lockclamp(port)
      other -> raise("unknown SMALT_GATE_MODE #{inspect(other)}")
    end
  end

  # -- capacity -----------------------------------------------------------------

  defp capacity(port) do
    queue = System.fetch_env!("SMALT_CAP_QUEUE")
    c = connect(port) |> handshake() |> authorize(endpoint() <> "/" <> queue)
        |> attach_sender(queue, 0) |> await_sender_ready()

    payload = :binary.copy(<<"x">>, 16)
    transfers =
      for id <- 1..4096 do
        transfer_frame(id, payload, true)
      end

    # chunked writes so a single huge TCP write can't stall the broker's reader
    transfers
    |> Enum.chunk_every(256)
    |> Enum.each(fn chunk -> :ok = :gen_tcp.send(c.sock, chunk) end)

    # the 4097th: unsettled so the broker must rule on it explicitly
    :ok = :gen_tcp.send(c.sock, transfer_frame(4097, payload, false))

    result = read_until_ruling(c, 60_000)
    json_line(%{mode: "capacity", queue: queue, result: result})
  end

  defp transfer_frame(id, payload, settled) do
    FrameCodec.encode_frame(:amqp, 0, {
      :transfer,
      %{handle: 0, delivery_id: id, delivery_tag: <<id::unsigned-64>>,
        message_format: 0, settled: settled, more: false},
      {:sections, [{:body_data, payload}]}
    })
  end

  # BK-78: the Azure-exact capacity face is a LINK DETACH with
  # amqp:link:message-size-exceeded (spec §2.8.15) and the CONNECTION
  # SURVIVES — a close-with-error, or a silent socket drop, is a divergence.
  # Returns {"condition", "description", "survived"}.
  defp read_until_ruling(c, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: raise("no broker ruling arrived")

    case pop(c.buf) do
      {:ok, %{performative: %{performative: :close} = perf}, _rest} ->
        {cond, desc} = close_error_fields(perf)
        Map.merge(%{"condition" => plain(cond), "description" => plain(desc)},
                  %{"survived" => false})

      {:ok, %{performative: %{performative: :detach} = perf}, rest} ->
        err = perf[:error] || %{}

        errcond = err_condition(err)

        if is_binary(errcond) do
          # detached WITH error = the ruling. Prove the connection survives:
          # a short recv must time out (broker still streaming), not close.
          survived =
            case :gen_tcp.recv(c.sock, 0, 2_000) do
              {:error, :timeout} -> true
              {:error, :closed} -> false
              {:ok, _more} -> true
            end

          %{"condition" => errcond,
            "description" => plain(detach_desc(err)),
            "survived" => survived}
        else
          read_until_ruling(%{c | buf: rest}, deadline)
        end

      {:ok, _other, rest} ->
        read_until_ruling(%{c | buf: rest}, deadline)

      :incomplete ->
        case :gen_tcp.recv(c.sock, 0, 5_000) do
          {:ok, data} -> read_until_ruling(%{c | buf: <<c.buf::binary, data::binary>>}, deadline)
          {:error, _} ->
            %{"condition" => "socket-closed", "description" => "no close frame",
              "survived" => false}
        end
    end
  end

  defp detach_desc(err), do: err_description(err)

  # AMQP error fields decode as {:described, 0x1D, [condition-symbol,
  # description, info]} (FrameCodec described-type decode), or a plain map /
  # list depending on producer. Handle every shape the wire can deliver.
  defp err_condition({:described, _, [c | _]}) when tuple_size(c) == 2, do: elem(c, 1)
  defp err_condition({:described, _, [c | _]}) when is_binary(c), do: c
  defp err_condition([c | _]) when is_binary(c), do: c
  defp err_condition(%{} = m), do: plain(m[:condition] || Map.get(m, "condition"))
  defp err_condition(_), do: nil

  defp err_description({:described, _, [_, d | _]}) when is_binary(d), do: d
  defp err_description([_, d | _]) when is_binary(d), do: d
  defp err_description(%{} = m), do: plain(m[:description] || Map.get(m, "description"))
  defp err_description(_), do: nil

  defp close_error_fields(perf) do
    err = perf[:error] || %{}
    {err_condition(err), err_description(err)}
  end

  # -- lock clamp ----------------------------------------------------------------

  defp lockclamp(port) do
    queues =
      System.fetch_env!("SMALT_LOCK_QUEUES")
      |> String.split(",")
      |> Enum.map(fn spec ->
        [name, expected] = String.split(spec, ":")
        {name, String.to_integer(expected)}
      end)

    results =
      Enum.map(queues, fn {queue, expected_ms} ->
        c =
          connect(port)
          |> handshake()
          |> authorize(endpoint() <> "/" <> queue)
          |> attach_sender(queue, 0)
          |> await_sender_ready()

        :ok = :gen_tcp.send(c.sock, transfer_frame(1, "lock-probe", true))

        c = attach_receiver(c, queue, 1)
        c = send_flow(c, 1, 2)

        delivery = await_transfer(c, 15_000)
        now = System.system_time(:millisecond)
        sections = decode_sections(delivery.payload)

        locked_until =
          Enum.find_value(sections, fn
            {:message_annotations, ann} -> ann["x-opt-locked-until"] |> plain_ts()
            _ -> nil
          end)

        delivery_count =
          Enum.find_value(sections, fn
            {:header, h} -> h[:delivery_count] || h["delivery_count"]
            _ -> nil
          end)

        %{
          "queue" => queue,
          "expected_ms" => expected_ms,
          "locked_until" => locked_until,
          "delta_ms" => if(is_integer(locked_until), do: locked_until - now, else: nil),
          "delivery_count" => delivery_count
        }
      end)

    json_line(%{mode: "lockclamp", observations: results})
  end

  defp plain_ts({:timestamp, ms}) when is_integer(ms), do: ms
  defp plain_ts(ms) when is_integer(ms), do: ms
  defp plain_ts(_), do: nil

  defp await_transfer(c, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: raise("no delivery arrived")

    case pop(c.buf) do
      {:ok, %{performative: %{performative: :transfer}} = f, _rest} -> f
      {:ok, _other, rest} -> await_transfer(%{c | buf: rest}, deadline)
      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, 2_000)
        await_transfer(%{c | buf: <<c.buf::binary, data::binary>>}, deadline)
    end
  end

  # -- CBS authorization (mirrors scripts/stress/amqp_tput_driver.exs) -------------

  defp endpoint, do: Smalt.Amqp.SasVerifier.endpoint()

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
      send_frame(
        c,
        {:transfer,
         %{
           handle: 2,
           delivery_id: 100,
           delivery_tag: <<100>>,
           message_format: 0,
           settled: true,
           more: false
         },
         {:sections, [
           {:application_properties, %{"operation" => "put-token", "type" => @cbs_type, "name" => audience}},
           {:body_amqp_value, token}
         ]}}
      )

    wait_cbs_reply(c, 60)
  end

  defp wait_cbs_reply(_c, 0), do: raise("no $cbs put-token reply arrived")

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

  # -- link setup ------------------------------------------------------------------

  defp attach_sender(c, queue, handle) do
    send_frame(c, {:attach, %{name: "gate-tx", handle: handle, role: false, target: %{address: queue}}})
  end

  defp attach_receiver(c, queue, handle) do
    send_frame(c, {:attach, %{name: "gate-rx", handle: handle, role: true, source: %{address: queue}}})
    c
  end

  defp send_flow(c, handle, credit) do
    send_frame(c, {:flow, %{handle: handle, link_credit: credit}})
  end

  defp await_sender_ready(c) do
    do_await(c, false, false)
  end

  defp do_await(c, true, true), do: c

  defp do_await(c, attach_seen?, flow_seen?) do
    case pop(c.buf) do
      {:ok, %{performative: %{performative: :attach}}, rest} ->
        do_await(%{c | buf: rest}, true, flow_seen?)

      {:ok, %{performative: %{performative: :flow}}, rest} ->
        do_await(%{c | buf: rest}, attach_seen?, true)

      {:ok, _other, rest} ->
        do_await(%{c | buf: rest}, attach_seen?, flow_seen?)

      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, 10_000)
        do_await(%{c | buf: <<c.buf::binary, data::binary>>}, attach_seen?, flow_seen?)
    end
  end

  # -- connection setup (mirrors scripts/stress/amqp_tput_driver.exs) ---------------

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)
    %{sock: sock, buf: <<>>}
  end

  defp handshake(c) do
    :ok = :gen_tcp.send(c.sock, @sasl_header)
    {_sasl_header, c} = recv_exact(c, 8)
    {%{performative: %{performative: :sasl_mechanisms}}, c} = next_frame(c)
    c = send_frame(c, {:sasl_init, %{mechanism: "ANONYMOUS"}})
    {%{performative: %{performative: :sasl_outcome, code: 0}}, c} = next_frame(c)

    :ok = :gen_tcp.send(c.sock, @header)
    {_header, c} = recv_exact(c, 8)
    c = send_frame(c, {:open, %{container_id: "smalt-gate-driver", max_frame_size: 65_536, channel_max: 65_535}})
    {%{performative: %{performative: :open}}, c} = next_frame(c)

    c =
      send_frame(c, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})

    {%{performative: %{performative: :begin}}, c} = next_frame(c)
    c
  end

  defp next_frame(c, timeout \\ 10_000) do
    case pop(c.buf) do
      {:ok, frame, rest} -> {frame, %{c | buf: rest}}
      :incomplete ->
        {:ok, data} = :gen_tcp.recv(c.sock, 0, timeout)
        next_frame(%{c | buf: <<c.buf::binary, data::binary>>}, timeout)
    end
  end

  defp recv_exact(%{buf: buf} = c, n) when byte_size(buf) >= n do
    <<data::binary-size(n), rest::binary>> = buf
    {data, %{c | buf: rest}}
  end

  defp recv_exact(c, n) do
    {:ok, data} = :gen_tcp.recv(c.sock, n - byte_size(c.buf), 5_000)
    recv_exact(%{c | buf: <<c.buf::binary, data::binary>>}, n)
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

  defp send_frame(%{sock: sock} = c, {name, fields}) do
    layer = if name in [:sasl_init, :sasl_mechanisms, :sasl_outcome], do: :sasl, else: :amqp
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(layer, 0, {name, fields}))
    c
  end

  defp send_frame(%{sock: sock} = c, {:transfer, fields, {:sections, _} = sections}) do
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(:amqp, 0, {:transfer, fields, sections}))
    c
  end

  defp decode_sections(payload) do
    case FrameCodec.decode_message(payload) do
      {:ok, sections} -> sections
      _ -> []
    end
  end

  defp plain({:symbol, s}) when is_binary(s), do: s
  defp plain(%{} = m), do: m
  defp plain(s) when is_binary(s), do: s
  defp plain(n) when is_integer(n), do: n
  defp plain(nil), do: nil
  defp plain(other), do: inspect(other)

  defp json_line(res) do
    json =
      res
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Jason.encode!()

    IO.puts("GATE_JSON #{json}")
  end
end

Gates.AmqpInvariantDriver.main()

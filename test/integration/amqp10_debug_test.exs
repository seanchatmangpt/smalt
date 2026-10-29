defmodule Amqp10.Debug do
  use ExUnit.Case, async: false
  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>
  test "debug" do
    Process.flag(:trap_exit, true)
    parent = self()
    {:ok, _lpid, port} = Smalt.Amqp10.Connection.start_listener(0, notify: parent)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)
    receive do {:amqp10_connection, pid} -> conn = pid after 5000 -> flunk("no notify") end # SLEEP-CLASS: POLL-STEP (bounded notify receive, 5s deadline)
    :ok = :gen_tcp.send(sock, @header)
    enc = fn ch, perf -> IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, ch, perf)) end
    :ok = :gen_tcp.send(sock, [enc.(0, {:open, %{container_id: "d"}}),
                               enc.(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
                               enc.(0, {:attach, %{name: "l", handle: 0, role: false, target: %{address: "q"}}})])
    buf = <<>>
    {frames, buf} = grab(sock, 3, buf, [])
    IO.inspect(frames, label: "got3")

    # BK-70r: the trailing "extra" leg assumed a 4th inbound frame always
    # arrives after the open/begin/attach exchange — nothing in the protocol
    # guarantees one (witnessed: recv :timeout). Observe-if-present, never
    # fail on absence.
    case :gen_tcp.recv(sock, 0, 500) do
      {:ok, extra} ->
        IO.inspect(Smalt.Amqp10.FrameDecoder.decode_frame(buf <> extra), label: "extra")

      {:error, :timeout} ->
        IO.puts("extra: none within 500ms (no unsolicited frame after attach)")
    end
  end

  # BK-70r: the previous helper built an improper list (`[f | {_, _}]` via
  # `|> List.flatten()` on a tuple) — FunctionClauseError in :lists.do_flatten
  # whenever a frame decoded in the {:ok, f, rest} branch. Accumulator form.
  defp grab(_sock, 0, buf, acc), do: {:lists.reverse(acc), buf}

  defp grab(sock, n, buf, acc) do
    case Smalt.Amqp10.FrameDecoder.decode_frame(buf) do
      {:ok, f, rest} ->
        grab(sock, n - 1, rest, [f | acc])

      {:more, _} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        grab(sock, n, buf <> data, acc)
    end
  end
end

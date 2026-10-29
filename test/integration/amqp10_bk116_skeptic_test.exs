# BK-116 skeptic scratch court — NOT a landed test. Run directly:
#   MIX_BUILD_ROOT=_build-bk116 mix test test/integration/amqp10_bk116_skeptic.exs
# New adversarial case owed by the v26.10.21 amqp10-court-closure re-audit:
# mid-transfer disposition-reconciliation race (exactly-once visibility).
defmodule Amqp10.Bk116Skeptic do
  @moduledoc """
  ADV-6: kill the connection between transfer initiation and the disposition,
  reconnect, re-deliver under the SAME {channel, delivery_id} key — assert
  exactly-once visibility: exactly one row for the key, exactly one row-count
  growth regardless of whether the pre-kill transfer landed, and the
  disposition answered on the LIVE connection only. No phantom double-count.
  """

  use ExUnit.Case, async: false

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>

  defp start_router! do
    parent = self()
    {:ok, _lpid, port} = Smalt.Amqp10.Connection.start_listener(0, notify: parent)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    conn =
      receive do
        {:amqp10_connection, pid} -> pid
      after
        5_000 -> flunk("no connection notify")
      end

    {conn, sock}
  end

  defp enc(ch, perf), do: IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, ch, perf))

  defp handshake!(sock) do
    :ok = :gen_tcp.send(sock, @header)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:open, %{container_id: "bk116"}}),
        enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
        enc(0, {:attach, %{name: "bk116-link", handle: 0, role: false,
                           target: %{address: "amqp10-bk116"}}})
      ])

    frames = recv_n(sock, 4, <<>>)
    kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)
    assert kinds == [:open, :begin, :attach, :flow], inspect(kinds)
    :ok
  end

  defp recv_n(_sock, 0, _buf), do: []

  defp recv_n(sock, n, buf) do
    case Smalt.Amqp10.FrameDecoder.decode_frame(buf) do
      {:ok, f, rest} -> [f | recv_n(sock, n - 1, rest)]
      {:more, _} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_n(sock, n, buf <> data)
      {:error, r} -> flunk("decode: #{inspect(r)}")
    end
  end

  defp transfer_frame(did, payload),
    do: enc(0, {:transfer, %{handle: 0, delivery_id: did,
                             delivery_tag: <<0::128>>, settled: true, more: false}, payload})

  # R-116-1 witness: force real mid-death send failures via the RST race
  # and assert the crash reason is TYPED. The race resolves either as
  # {:tcp_tx_error, reason} (tx/3 hit the dead socket before tcp_closed was
  # processed) or {:transport_closed, reason} (tcp_closed won) — BOTH are
  # typed; the law under test is "never a bare MatchError", with at least
  # one attempt required to witness the tx/3 path directly. Bounded retries
  # over fresh real connections, no sleeps.
  test "R-116-1: mid-death tx crashes typed, never MatchError" do
    Process.flag(:trap_exit, true)
    :ok = Smalt.Amqp10.Ledger.ensure()

    reasons =
      for i <- 1..8 do
        {conn, sock} = start_router!()
        :ok = handshake!(sock)
        :ok = :gen_tcp.send(sock, transfer_frame(800_100 + i, "r116-#{i}"))
        ref = Process.monitor(conn)
        :ok = :inet.setopts(sock, linger: {true, 0})
        :ok = :gen_tcp.close(sock)

        assert_receive {:DOWN, ^ref, :process, ^conn, reason}, 5_000
        assert match?({:tcp_tx_error, _}, reason) or match?({:transport_closed, _}, reason),
               "untyped crash reason: #{inspect(reason)}"

        reason
      end

    assert Enum.any?(reasons, &match?({:tcp_tx_error, _}, &1)),
           "no attempt witnessed the tx/3 error path; reasons: #{inspect(reasons)}"
  end

  test "ADV-6: kill between transfer and disposition, reconnect, exactly-once visibility" do
    Process.flag(:trap_exit, true)
    :ok = Smalt.Amqp10.Ledger.ensure()
    before = :ets.info(:amqp10_settled, :size)

    # Leg 1: initiate the transfer, RST before reading the disposition.
    {conn1, sock1} = start_router!()
    :ok = handshake!(sock1)
    :ok = :gen_tcp.send(sock1, transfer_frame(800_001, "bk116-original"))
    ref1 = Process.monitor(conn1)
    :ok = :inet.setopts(sock1, linger: {true, 0})
    :ok = :gen_tcp.close(sock1)

    # The tree behind conn1 must die TYPED: R-116-1 closure — the tx/3 send
    # failure surfaces as {:tcp_tx_error, _}, never a bare MatchError.
    # Bounded poll on the real DOWN reason, no sleep.
    assert_receive {:DOWN, ^ref1, :process, ^conn1, reason1}, 5_000
    assert match?({:tcp_tx_error, _}, reason1) or match?({:transport_closed, _}, reason1),
           "untyped crash reason: #{inspect(reason1)}"

    # Leg 2: reconnect on the SAME listener, re-deliver under the SAME
    # {channel=0, delivery_id=800_001} key with a DIFFERENT payload.
    {conn2, sock2} = start_router!()
    :ok = handshake!(sock2)
    :ok = :gen_tcp.send(sock2, transfer_frame(800_001, "bk116-redelivery"))

    # Exactly ONE disposition, answered on the live connection.
    [disposition] = recv_n(sock2, 1, <<>>)
    {_, disp} = disposition.performative
    assert disp[:first] == 800_001
    assert disp[:settled] == true
    assert disp[:state] == {:described, 0x24, []}

    # Exactly-once visibility: exactly one row for the key, payload = the
    # redelivered body; table grew by EXACTLY 1 (set overwrite, never a
    # phantom double-count) whichever way the pre-kill leg landed.
    assert [{_, "bk116-redelivery", _ts}] = :ets.lookup(:amqp10_settled, {0, 800_001})
    grew = :ets.info(:amqp10_settled, :size) - before
    assert grew == 1, "expected +1 row, got +#{grew} (phantom double-count)"

    # Cleanup: close leg 2 typed.
    ref2 = Process.monitor(conn2)
    :ok = :gen_tcp.send(sock2, enc(0, {:close, %{}}))
    assert_receive {:DOWN, ^ref2, :process, ^conn2, _}, 5_000
  end
end

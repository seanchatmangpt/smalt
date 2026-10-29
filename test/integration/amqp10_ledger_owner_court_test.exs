# BK-41 court — JA-1 finding #2: AMQP 1.0 settled-ledger holder supervision.
#
# Subject: lib/smalt/messaging/amqp10/amqp10_ledger.ex (new GenServer owner)
# + amqp10_connection.ex ets_table/0 rewrite.
#
# Chicago discipline: real kills of the real owner pid, real TCP wire
# settled transfers, real ETS table reads. No mocks, no sleeps — bounded
# polls via SmaltTest.Internal.Poll.
#
# Court legs:
#   1. Kill the ledger owner for real -> the table and its CONTENTS survive
#      via heir `:init` (bounded poll), and the next connection re-adopts
#      cleanly and keeps landing settled transfers byte-exact.
#   2. Concurrency leg: N writers race `ensure/0` + settled insert while the
#      owner is killed mid-flight -> zero lost inserts (no lost-ledger
#      window), every delivery readable back.
#   3. Typed-lifecycle leg: owner start is idempotent (`already_started`
#      absorbed), restart re-adopts the heir-owned table.
#
# Context: solo

Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))

defmodule Integration.Amqp10LedgerOwnerCourtTest do
  use ExUnit.Case, async: false
  import SmaltTest.Internal.Poll

  alias Smalt.Amqp10.Ledger

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>
  @table :amqp10_settled

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "BK-41.1: kill the ledger owner -> table + contents survive via heir, next connection re-adopts" do
    :ok = Ledger.ensure()
    owner = Ledger.owner()
    assert is_pid(owner)

    # Seed a real settled transfer over the real wire.
    {:ok, sock, conn} = connect_and_handshake!()
    did = 41_000_001
    settled_transfer!(sock, did, "bk41-precKill")
    assert [{_, "bk41-precKill", _}] = :ets.lookup(@table, {0, did})

    # Kill the owner FOR REAL and prove it died.
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    # Heir: the :init PROCESS owns the table now; contents intact.
    init_pid = Process.whereis(:init)

    assert {:ok, :init_owned} =
             eventually(fn ->
               case :ets.info(@table, :owner) do
                 ^init_pid -> {:ok, :init_owned}
                 :undefined -> {:error, :table_gone}
                 pid when is_pid(pid) -> {:error, {:owner, pid}}
               end
             end)

    assert [{_, "bk41-precKill", _}] = :ets.lookup(@table, {0, did})

    # Next connection re-adopts cleanly: owner restarts, table NOT recreated,
    # contents still readable, and a fresh wire transfer lands byte-exact.
    {:ok, sock2, conn2} = connect_and_handshake!()
    assert {:ok, new_owner} =
             eventually(fn ->
               case Ledger.owner() do
                 pid when is_pid(pid) and pid != owner -> {:ok, pid}
                 _ -> {:error, :no_new_owner}
               end
             end)

    assert Process.alive?(new_owner)
    assert :ets.info(@table, :owner) == :init or is_pid(:ets.info(@table, :owner))

    did2 = 41_000_002
    settled_transfer!(sock2, did2, "bk41-postRestart")
    assert [{_, "bk41-postRestart", _}] = :ets.lookup(@table, {0, did2})
    assert [{_, "bk41-precKill", _}] = :ets.lookup(@table, {0, did})

    :gen_tcp.close(sock)
    :gen_tcp.close(sock2)
  end

  test "BK-41.2: concurrent writers during owner death -> zero lost-ledger window" do
    :ok = Ledger.ensure()
    owner = Ledger.owner()
    assert is_pid(owner)

    n = 24
    parent = self()

    writers =
      for i <- 1..n do
        spawn(fn ->
          did = 41_100_000 + i
          send(parent, {:started, i, Ledger.ensure()})

          # Insert under the race: owner may die before, during, after.
          row = {{0, did}, "bk41-race-#{i}", System.system_time(:millisecond)}
          {:ok, inserted} =
            try do
              :ets.insert(@table, row)
              {:ok, true}
            rescue
              ArgumentError -> {:ok, false}
            end

          send(parent, {:inserted, i, did, inserted})
        end)
      end

    # Kill the owner mid-flight, after some writers have started.
    Process.exit(owner, :kill)

    assert_receive_down = fn _ref -> :ok end

    started = for _ <- 1..n do
      assert_receive {:started, _i, :ok}, 5_000
    end

    assert length(started) == n

    results =
      for _ <- 1..n do
        assert_receive {:inserted, _i, did, inserted}, 5_000
        {did, inserted}
      end

    # Every insert must have landed (public table + heir to :init means the
    # table exists throughout; ArgumentError fallback would be a lost window).
    assert Enum.all?(results, fn {_did, inserted} -> inserted end),
           "lost-ledger window: some inserts failed: #{inspect(results)}"

    for {did, _} <- results do
      assert {:ok, _did} =
               eventually(fn ->
                 case :ets.lookup(@table, {0, did}) do
                   [_] -> {:ok, did}
                   [] -> {:error, {:missing, did}}
                 end
               end)
    end

    # Owner restart is lazy — bring it back and confirm it is alive.
    :ok = Ledger.ensure()

    assert {:ok, :up} =
             eventually(fn -> if is_pid(Ledger.owner()), do: {:ok, :up}, else: {:error, :down} end)
  end

  test "BK-41.3: ensure/0 idempotent; restart adopts heir-owned table without data loss" do
    :ok = Ledger.ensure()
    owner = Ledger.owner()
    did = 41_200_001

    row = {{0, did}, "bk41-adopt", System.system_time(:millisecond)}
    :ets.insert(@table, row)

    # Idempotent: second ensure is a no-op, same owner.
    :ok = Ledger.ensure()
    assert Ledger.owner() == owner

    # Kill -> heir to :init -> contents survive.
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    init_pid = Process.whereis(:init)

    assert {:ok, :init_owned} =
             eventually(fn ->
               if :ets.info(@table, :owner) == init_pid, do: {:ok, :init_owned}, else: {:error, :not_init}
             end)

    assert [{_, "bk41-adopt", _}] = :ets.lookup(@table, {0, did})

    # Restart adopts: no recreate, data preserved.
    :ok = Ledger.ensure()
    assert [{_, "bk41-adopt", _}] = :ets.lookup(@table, {0, did})
    assert is_pid(Ledger.owner())
  end

  # -- helpers ---------------------------------------------------------------

  defp connect_and_handshake! do
    {:ok, lpid, port} = Smalt.Amqp10.Connection.start_listener(0, notify: self())

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    conn =
      receive do
        {:amqp10_connection, pid} -> pid
      after
        5_000 -> flunk("no connection notify")
      end

    :ok = :gen_tcp.send(sock, @header)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:open, %{container_id: "bk41-client"}}),
        enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
        enc(0, {:attach, %{name: "bk41-link", handle: 0, role: false,
                           target: %{address: "bk41-target"}}})
      ])

    frames = recv_while(sock, 4, <<>>)
    kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)
    assert kinds == [:open, :begin, :attach, :flow], "unexpected handshake: #{inspect(kinds)}"

    {:ok, sock, conn}
  end

  defp enc(ch, perf), do: IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, ch, perf))

  defp settled_transfer!(sock, delivery_id, payload) do
    tag = :binary.copy(<<0>>, 16)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:transfer, %{handle: 0, delivery_id: delivery_id,
                             delivery_tag: tag, settled: true, more: false}, payload})
      ])

    [disposition] = recv_while(sock, 1, <<>>)
    {_, fields} = disposition.performative
    assert fields[:first] == delivery_id
    assert fields[:settled] == true
    :ok
  end

  defp recv_while(_sock, 0, _buf), do: []

  defp recv_while(sock, n, buf) do
    {frame, buf2} =
      case Smalt.Amqp10.FrameDecoder.decode_frame(buf) do
        {:ok, f, rest} -> {f, rest}
        {:more, _} ->
          {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
          case Smalt.Amqp10.FrameDecoder.decode_frame(buf <> data) do
            {:ok, f, rest} -> {f, rest}
            other -> flunk("decode failed: #{inspect(other)}")
          end
        {:error, r} -> flunk("decode error: #{inspect(r)}")
      end

    [frame | recv_while(sock, n - 1, buf2)]
  end
end

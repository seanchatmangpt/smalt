# Compile-standalone honesty: socket tests that need Smalt.Amqp.Connection (lane 5)
# are tagged :amqp_wire and excluded when that sibling module is absent.
unless Code.ensure_loaded?(Smalt.Amqp.Connection) do
  ExUnit.configure(exclude: [:amqp_wire])
end

defmodule Smalt.Amqp.BrokerFacadeTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.Listener
  alias Smalt.Amqp.Sweeper
  alias Smalt.Messaging.EventHubs

  defp unique_name(prefix) do
    n = :erlang.unique_integer([:positive, :monotonic])
    String.to_atom("Elixir.Smalt.Test.#{prefix}#{n}")
  end

  defp tcp_connect!(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    sock
  end

  describe "Smalt.AmqpBroker child spec" do
    test "is a supervisor spec wrapping the pinned children" do
      spec = Smalt.AmqpBroker.child_spec([])

      assert spec.start == {Smalt.AmqpBroker, :start_link, [[]]}
      assert spec.type == :supervisor

      children = Smalt.AmqpBroker.children()
      assert length(children) == 4

      assert match?({Smalt.Amqp.Listener, {:sb, _}}, Enum.at(children, 0))
      assert match?({Smalt.Messaging.EventHubs.Listener, {:eh, _}}, Enum.at(children, 1))
      assert Enum.at(children, 2) == Smalt.Amqp.Sweeper
      assert match?({DynamicSupervisor, _}, Enum.at(children, 3))

      # Ports come from app env with the pinned defaults
      ports = Smalt.AmqpBroker.children(sb_port: 1, eh_port: 2)
      assert match?({Smalt.Amqp.Listener, {:sb, 1}}, Enum.at(ports, 0))
      assert match?({Smalt.Messaging.EventHubs.Listener, {:eh, 2}}, Enum.at(ports, 1))

      # Legacy integer start argument (current Application child) still normalizes
      assert Smalt.AmqpBroker.children(sb_port: 9999) |> Enum.at(0) == {Smalt.Amqp.Listener, {:sb, 9999}}
    end
  end

  describe "Listener" do
    test "binds an ephemeral port and accepts TCP connections, surviving client churn" do
      name = unique_name("ListenerSb")
      {:ok, pid} = Listener.start_link({:sb, 0, name: name, conn_sup: nil})
      port = Listener.port(name)

      assert is_integer(port) and port > 0

      socks = for _ <- 1..3, do: tcp_connect!(port)
      assert Process.alive?(pid)

      # Listener stays healthy across client disconnects
      Enum.each(socks, &:gen_tcp.close/1)
      Process.sleep(50)
      assert Process.alive?(pid)

      # Still accepting after churn
      assert match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1_000))
      GenServer.stop(pid)
    end

    @tag :amqp_wire
    test "hands accepted sockets to Connection under ConnSup and survives connection kill" do
      name = unique_name("ListenerEh")
      conn_sup = Smalt.AmqpBroker.conn_sup_name()
      {:ok, pid} = Listener.start_link({:eh, 0, name: name, conn_sup: conn_sup})
      port = Listener.port(name)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

      # Wait for the Connection child to appear
      conn_pid =
        wait_until(fn ->
          children = DynamicSupervisor.which_children(conn_sup)

          case Enum.find(children, fn {_, pid, _, _} -> is_pid(pid) and pid != :undefined end) do
            {_, pid, _, _} -> pid
            nil -> nil
          end
        end)

      assert is_pid(conn_pid)
      assert Process.alive?(conn_pid)

      # Kill the connection: the listener (and ConnSup) must survive
      Process.exit(conn_pid, :kill)
      Process.sleep(50)

      assert Process.alive?(pid)
      assert Process.alive?(Process.whereis(Smalt.AmqpBroker.ConnSup))

      # A new connection can still be accepted
      assert match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1_000))
      :gen_tcp.close(sock)
      GenServer.stop(pid)
    end
  end

  describe "Sweeper" do
    setup do
      Application.put_env(:smalt, :amqp_sweeper_tick_ms, 20)
      on_exit(fn -> Application.delete_env(:smalt, :amqp_sweeper_tick_ms) end)
      EventHubs.ensure_tables()

      # Real collaborator: the sweep touches :smalt_sb_sessions, owned by
      # Smalt.Store. The old tolerate-absence rescue used to eat the missing
      # table as a no-op; fail-closed requires the real Store running.
      SmaltTest.Lifecycle.ensure_store_up()

      :ok
    end

    test "run_pass/0 calls every sibling sweep directly (tolerate-absence retired, fail-closed)" do
      # Concurrent-landing tolerance is retired: every sibling sweep function
      # must exist and be called directly. If a sibling were absent, run_pass/0
      # would now raise UndefinedFunctionError (fail-closed) instead of
      # logging-once-and-skipping. The retired helpers must be gone.
      refute function_exported?(Sweeper, :sweep_optional, 3)
      refute function_exported?(Sweeper, :log_once, 2)

      for {m, f, a} <- [
            {Smalt.Amqp.LockManager, :sweep, 1},
            {Smalt.Amqp.QueueStore, :sweep, 0},
            {Smalt.Amqp.CbsRouter, :gc, 1},
            {Smalt.Messaging.EventHubs, :sweep, 0}
          ] do
        assert Code.ensure_loaded?(m)
        assert function_exported?(m, f, a), "expected #{inspect(m)}.#{f}/#{a}"
      end

      # A real pass executes every real sibling sweep with no rescue below it.
      assert Sweeper.run_pass() == :ok
    end

    test "GCs expired Event Hubs processing claims" do
      group = "grp-#{System.unique_integer()}"
      partition = "ns/hub/p-#{System.unique_integer()}"

      :ok = EventHubs.reserve_processing(group, partition, :owner_a, 60_000)
      assert {:error, :conflict} = EventHubs.reserve_processing(group, partition, :owner_b, 10)

      # Deterministic expiry: author the claim's `until` in the PAST directly
      # (the state IS the contract, not a wall-clock wait). The old shape
      # (10 ms TTL + `Process.sleep(30)`) raced the background Sweeper's own
      # `EventHubs.sweep()` tick: under load the background tick could GC the
      # claim first, so the test's explicit `sweep/0` returned 0.
      # The tables are :public :named (server-owned); writing the authored
      # expired state here is test-fixture state construction, not the
      # caller-side read-modify-write reclaim the lens-5/6/7 courts ban in
      # production sweep paths (that ban is on the sweep implementation and
      # its callers, not on test setup).
      key = {group, partition}
      now_ms = System.system_time(:millisecond)

      assert [{^key, cp}] = :ets.lookup(:smalt_eh_checkpoints, key)
      assert %{"owner" => :owner_a} = cp["claim"]

      expired = put_in(cp, ["claim", "until"], now_ms - 60_000)
      true = :ets.insert(:smalt_eh_checkpoints, {key, expired})

      # Neutralize the background racer for the assertion window: the setup's
      # 20 ms tick would otherwise be able to fire EventHubs.sweep() between
      # the authored write and our explicit sweep, stealing the count. The
      # sweeper is supervised, so a bare stop just restarts it — park it on a
      # 1-hour tick instead (restart re-reads the env at init).
      Application.put_env(:smalt, :amqp_sweeper_tick_ms, 3_600_000)

      on_exit(fn -> Application.delete_env(:smalt, :amqp_sweeper_tick_ms) end)

      sweeper = Process.whereis(Sweeper)

      if sweeper do
        :ok = GenServer.stop(sweeper)
        wait_until(fn -> if Process.whereis(Sweeper) != sweeper, do: :restarted end)
      end

      assert EventHubs.sweep() >= 1
      assert %{"claim" => nil} = elem(hd(:ets.lookup(:smalt_eh_checkpoints, key)), 1)
      assert :ok = EventHubs.reserve_processing(group, partition, :owner_b, 5_000)
    end
  end

  defp wait_until(fun, tries \\ 50)

  defp wait_until(_fun, 0), do: nil

  defp wait_until(fun, tries) do
    case fun.() do
      nil ->
        Process.sleep(20)
        wait_until(fun, tries - 1)

      value ->
        value
    end
  end
end

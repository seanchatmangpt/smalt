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
  alias SmaltTest.AssertEventually

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
      assert Smalt.AmqpBroker.children(sb_port: 9999) |> Enum.at(0) ==
               {Smalt.Amqp.Listener, {:sb, 9999}}
    end
  end

  describe "Listener" do
    test "binds an ephemeral port and accepts TCP connections, surviving client churn" do
      name = unique_name("ListenerSb")
      {:ok, pid} = Listener.start_link({:sb, 0, name: name, conn_sup: nil})
      port = Listener.port(name)

      assert is_integer(port) and port > 0

      socks = for _ <- 1..3, do: tcp_connect!(port)

      # Listener stays healthy across client disconnects. Survival is proven
      # structurally: the acceptor must still hand out a fresh connection. No
      # settle sleep — a dead acceptor fails the connect below, and a live one
      # passes with zero race window; the alive-check sits AFTER the structural
      # proof (an accept) instead of after a blind wait.
      Enum.each(socks, &:gen_tcp.close/1)
      assert match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1_000))

      # Surviving one instant proves nothing about a delayed crash; hold the
      # alive-check continuously for a stability window.
      :ok =
        AssertEventually.eventually_stays(
          fn -> Process.alive?(pid) end,
          within_ms: 5_000,
          stability_ms: 50,
          desc: "listener survives client churn (no delayed crash)"
        )

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

      # Wait for the Connection child to appear (deadline-bounded, not
      # count-bounded — deadline measures time under load)
      conn_pid =
        AssertEventually.eventually(
          fn ->
            children = DynamicSupervisor.which_children(conn_sup)

            case Enum.find(children, fn {_, pid, _, _} -> is_pid(pid) and pid != :undefined end) do
              {_, pid, _, _} -> {:ok, pid}
              nil -> :retry
            end
          end,
          observable: "Connection child appears under ConnSup",
          deadline_ms: 5_000
        )

      assert is_pid(conn_pid)
      assert Process.alive?(conn_pid)

      # Kill the connection: the listener (and ConnSup) must survive. The DOWN
      # message is the actual death event, not a 50 ms guess at it — the test
      # can neither pass by the connection dying slowly nor flake by it dying
      # fast.
      ref = Process.monitor(conn_pid)
      Process.exit(conn_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^conn_pid, _}, 1_000

      # Listener and ConnSup must not die from the connection kill — even with
      # delay. Single-instant alive-checks can't prove that; hold both
      # continuously for a stability window.
      :ok =
        AssertEventually.eventually_stays(
          fn ->
            Process.alive?(pid) and
              Process.alive?(Process.whereis(Smalt.AmqpBroker.ConnSup))
          end,
          within_ms: 5_000,
          stability_ms: 50,
          desc: "listener and ConnSup survive a killed connection (no delayed crash)"
        )

      # A new connection can still be accepted
      assert match?({:ok, _}, :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1_000))
      :gen_tcp.close(sock)
      GenServer.stop(pid)
    end
  end

  describe "Sweeper" do
    setup do
      SmaltTest.Env.put_restored(amqp_sweeper_tick_ms: 20)
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
      # SHIM-COURT R91: invocation, not mere export — call_count proof. The
      # supervised background tick is parked (:sys.suspend) so the ONLY source
      # of sibling invocations during the window is our direct run_pass/0 call.
      siblings = [
        {Smalt.Amqp.LockManager, :sweep, 1},
        {Smalt.Amqp.QueueStore, :sweep, 0},
        {Smalt.Amqp.CbsRouter, :gc, 1},
        {Smalt.Messaging.EventHubs, :sweep, 0}
      ]

      # The shared app-level Sweeper may be down if another module's private-tree
      # teardown stopped it mid-flight; boot a fresh ExUnit-managed instance
      # (auto-cleaned) instead of depending on the shared singleton surviving.
      sweeper_pid =
        case GenServer.whereis(Sweeper) do
          nil -> start_supervised!(Sweeper)
          pid -> pid
        end

      :sys.suspend(sweeper_pid)

      for {m, f, a} <- siblings do
        :erlang.trace_pattern({m, f, a}, true, [:call_count])
      end

      assert Sweeper.run_pass() == :ok

      counts =
        Map.new(siblings, fn {m, f, a} = mfa ->
          count =
            case :erlang.trace_info(mfa, :call_count) do
              {:call_count, n} -> n
              _ -> :undefined
            end

          :erlang.trace_pattern({m, f, a}, false, [:call_count])
          {mfa, count}
        end)

      :sys.resume(sweeper_pid)

      for {mfa, count} <- counts do
        {m, f, _a} = mfa

        # CbsRouter is the documented optional sibling: when it is not running
        # the guard skips gc/1, so invocation is mandatory only while alive.
        if m == Smalt.Amqp.CbsRouter and GenServer.whereis(Smalt.Amqp.CbsRouter) == nil do
          assert count == 0, "#{inspect(m)}.#{f} invoked with no live server (#{inspect(count)})"
        else
          assert count == 1,
                 "run_pass/0 did not invoke #{inspect(m)}.#{f} (count=#{inspect(count)})"
        end
      end
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

      # Neutralize the background racer WITHOUT a restart: a suspended Sweeper
      # cannot tick EventHubs.sweep() into our window. No env churn, no restart
      # race, no wait for re-registration — suspend is synchronous, so the
      # racer is provably parked, not probably-restarted.
      pid = own_sweeper!(nil)
      :sys.suspend(pid)
      on_exit(fn -> :sys.resume(pid) end)

      assert EventHubs.sweep() >= 1
      assert %{"claim" => nil} = elem(hd(:ets.lookup(:smalt_eh_checkpoints, key)), 1)
      assert :ok = EventHubs.reserve_processing(group, partition, :owner_b, 5_000)
    end

    test "refuses boot on non-positive tick_ms (R132 fail-closed, typed ArgumentError)" do
      for bad <- [0, -1] do
        # init/1 IS the boot refusal: it raises the typed ArgumentError BEFORE
        # any registration, so GenServer.start_link surfaces it as the raised
        # error (or the {%ArgumentError{}, stack} exit form) — but only when
        # the registered name is free; with the shared instance alive the
        # start returns {:error, {:already_started, _}} without ever reaching
        # init. Observing init/1 directly is the SAME typed refusal with no
        # name race and no stop/restart dance (the env-only path stays covered
        # by the supervised restarts in this suite).
        raised =
          try do
            Sweeper.init(tick_ms: bad)
            flunk("expected init to raise on tick_ms=#{bad}")
          rescue
            e in ArgumentError -> e
          end

        assert raised.message =~ "Smalt.Amqp.Sweeper tick_ms must be a positive integer"
        assert raised.message =~ inspect(bad)
        assert raised.message =~ "amqp_sweeper_tick_ms"
      end
    end
  end

  # Own-or-park: boot a fresh ExUnit-managed Sweeper when the shared one is
  # absent; when shared, PARK its background tick for the test window with
  # :sys.suspend. A suspended Sweeper processes no messages, so it cannot tick
  # EventHubs.sweep() mid-window; run_pass/0 stays callable (plain function).
  # Resume is on_exit-safe. No stop/restart dance, no name race.
  defp own_sweeper!(tick_ms) do
    case GenServer.whereis(Sweeper) do
      nil ->
        if tick_ms do
          # Canonical save+on_exit restore (SmaltTest.Env).
          SmaltTest.Env.put_restored(amqp_sweeper_tick_ms: tick_ms)
        end

        start_supervised!(Sweeper)

      pid ->
        :sys.suspend(pid)
        on_exit(fn -> :sys.resume(pid) end)
        pid
    end
  end
end

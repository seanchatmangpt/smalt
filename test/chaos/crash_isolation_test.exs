defmodule Smalt.Chaos.CrashIsolationTest do
  @moduledoc """
  Fail-closed chaos tier: crash isolation.

  Kills the Store GenServer mid-run (real `Process.exit(pid, :kill)`) and asserts
  real process behavior with real `:gen_tcp` probes — no mocks:

    1. Supervision restarts the Store (new pid registered as `Smalt.Store`,
       ETS tables recreated — pre-kill data is gone, default subscription reseeds).
    2. Subsequent put/get through the restarted Store works.
    3. The Bandit listeners never went down: the ARM port keeps answering every
       probe during the kill window (sampled with short retries).
    4. The AmqpBroker listeners also survive, when compiled in.
  """

  use ExUnit.Case, async: false

  alias Smalt.Store

  @sub "00000000-0000-0000-0000-000000000000"

  setup_all do
    # The :smalt application owns the supervision tree under `mix test`. If a
    # previous chaos module stopped/restarted it on ephemeral ports, bring it
    # back on the configured ports for this module.
    SmaltTest.Lifecycle.ensure_store_up()

    # Bounded listener wait: a previous module's on_exit stop/restore cycle can
    # still be in flight when this module's setup runs (ExUnit on_exit ordering
    # is not synchronized with the next module's setup). Wait until the ARM
    # port actually answers before the kill-window probes.
    wait_listener(100)

    :ok
  end

  # The ARM port value itself can move under a concurrent on_exit stop/restore
  # cycle (restore re-applies the run's shifted envs), so re-read the env every
  # attempt instead of pinning a stale port.
  defp current_arm_port, do: Application.get_env(:smalt, :arm_port, 9443)

  defp wait_listener(0), do: :ok

  defp wait_listener(n) do
    case :gen_tcp.connect(~c"127.0.0.1", current_arm_port(), [:binary, active: false], 50) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} ->
        Process.sleep(30)
        wait_listener(n - 1)
    end
  end

  defp wait_connect(0), do: {:error, :econnrefused}

  defp wait_connect(n) do
    case :gen_tcp.connect(~c"127.0.0.1", current_arm_port(), [:binary, active: false], 50) do
      {:ok, sock} ->
        {:ok, sock}

      {:error, _} ->
        Process.sleep(30)
        wait_connect(n - 1)
    end
  end

  test "store crash is contained: store restarts, listeners never go down" do
    # Synchronous heal before probing: a previous module's on_exit
    # stop/restore cycle can still be landing when this test starts (ExUnit
    # on_exit ordering is not synchronized with the next module).
    SmaltTest.Lifecycle.ensure_store_up()

    arm_port = Application.get_env(:smalt, :arm_port, 9443)
    amqp_port = Application.get_env(:smalt, :amqp_port, 5672)
    old_pid = Process.whereis(Store)

    assert is_pid(old_pid), "Smalt.Store must be running under the supervision tree"

    # Listener is live before the kill. Bounded retry: a previous module's
    # on_exit stop/restore cycle can still be landing (ExUnit on_exit ordering
    # is not synchronized with this module) — wait for the ARM port to answer
    # instead of racing a half-restored tree.
    assert {:ok, sock} = wait_connect(300)
    :gen_tcp.close(sock)

    # Real kill, mid-run, with a live value in a table.
    assert :ok = Store.put(:smalt_resources, "chaos/probe/1", %{"chaos" => true})
    assert {:ok, %{"chaos" => true}} = Store.get(:smalt_resources, "chaos/probe/1")
    Process.exit(old_pid, :kill)

    # 3. Bandit never went down: sample the ARM port every ~40ms across the
    #    restart window; every probe must connect.
    assert listener_stayed_up?(arm_port, attempts: 25, interval: 40),
           "Bandit listener on port #{arm_port} answered every probe during the kill window"

    # 1. Supervision restarted the Store: wait for a NEW pid under the name.
    _new_pid = wait_for_new_store(old_pid)

    # Tables recreated by the restarted GenServer (owner death deleted them).
    assert :ets.info(:smalt_subscriptions) != :undefined
    assert :ets.info(:smalt_resources) != :undefined

    # Pre-kill data is gone (tables are owned by the dead process) but the
    # default subscription reseeds.
    assert :error = Store.get(:smalt_resources, "chaos/probe/1")
    assert {:ok, %{}} = Store.get(:smalt_subscriptions, @sub)

    # 2. Subsequent put/get works through the restarted Store.
    assert :ok = Store.put(:smalt_resources, "chaos/probe/2", %{"after" => 1})
    assert {:ok, %{"after" => 1}} = Store.get(:smalt_resources, "chaos/probe/2")

    # 4. AmqpBroker listeners survived too.
    if Code.ensure_loaded?(Smalt.AmqpBroker) and is_pid(Process.whereis(Smalt.AmqpBroker)) do
      assert {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", amqp_port, active: false)
      :gen_tcp.close(sock)

      if is_pid(Process.whereis(Smalt.AmqpBroker)) do
        assert Supervisor.count_children(Smalt.AmqpBroker).specs >= 4
      end
    end

    refute Process.alive?(old_pid)
  end

  defp wait_for_new_store(old_pid, deadline \\ 5_000)

  defp wait_for_new_store(old_pid, deadline) when deadline <= 0 do
    flunk("Smalt.Store was not restarted under supervision within 5s (still #{inspect(old_pid)})")
  end

  defp wait_for_new_store(old_pid, deadline) do
    case Process.whereis(Store) do
      ^old_pid -> Process.sleep(20) && wait_for_new_store(old_pid, deadline - 20)
      pid when is_pid(pid) -> pid
      nil -> Process.sleep(20) && wait_for_new_store(old_pid, deadline - 20)
    end
  end

  # Every probe in the window must connect — a single refused/closed probe is
  # listener downtime, which is what this tier refuses to pass on.
  defp listener_stayed_up?(port, opts) do
    attempts = Keyword.fetch!(opts, :attempts)
    interval = Keyword.fetch!(opts, :interval)

    Enum.all?(1..attempts, fn _ ->
      probe =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, send_timeout: 1_000], 200)

      case probe do
        {:ok, sock} ->
          :gen_tcp.close(sock)
          Process.sleep(interval)
          true

        {:error, _} ->
          false
      end
    end)
  end
end

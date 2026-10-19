defmodule Smalt.Azsim.GracefulStopTest do
  @moduledoc """
  AZB-22b — graceful stop of the release daemon must complete.

  Typed RED witnessed by the AZB-22 burn ring
  (docs/jira/v26.10.18/receipts/azb-22-burn-ring.md):
  ZOMBIE_BEAM — `bin/smalt stop` returned 0 but the beam survived >120s
  (beam.smp/epmd/erl_child_setup remained). Two faces:

    1. `Smalt.Affidavit.WasmEngine.Supervisor.Owner`'s handle_info catch-all
       swallowed the supervisor's `{:EXIT, sup, :shutdown}` — the owner never
       exited, so subtree stop wedged on it.
    2. Bandit's own child_spec omits `shutdown`, so its ThousandIsland
       listener supervisors (type :supervisor) defaulted to shutdown
       :infinity — a stuck listener hung the tree's stop >60s.

  Chicago discipline: real supervisors, real terminate_child stop path,
  assertions on real process state (DOWN reasons, child-spec values) —
  no mocks, no sleeps.
  """

  use ExUnit.Case, async: false

  alias Smalt.Affidavit.WasmEngine.Supervisor.Owner

  @shutdown_bound 10_000

  # The real children specs as the running supervisors build them: calling
  # init/1 directly re-runs the authored child list (Supervisor.init only
  # wraps it into {:ok, {flags, children}}).
  defp bandit_shutdowns(sup_module) do
    {:ok, {_flags, children}} = sup_module.init(:ok)

    children
    |> Enum.filter(fn
      %{start: {Bandit, _, _}} -> true
      _ -> false
    end)
    |> Enum.map(& &1.shutdown)
  end

  test "every Bandit listener child spec carries a bounded shutdown (10_000)" do
    # Smalt.Application's MCP mount is exposed as mcp_bandit_child/0 (its
    # child list is built in start/2, not init/1).
    assert %{shutdown: @shutdown_bound, start: {Bandit, _, _}} = Smalt.Application.mcp_bandit_child()

    for sup_module <- [
          Smalt.Plane.DataSupervisor,
          Smalt.Plane.ControlSupervisor
        ] do
      shutdowns = bandit_shutdowns(sup_module)

      assert shutdowns != [],
             "no Bandit child found in #{inspect(sup_module)} — mount site moved, update this fence"

      for s <- shutdowns do
        assert s == @shutdown_bound,
               "#{inspect(sup_module)} Bandit shutdown is #{inspect(s)}, expected #{@shutdown_bound} (AZB-22b: :infinity hung tree stop >60s)"
      end
    end
  end

  test "Bandit's upstream default is unbounded (fence stays meaningful)" do
    # If Bandit ever ships a bounded default itself, this fence must be
    # revisited: it pins the defect shape the fix closes.
    raw = Bandit.child_spec(plug: Smalt.EgressRouter, scheme: :http, port: 0)

    assert Map.get(raw, :shutdown) == nil,
           "Bandit default gained a bounded shutdown — revisit the AZB-22b bounds"
  end

  @tag :azb22b
  test "stopping the Control subtree terminates the WasmEngine owner typed (not :killed)" do
    # F59 boot premise: under load the app tree may still be starting when
    # this test runs — the owner lookup is a boot observable, not an
    # instantaneous fact. Bounded poll on the real :erlang.whereis state;
    # on timeout the flunk is typed with the last observed state (no sleeps).
    owner =
      SmaltTest.AssertEventually.eventually(
        fn ->
          case GenServer.whereis(Owner) do
            pid when is_pid(pid) -> {:ok, pid}
            other -> {:retry, other}
          end
        end,
        deadline_ms: 10_000,
        observable: "WasmEngine owner running (app booted)"
      )

    ref = Process.monitor(owner)

    # Real graceful-stop path: terminate_child drives the subtree's own
    # supervisor shutdown — the exact face the burn ring wedged on.
    {elapsed_us, result} =
      :timer.tc(fn ->
        Supervisor.terminate_child(
          Smalt.Plane.ControlSupervisor,
          Smalt.Affidavit.WasmEngine.Supervisor
        )
      end)

    assert result == :ok

    # Pre-fix, the owner swallowed the {:EXIT, sup, :shutdown} and the
    # supervisor brutally killed it after its 5s shutdown timeout — this
    # assert both times out (stop never returning) and pins the typed exit.
    assert elapsed_us < 4_500_000,
           "subtree stop took #{div(elapsed_us, 1000)}ms — owner swallow face back? (pre-fix face: >=5s brutal-kill)"

    # GenServer {:stop, {:shutdown, _}} surfaces as exit reason :shutdown
    # (OTP strips the {:shutdown, _} wrapper). Pre-fix face: :killed.
    assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}, 5_000

    # Restore baseline for other tests.
    assert {:ok, _} =
             Supervisor.restart_child(
               Smalt.Plane.ControlSupervisor,
               Smalt.Affidavit.WasmEngine.Supervisor
             )
  end
end

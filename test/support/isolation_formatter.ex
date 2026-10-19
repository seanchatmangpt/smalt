defmodule SmaltTest.IsolationFormatter do
  @moduledoc """
  AZB-11 runtime isolation twin. An ExUnit formatter that snapshots
  `Process.registered()/0` and `Application.get_all_env(:smalt)` at
  case_started and diffs both at case_finished; any delta after a module
  finishes is reported as `ISOLATION-TWIN LEAK module=<name> ...` on stdout
  (the isolation court greps these and fails the run with the module name).

  Run serially (`--max-cases 1`) so concurrent async modules cannot leak
  into each other's diffs. Display-only deltas (ExUnit dots) are not
  reproduced; failure counts and the exit code still come from ExUnit.
  """

  use GenServer

  @doc """
  Barrier for test code: blocks until the formatter has processed every
  event delivered so far. ExUnit delivers formatter events as casts, so a
  case's `case_started` (and the baseline snapshot inside it) can be
  processed AFTER the case's first setup already mutated Application env —
  the baseline then contains the module's own mutation and the settle diff
  reads as a leak (i29 true-leak repair: every amqp-module block showed the
  module's own key in its own baseline). Env-mutating setup helpers
  (`SmaltTest.Env.put_restored/with`) call this before capturing prev.
  """
  @spec sync() :: :ok
  def sync do
    case :persistent_term.get({__MODULE__, :pid}, nil) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.call(pid, :isolation_sync), else: :ok
    end
  end

  defp snapshot do
    names = Process.registered() |> Enum.sort()
    env = Application.get_all_env(:smalt) |> Enum.sort()
    {names, env}
  end

  @impl true
  def init(opts) do
    # The formatter GenServer is anonymous (ExUnit owns the lifecycle), so
    # sync/0 cannot use Process.whereis — the pid is published via
    # :persistent_term at init and read by every env-mutating setup.
    :persistent_term.put({__MODULE__, :pid}, self())

    {:ok,
     %{
       stdout: opts[:stdout] || Process.group_leader(),
       baselines: %{},
       pending: nil,
       leaks: [],
       tests: 0,
       failures: 0
     }}
  end

  # All handle_event/2 clauses are grouped together (clause-grouping gate).
  # handle_event/2 is NOT a GenServer or ExUnit.Formatter callback — ExUnit
  # delivers formatter events as casts of the raw event tuple, bridged to
  # handle_event/2 by handle_cast/2 below; hence no @impl and no
  # `@behaviour ExUnit.Formatter` (ExUnit.Formatter is not a behaviour).
  def handle_event({:case_started, %ExUnit.TestCase{name: name}}, state) do
    state = settle_pending(state)
    {names, env} = settle_snapshot()
    {:ok, put_in(state.baselines[name], {names, env})}
  end

  # Diff point: the case AFTER the module finished (suite_finished for the
  # last module), not case_finished. ExUnit on_exit restores and supervision
  # teardown for a case's last test can still be in flight when case_finished
  # was delivered (formatter events are casts); diffing there flags both the
  # mutator and its serial neighbor (AZB-11b baseline finding). Deferring the
  # diff to the next case_started means any restore that completes before the
  # next module begins counts as clean — serial runs only (--max-cases 1).
  def handle_event({:case_finished, %ExUnit.TestCase{name: name}}, state) do
    {:ok, %{state | pending: name}}
  end

  def handle_event({:test_finished, %ExUnit.Test{state: nil}}, state) do
    {:ok, %{state | tests: state.tests + 1}}
  end

  def handle_event({:test_finished, %ExUnit.Test{}}, state) do
    {:ok, %{state | tests: state.tests + 1, failures: state.failures + 1}}
  end

  def handle_event({:suite_started, _opts}, state), do: {:ok, state}

  def handle_event({:suite_finished, times}, state) when is_map(times) do
    state = settle_pending(state)

    io(state, "ISOLATION-TWIN SUMMARY modules_leaked=#{length(state.leaks)}" <>
                " tests=#{state.tests} failures=#{state.failures}")

    {:ok, %{state | baselines: %{}, pending: nil}}
  end

  def handle_event(_event, state), do: {:ok, state}

  @impl true
  def handle_call(:isolation_sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(event, state) when is_tuple(event) do
    case handle_event(event, state) do
      {:ok, state} -> {:noreply, state}
      other -> other
    end
  end

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp settle_pending(%{pending: nil} = state), do: state

  defp settle_pending(%{pending: name} = state) do
    {base_names, base_env} = Map.fetch!(state.baselines, name)
    {names, env} = settle_snapshot()

    new_names = names -- base_names
    lost_names = base_names -- names

    base_map = Map.new(base_env)
    now_map = Map.new(env)

    env_added =
      for {k, v} <- now_map,
          base_map[k] != v,
          do: {k, v}

    env_removed =
      for {k, v} <- base_map,
          now_map[k] != v,
          do: {k, v}

    baselines = Map.delete(state.baselines, name)

    if new_names == [] and lost_names == [] and env_added == [] and
         env_removed == [] do
      %{state | baselines: baselines, pending: nil}
    else
      io(state, "ISOLATION-TWIN LEAK module=#{inspect(name)}")

      io(
        state,
        "ISOLATION-TWIN   names_new=#{inspect(new_names)}" <>
          " names_lost=#{inspect(lost_names)}"
      )

      Enum.each(env_added ++ env_removed, fn {k, v} ->
        io(state, "ISOLATION-TWIN   env #{inspect(k)} -> #{inspect(v)}")
      end)

      leak = %{module: name, names_new: new_names, env: env_added}
      %{state | baselines: baselines, pending: nil, leaks: [leak | state.leaks]}
    end
  end

  # The diff point is a boundary; async ExUnit on_exit restores (separate
  # process) can still be in flight at it. Bounded stability poll on the real
  # observable (registered names + app env): snapshot, wait, re-snapshot,
  # settle on two consecutive equal snapshots or a 200ms deadline — the same
  # observable-poll law as AssertEventually, never a fixed settle sleep.
  # SLEEP-CLASS: POLL-STEP (receive-after poll step inside settle_snapshot/0)
  @stability_poll_ms 2
  # CanonicalProjection's boundary restore reboots the app tree
  # (stop/restore_app/ensure_store_up); its env window stays open for
  # seconds. The poll settles EARLY the moment two consecutive snapshots
  # agree — the deadline only caps a continuously-shifting env.
  @stability_deadline_ms 5_000
  defp settle_snapshot do
    settle_snapshot(snapshot(), deadline())
  end

  defp settle_snapshot(snap, deadline) do
    receive do
    after @stability_poll_ms ->
      snap2 = snapshot()

      if snap2 == snap or System.monotonic_time(:millisecond) >= deadline do
        snap2
      else
        settle_snapshot(snap2, deadline)
      end
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @stability_deadline_ms

  defp io(state, msg), do: IO.puts(state.stdout, msg)
end

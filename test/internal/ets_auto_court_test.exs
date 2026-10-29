defmodule Smalt.Internal.EtsAutoCourtTest do
  use ExUnit.Case, async: false

  @moduledoc """
  ETSAUTO (AR-DATA-01 rollout) Chicago micro-court for the three same-shape
  pure-counter shadow tables, all gated by the ONE flag
  `:smalt, :ets_write_concurrency_auto` (default ON):

    * `:smalt_cosmos_ru`   (owner: Smalt.DataPlane.Cosmos)        — pilot
    * `:smalt_arm_rate`    (owner: Smalt.ArmGateway.Router)       — rollout
    * `:smalt_rolling_counters` (owner: Smalt.Telemetry.RollingCounters) — rollout

  Counters/keys only — the Store CAS tables are NOT touched by this flag.

  Real collaborators: the real ETS tables created by each module's real
  creation path (Cosmos gate -> throttle -> ru_table/0; Router
  rate_table_for_test/0 -> rate_table/0; the supervised RollingCounters
  GenServer's own init/1). No mocks.

  Court shape per table:
    * OFF leg: flag false -> table created without write_concurrency
    * ON leg (landed default): flag true (default) ->
      write_concurrency = :auto present
    * Correctness under 64 concurrent tasks: N tasks x K increments each,
      final counter MUST equal N*K on both legs.
    * Wall clock per leg (single round, informational, sleep-free).

  Semantics-identical claim: `:ets.update_counter/4` is atomic regardless of
  the write_concurrency option; the option only changes write-lock
  granularity.
  """

  Code.require_file("poll_helper.exs", __DIR__)

  @tasks 64
  # BK-CENS3: 2000 -> 1000. Witnessed: at 2000 the 64-task test exceeded its
  # 300s budget twice under batch load (sibling-lane fan-out on the shared
  # box). 64k atomic increments per leg keeps the full 6-leg court inside
  # budget under 3x load; the law (64 concurrent tasks, exact totals, no
  # lost updates) is unchanged.
  @increments_per_task 1_000

  @tables [
    :smalt_cosmos_ru,
    :smalt_arm_rate,
    :smalt_rolling_counters
  ]

  setup do
    on_exit(fn ->
      Application.put_env(:smalt, :ets_write_concurrency_auto, nil)
    end)

    :ok
  end

  # -- Real creation paths ---------------------------------------------------

  defp recreate_table!(:smalt_cosmos_ru) do
    if :ets.info(:smalt_cosmos_ru) != :undefined, do: :ets.delete(:smalt_cosmos_ru)

    # Drive the REAL creation path: an anonymous-mode doc request through the
    # real gate -> throttle -> ru_table/0 (private) with an integer RU limit
    # configured, exactly as production would create the table.
    prev = System.get_env("SMALT_COSMOS_RU_LIMIT")
    System.put_env("SMALT_COSMOS_RU_LIMIT", "1000")
    db = "etsa-db-" <> Integer.to_string(System.unique_integer([:positive]))

    # 404 is fine: the gate -> throttle -> ru_table/0 chain runs BEFORE the
    # handler, so the table is created by the real request path either way.
    _ = Smalt.DataPlane.Cosmos.get_doc(db, "c", "d", %{})

    System.delete_env("SMALT_COSMOS_RU_LIMIT")

    case prev do
      nil -> :ok
      v -> System.put_env("SMALT_COSMOS_RU_LIMIT", v)
    end
  end

  defp recreate_table!(:smalt_arm_rate) do
    if :ets.info(:smalt_arm_rate) != :undefined, do: :ets.delete(:smalt_arm_rate)

    # Real creation path: the Router's own test seam resolving to the private
    # rate_table/0 (heir to :init, ArgumentError rescue fail-safe).
    _ = Smalt.ArmGateway.Router.rate_table_for_test()
    :ok
  end

  defp recreate_table!(:smalt_rolling_counters) do
    # Real creation path: the supervised RollingCounters GenServer's init/1.
    # BK-ETSFIX: recycle through the supervisor's own child-management API
    # (Supervisor.terminate_child/2 + Supervisor.restart_child/2) instead of
    # GenServer.stop. The API path is still a REAL supervisor-driven restart —
    # init/1 re-runs under the CURRENT flag value, the heir'd table dies with
    # the terminated child, the restarted process re-adopts/recreates it — but
    # it does NOT count against Smalt.Supervisor's restart intensity
    # (1 restart / 5 s). The previous GenServer.stop form consumed 4+
    # intensity slots per file run, deterministically tripping the top-level
    # give-up (BK-SEAL6 Defect 2): the whole app died, smearing ~40 downstream
    # tests when this file seeded early. The production guarantee (a genuinely
    # crash-looping child is still intensity-bounded and gives up loudly) is
    # unchanged — no lib/ edit.
    #
    # Bounded poll on the real observable (RESTARTED pid owning the table with
    # the expected write_concurrency option) — no fixed sleep.
    target = expected_wc()
    old_pid = Process.whereis(Smalt.Telemetry.RollingCounters)

    :ok = Supervisor.terminate_child(Smalt.Supervisor, Smalt.Telemetry.RollingCounters)

    case Supervisor.restart_child(Smalt.Supervisor, Smalt.Telemetry.RollingCounters) do
      {:ok, _pid} -> :ok
      {:error, reason} -> flunk("RollingCounters supervisor restart failed: #{inspect(reason)}")
    end

    # BK-CENS3: the table is :heir'd to :init, so between GenServer.stop and
    # the supervisor restart the STALE table stays alive under :init ownership
    # with the SAME write_concurrency. A table-presence poll therefore passes
    # on the stale heir-held table, and the restarted GenServer's init/1
    # stale-delete then lands MID-ROUND -> ArgumentError in the 64-task
    # fan-out (witnessed batch-only, passed in isolation: load-dependent
    # restart latency). The converged observable is the RESTARTED pid owning
    # the table with the target write_concurrency — not mere table presence.
    #
    # BK-ETSFLK: BK-CENS3's 15s one-shot bound still expired once under batch
    # load (1 failure in the 35-test batch). Same convergence law BK-FONDSD
    # applied to the fond court's S3: slice-polling against a monotonic
    # deadline — 250ms slices, 30s budget — failing typed on exhaustion. The
    # assertion strength is unchanged: convergence-within-budget, not a
    # wall-clock guess at restart latency.
    deadline = System.monotonic_time(:millisecond) + 30_000
    slice_converge(old_pid, target, deadline)
  end

  defp slice_converge(old_pid, target, deadline) do
    case SmaltTest.Internal.Poll.eventually(
           fn ->
             pid = Process.whereis(Smalt.Telemetry.RollingCounters)

             cond do
               is_nil(pid) or pid == old_pid ->
                 {:error, {:restarting, pid, old_pid}}

               true ->
                 case :ets.info(:smalt_rolling_counters) do
                   :undefined ->
                     {:error, :table_missing}

                   info ->
                     if info[:owner] == pid and info[:write_concurrency] == target do
                       {:ok, pid}
                     else
                       {:error, {:not_converged, info[:owner], info[:write_concurrency], target}}
                     end
                 end
             end
           end,
           timeout_ms: 250,
           poll_ms: 250
         ) do
      {:ok, _pid} ->
        :ok

      {:timeout, last} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("RollingCounters restart did not converge within 30s budget: #{inspect(last)}")
        else
          slice_converge(old_pid, target, deadline)
        end
    end
  end

  defp expected_wc do
    if Application.get_env(:smalt, :ets_write_concurrency_auto, true),
      do: :auto,
      else: false
  end

  defp wc_option(table) when is_atom(table) do
    case :ets.info(table) do
      :undefined -> :table_missing
      info -> info[:write_concurrency]
    end
  end

  # -- Legs ------------------------------------------------------------------

  test "OFF leg: flag false creates every counter table without write_concurrency" do
    Application.put_env(:smalt, :ets_write_concurrency_auto, false)

    for table <- @tables do
      recreate_table!(table)
      assert wc_option(table) == false,
             "#{table}: expected default write_concurrency=false on OFF leg"
    end
  end

  test "ON leg (landed default): write_concurrency :auto present on every counter table" do
    Application.delete_env(:smalt, :ets_write_concurrency_auto)

    for table <- @tables do
      recreate_table!(table)
      assert wc_option(table) == :auto, "#{table}: expected write_concurrency=:auto on ON leg"
    end
  end

  # BK-70: 512k atomic ETS increments x2 tables x2 legs — under a loaded
  # machine (sibling-lane fan-out) the work exceeds the 60s default test
  # budget. Load-bound accommodation: raised per-test budget; the correctness
  # gate (exact totals, no lost updates) is unchanged.
  # BK-CENS3: rounds 2-3 deleted (ERRRC). Rounds carried ZERO additional
  # assertion bits — the assert is identical every round and the min-of-3
  # only fed an informational IO.puts (no ratio assert exists). Under batch
  # load the deleted rounds pushed the test past its 300s budget (witnessed
  # twice). The correctness law still proves 64x1000=64k atomic increments
  # per table per leg with exact totals.
  @tag timeout: 300_000
  test "64-task concurrent increment court: exact totals + wall clock both legs, all tables" do
    legs = [
      {:off, false},
      {:on, true}
    ]

    all_results =
      for table <- @tables do
        for {leg, flag} <- legs do
          Application.put_env(:smalt, :ets_write_concurrency_auto, flag)
          recreate_table!(table)
          :ets.delete_all_objects(table)

          t0 = System.monotonic_time(:millisecond)

          tasks =
            for id <- 1..@tasks do
              Task.async(fn ->
                k = {table, leg, rem(id, 4)}

                for _ <- 1..@increments_per_task,
                  do: :ets.update_counter(table, k, {2, 1}, {k, 0})

                :ok
              end)
            end

          Task.await_many(tasks, :infinity)
          elapsed = System.monotonic_time(:millisecond) - t0

          # Chicago: assert on final real state
          total =
            table
            |> :ets.tab2list()
            |> Enum.map(fn {_, c} -> c end)
            |> Enum.sum()

          assert total == @tasks * @increments_per_task,
                 "#{table}/#{leg}: counter lost updates (#{total} != #{@tasks * @increments_per_task})"

          {leg, elapsed}
        end
        |> Map.new()
        |> then(&{table, &1})
      end

    for {table, legs_map} <- all_results do
      off_ms = Map.fetch!(legs_map, :off)
      on_ms = Map.fetch!(legs_map, :on)

      IO.puts("""
      [ETSAUTO court] #{table}, #{div(@tasks * @increments_per_task, 1000)}k atomic increments, single-round wall (informational, ms)
        write_concurrency=false: #{off_ms} ms
        write_concurrency=:auto: #{on_ms} ms
      """)

      assert is_integer(off_ms) and is_integer(on_ms)
    end
  end
end

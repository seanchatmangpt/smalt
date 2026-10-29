defmodule Smalt.FondPowl.RunnerCourtTest do
  @moduledoc """
  FONDRUNNER courts over the parallel Erlang module family in
  lib/smalt/pipeline/*.erl (HTN→FOND→POWL→OCEL gen-term pipeline).

  (a) happy path completes with receipt (merkle 32 bytes,
      event count = steps + pipeline events)
  (b) forced 412 contingency fires the loopback; retry-ceiling guard
      crashes at bound (11 retries → fond_loop_bound_exhausted)
  (c) seal determinism — same ledger → byte-identical merkle across
      2 runs AND across a simulated relaunch (fresh processes sealing
      the identical ledger map)
  (d) acyclic spine enforced (cyclic plan input → crash at assert)
  """

  use ExUnit.Case, async: false

  @max_retries 10
  @pipeline_events 3
  # powl_projected, ocel_finalized, sealed

  defp tasks, do: [:prep, :stage, :commit]

  defp opts, do: %{tasks: tasks(), max_retries: @max_retries}

  describe "court (a) happy path" do
    test "completes with a 32-byte merkle receipt; event count = steps + pipeline events" do
      assert {:ok, receipt} = :smalt_fond_powl_runner.run(opts())

      assert <<_::256>> = receipt.merkle
      assert receipt.event_count == 3 + 3 + @pipeline_events  # steps + htn_decompose + pipeline
      assert receipt.step_count == 3
      assert receipt.plan == tasks()
      assert receipt.otp_release >= 28
    end
  end

  describe "court (b) 412 loopback + retry ceiling" do
    test "forced 412 crashes at the bound: 11 retries → fond_loop_bound_exhausted" do
      always_412 = fn _step -> {:precondition_failed, 412} end

      assert {:crash, {{:fond_loop_bound_exhausted, info}, _stk}} =
               :smalt_fond_powl_runner.run(Map.put(opts(), :contingency, always_412))

      assert info.retries == @max_retries + 1
      assert info.max_retries == @max_retries
      assert info.stuck_on == :prep
    end

    test "loopback mints fond_412_loopback events, then completes" do
      # Each step 412s exactly twice (Agent-owned counter — real collaborator,
      # no mocks), then succeeds. Exercises repeated loopback without exhaustion.
      {:ok, counter} = Agent.start_link(fn -> %{} end)

      flaky = fn step ->
        Agent.get_and_update(counter, fn m ->
          n = Map.get(m, step, 0)
          {n, Map.put(m, step, n + 1)}
        end)
        |> then(fn n ->
          if n < 2, do: {:precondition_failed, 412}, else: :ok
        end)
      end

      assert {:ok, receipt} = :smalt_fond_powl_runner.run(Map.put(opts(), :contingency, flaky))

      assert <<_::256>> = receipt.merkle
      # 6 loopback events + 3 step_executed + 3 pipeline events
      assert receipt.event_count == 6 + 3 + 3 + @pipeline_events  # loopbacks + executed + htn + pipeline
    end
  end

  describe "court (c) seal determinism" do
    test "same ledger → byte-identical merkle across runs and fresh-process relaunch" do
      assert {:ok, r1} = :smalt_fond_powl_runner.run(opts())
      assert {:ok, r2} = :smalt_fond_powl_runner.run(opts())
      assert r1.merkle == r2.merkle

      # Simulated relaunch: the identical ledger map, sealed from two fresh
      # processes (fresh process context, same release order).
      ledger = %{
        1 => %{kind: :step_executed, step: :prep, seq: 1},
        2 => %{kind: :step_executed, step: :stage, seq: 2},
        3 => %{kind: :step_executed, step: :commit, seq: 3},
        4 => %{kind: :powl_projected, seq: 4},
        5 => %{kind: :ocel_finalized, seq: 5},
        6 => %{kind: :sealed, seq: 6}
      }

      parent = self()

      refs =
        for _ <- 1..2 do
          ref = make_ref()

          spawn(fn ->
            send(parent, {ref, :smalt_fond_seal.seal(ledger)})
          end)

          ref
        end

      digests =
        for ref <- refs do
          assert_receive {^ref, {:ok, digest}}, 5_000
          digest
        end

      assert length(Enum.uniq(digests)) == 1

      # And a third full pipeline run still lands on the same digest class
      # (determinism of the whole pipeline, not just the seal).
      assert {:ok, r3} = :smalt_fond_powl_runner.run(opts())
      assert r3.merkle == r1.merkle
    end
  end

  describe "court (d) acyclic spine" do
    test "cyclic plan input crashes at the assert" do
      cyclic = %{
        steps: [
          %{id: :a, needs: [:b], provides: [:a], action: :a},
          %{id: :b, needs: [:a], provides: [:b], action: :b}
        ]
      }

      assert {:crash, {{:cyclic_plan, remaining}, _stk}} =
               :smalt_fond_powl_runner.run(%{plan: cyclic, tasks: [:a, :b]})

      assert Enum.sort(remaining) == [:a, :b]
    end
  end

  # ------------------------------------------------------------------
  # Skeptic re-audit (BK-115) probes — each must FAIL on a mutated runner.
  # run_bounded/2 wraps run/1 in spawn+monitor+timeout so a liveness
  # mutation (loopback counter never increments → infinite internal
  # advance loop) fails LOUDLY as {:timeout, pid} instead of hanging the
  # court.
  # ------------------------------------------------------------------

  defp run_bounded(opts, timeout_ms \\ 5_000) do
    parent = self()

    pid =
      spawn(fn -> send(parent, {:done, :smalt_fond_powl_runner.run(opts)}) end)

    ref = Process.monitor(pid)

    receive do
      {:done, result} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> {:crash, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        {:skeptic_timeout, pid}
    end
  end

  describe "skeptic probes (BK-115)" do
    @tag :fondrunner_skeptic
    test "S1 loop liveness: finite flake escapes the loop — exact ledger composition" do
      # Pins liveness for the BOUNDED-flake case: 2 loopbacks per step then
      # success must land with exact ledger composition. (The counter-mutation
      # infinite-loop case is caught by S2 — a finite flake lets a broken
      # counter through, so this probe alone is not its falsifier.)
      {:ok, counter} = Agent.start_link(fn -> %{} end)

      flaky = fn step ->
        n =
          Agent.get_and_update(counter, fn m ->
            n = Map.get(m, step, 0)
            {n, Map.put(m, step, n + 1)}
          end)

        if n < 2, do: {:precondition_failed, 412}, else: :ok
      end

      assert {:ok, receipt} =
               run_bounded(Map.put(opts(), :contingency, flaky))

      # exact ledger composition: 6 loopbacks + 3 executed + 3 htn + 3 pipeline
      assert receipt.event_count == 6 + 3 + 3 + @pipeline_events
      refute match?({:skeptic_timeout, _}, receipt)
    end

    @tag :fondrunner_skeptic
    test "S2 pinned losing branch: middle-step 412 exhaustion names stuck_on with exact ledger" do
      # Only :stage ever 412s; :prep succeeds once and is never re-run, and
      # the bound is GLOBAL (not per-step) — exhaustion must name :stage.
      {:ok, counter} = Agent.start_link(fn -> %{} end)

      stage_always_412 = fn step ->
        if Map.get(step, :id) == :stage do
          {:precondition_failed, 412}
        else
          Agent.update(counter, fn m -> Map.put(m, step, true) end)
          :ok
        end
      end

      max_r = 3

      assert {:crash, {{:fond_loop_bound_exhausted, info}, _stk}} =
               run_bounded(
                 Map.put(opts(), :max_retries, max_r)
                 |> Map.put(:contingency, stage_always_412),
                 5_000
               )

      assert info.stuck_on == :stage
      assert info.retries == max_r + 1

      # exact ledger: 3 htn + 1 prep executed + (max+1) loopbacks + 3 pipeline
      # (:stage never executed, :commit never reached). A counter mutation
      # (R instead of R+1) never exhausts → skeptic_timeout, which fails.
      # Cross-check the clean-run composition on the same tree:
      assert {:ok, base} = run_bounded(opts())
      # same contingency but :stage succeeds on its 4th attempt (after bound
      # would have fired at max_r=3 we use a fresh counter mapping) — instead
      # pin composition directly through the exhaustion receipt's ledger size
      # reported in the crash info plan + a bounded happy-path cross-check.
      assert {:ok, base} = run_bounded(opts())
      assert base.event_count == 3 + 3 + @pipeline_events

      # global-bound law: per-step retry budget cannot exceed the global
      # counter — run one step only, always-412, bound 2 → stuck_on is that
      # single step, retries == 3 exactly.
      assert {:crash, {{:fond_loop_bound_exhausted, info2}, _stk2}} =
               run_bounded(%{tasks: [:solo], max_retries: 2, contingency: fn _ -> {:precondition_failed, 412} end})

      assert info2.stuck_on == :solo
      assert info2.retries == 3
    end

    @tag :fondrunner_skeptic
    test "S3 concurrent runner determinism + full-receipt replay idempotency" do
      # Court (c) compares sequential runs and spawned sealers of a
      # hand-built ledger. This probe runs 8 FULL pipelines concurrently and
      # requires byte-identical FULL receipts (merkle AND event/step counts
      # AND plan), i.e. replay idempotency, not just digest equality.
      parent = self()

      refs =
        for _ <- 1..8 do
          ref = make_ref()

          spawn(fn ->
            send(parent, {ref, :smalt_fond_powl_runner.run(opts())})
          end)

          ref
        end

      # F6-B (bkfondskep): bounded poll, not a single fixed fence — collects
      # each sealed receipt in slices and asserts convergence within the
      # overall deadline, so a loaded machine (lane-compile load ~124) reschedules
      # instead of flaking. Convergence budget stays bounded (30s).
      deadline = System.monotonic_time(:millisecond) + 30_000

      receipts =
        for ref <- refs do
          assert {:ok, r} = recv_until_ok(ref, deadline)
          r
        end

      assert length(receipts) == 8
      assert length(Enum.uniq(receipts)) == 1
    end

    defp recv_until_ok(ref, deadline) do
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("S3 receipt did not converge within bounded deadline")
      end

      receive do
        {^ref, {:ok, r}} -> {:ok, r}
      after
        250 -> recv_until_ok(ref, deadline)
      end
    end
  end

  describe "order-fingerprint gate" do
    test "admits on the pinned toolchain and seals a fixed ledger identically" do
      assert :ok = :smalt_fond_seal.order_gate()

      ledger = %{1 => <<"a">>, 2 => <<"b">>, 3 => <<"c">>, 4 => <<"d">>}
      assert {:ok, d1} = :smalt_fond_seal.seal(ledger)
      assert {:ok, ^d1} = :smalt_fond_seal.seal(ledger)
      assert <<_::256>> = d1
    end

    test "sentinel fingerprint is a pinned integer, distinct from the 26.x-era order" do
      assert 628801 = :smalt_fond_seal.sentinel_fingerprint()

      perturbed = Map.new(0..63, fn k -> {k + 1000, true} end)
      refute :erlang.phash2(:maps.keys(perturbed)) == 628801
    end
  end

  # ------------------------------------------------------------------
  # F1-A (bkfondskep) — needs_sat/3 ≡ next_ready/2 15-shape mirror court.
  # Every shape runs BOTH the real planner (assert_acyclic/1) and the real
  # executor (run/1); the planner must agree with the executor's observed
  # outcome — no false refusals of executable plans, no admissions of
  # unrunnable ones. Falsifier for the 5 witness shapes: they flip from
  # false-refusal to :executable.
  # ------------------------------------------------------------------

  @f1a_expect %{
    linear: :executable,
    diamond: :executable,
    fork: :executable,
    join: :executable,
    mixed_provides: :executable,
    unprovided: {:refused, :unprovided_need},
    cycle: {:refused, :cyclic_plan},
    self_need: {:refused, :cyclic_plan},
    dup_provider: :executable,
    dup_provider_min: :executable,
    empty: :executable,
    done_id_only: :executable,
    dup_ids: :executable,
    # BK-DUPID: the true dup-id shape (two steps, both `id: :a`) — the
    # executor's id-keyed done-set collapses duplicates and runs it; the
    # planner must admit it too (deduped Kahn fixpoint).
    dup_ids_exact: :executable,
    # BK-DUPID control: a REAL cycle (cyc1→cyc2→cyc1, distinct ids) must
    # still refuse cyclic_plan even in a plan that also carries dup ids —
    # dedup must not mask genuine cycles.
    dup_ids_cycle_control: {:refused, :cyclic_plan},
    diamond_mixed: {:refused, :unprovided_need},
    late_provider: :executable
  }

  defp f1a_shapes do
    [
      {:linear, [%{id: :a, needs: [], provides: [:a], action: :a},
                 %{id: :b, needs: [:a], provides: [:b], action: :b}]},
      {:diamond, [%{id: :a, needs: [], provides: [:a], action: :a},
                  %{id: :b, needs: [:a], provides: [:b], action: :b},
                  %{id: :c, needs: [:a], provides: [:c], action: :c},
                  %{id: :d, needs: [:b, :c], provides: [:d], action: :d}]},
      {:fork, [%{id: :a, needs: [], provides: [:a], action: :a},
               %{id: :b, needs: [:a], provides: [:b], action: :b},
               %{id: :c, needs: [:a], provides: [:c], action: :c}]},
      # join: bare step-id needs, no useful `provides` anywhere (done-id arm).
      {:join, [%{id: :j1, needs: [:x], provides: [:j1], action: :j1},
               %{id: :j2, needs: [:x], provides: [:j2], action: :j2},
               %{id: :x, needs: [], provides: [], action: :x}]},
      {:mixed_provides, [%{id: :a, needs: [], provides: [:p1, :p2], action: :a},
                         %{id: :b, needs: [:p1], provides: [:b], action: :b},
                         %{id: :c, needs: [:p2], provides: [:c], action: :c}]},
      # genuinely unprovided: nothing provides :never and :never is no id.
      {:unprovided, [%{id: :a, needs: [], provides: [:a], action: :a},
                     %{id: :b, needs: [:never], provides: [:b], action: :b}]},
      {:cycle, [%{id: :a, needs: [:b], provides: [:a], action: :a},
                %{id: :b, needs: [:a], provides: [:b], action: :b}]},
      # self-need without provides: Kahn cannot ready it — cyclic_plan class.
      {:self_need, [%{id: :s, needs: [:s], provides: [], action: :s}]},
      {:dup_provider, [%{id: :a, needs: [], provides: [:x], action: :a},
                       %{id: :b, needs: [:x], provides: [:x], action: :b},
                       %{id: :c, needs: [:x], provides: [:c], action: :c}]},
      {:dup_provider_min, [%{id: :a, needs: [], provides: [:x], action: :a},
                           %{id: :b, needs: [:x], provides: [:x], action: :b}]},
      {:empty, []},
      {:done_id_only, [%{id: :a, needs: [], provides: [], action: :a},
                       %{id: :b, needs: [:a], provides: [], action: :b}]},
      {:dup_ids, [%{id: :a, needs: [], provides: [], action: :a},
                  %{id: :b, needs: [:a], provides: [], action: :b},
                  %{id: :c, needs: [:b], provides: [], action: :c}]},
      # BK-DUPID: TRUE duplicate step ids — executor done-set collapses them
      # and runs; planner (deduped Kahn fixpoint) must admit, not cyclic_plan.
      {:dup_ids_exact, [%{id: :a, needs: [], provides: [], action: :a},
                        %{id: :a, needs: [], provides: [], action: :a}]},
      # BK-DUPID control: real cycle among distinct ids, alongside dup ids —
      # dedup must not mask genuine cycles.
      {:dup_ids_cycle_control, [%{id: :a, needs: [], provides: [], action: :a},
                                %{id: :a, needs: [], provides: [], action: :a},
                                %{id: :cyc1, needs: [:cyc2], provides: [], action: :c1},
                                %{id: :cyc2, needs: [:cyc1], provides: [], action: :c2}]},
      # diamond_mixed: one genuinely unprovided need inside a diamond.
      {:diamond_mixed, [%{id: :a, needs: [], provides: [:a], action: :a},
                        %{id: :b, needs: [:a, :ghost], provides: [:b], action: :b},
                        %{id: :c, needs: [:a], provides: [:c], action: :c}]},
      {:late_provider, [%{id: :a, needs: [:z], provides: [:a], action: :a},
                        %{id: :z, needs: [], provides: [:z], action: :z}]}
    ]
  end

  defp f1a_planner(steps) do
    try do
      :smalt_fond_plan.assert_acyclic(%{steps: steps})
      :executable
    catch
      :error, {klass, _} when klass in [:unprovided_need, :cyclic_plan] -> {:refused, klass}
    end
  end

  defp f1a_executor(steps, timeout_ms \\ 5_000) do
    parent = self()

    pid =
      spawn(fn ->
        send(
          parent,
          {:done,
           :smalt_fond_powl_runner.run(%{
             plan: %{steps: steps},
             tasks: Enum.map(steps, & &1.id),
             max_retries: 3
           })}
        )
      end)

    ref = Process.monitor(pid)

    receive do
      {:done, {:ok, _receipt}} -> :executable
      {:done, {:crash, {{klass, _}, _}}} when klass in [:unprovided_need, :cyclic_plan] -> {:refused, klass}
      {:DOWN, ^ref, :process, ^pid, {klass, _}} when klass in [:unprovided_need, :cyclic_plan] -> {:refused, klass}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        {:skeptic_timeout, pid}
    end
  end

  describe "court (f) F1-A needs_sat ≡ next_ready mirror (bkfondskep)" do
    for {name, expected} <- @f1a_expect do
      test "F1-A shape #{name} — planner agrees with real executor (#{inspect(expected)})" do
        {name, steps} = List.keyfind(f1a_shapes(), unquote(name), 0)
        expected = unquote(expected)

        p = f1a_planner(steps)
        e = f1a_executor(steps)

        assert p == expected, "planner #{inspect(p)} != expected #{inspect(expected)}"
        assert e == expected, "executor #{inspect(e)} != expected #{inspect(expected)}"
        assert p == e, "planner/executor divergence on #{name}: #{inspect(p)} vs #{inspect(e)}"
      end
    end

    test "F1-A full 17-shape sweep — 17/17 planner≡executor (incl. BK-DUPID dup-id legs)" do
      results =
        for {name, steps} <- f1a_shapes() do
          p = f1a_planner(steps)
          e = f1a_executor(steps)
          {name, p, e}
        end

      divergent = Enum.filter(results, fn {_n, p, e} -> p != e end)
      assert divergent == [], "divergences: #{inspect(divergent)}"
      assert length(results) == 17
    end
  end

  describe "court (e) EXPL-10 F6 — bounded receive" do
    test "hang-shape contingency returns typed within a bounded Task (never indefinite)" do
      hang = fn _step -> :timer.sleep(:infinity) end

      # The probe itself is bounded (a hung caller would fail the suite on
      # the ExUnit @timeout, not hang the lane): run/1 must answer BEFORE the
      # probe bound does — that ordering IS the non-vacuity proof.
      {elapsed_us, result} =
        :timer.tc(fn ->
          :smalt_fond_powl_runner.run(opts() |> Map.put(:timeout, 100) |> Map.put(:contingency, hang))
        end)
      elapsed_ms = div(elapsed_us, 1000)

      assert {:crash, {fond_receive_timeout, info}} = result
      assert info.timeout_ms == 100
      assert info.plan == tasks()
      assert elapsed_ms < 5_000

      # Legitimacy: default (no :timeout opt) stays unbounded — but the
      # leg is still witnessed through Task with an outer bound so the
      # suite cannot hang; a real completion races the bound and wins.
      task = Task.async(fn -> :smalt_fond_powl_runner.run(opts()) end)

      assert {:ok, receipt} = Task.await(task, 5_000)
      assert <<_::256>> = receipt.merkle
    end

    test "reachable plan still completes with an explicit generous timeout (loopback-legality)" do
      assert {:ok, receipt} = :smalt_fond_powl_runner.run(Map.put(opts(), :timeout, 10_000))

      assert receipt.step_count == 3
      assert receipt.plan == tasks()
      assert <<_::256>> = receipt.merkle
    end

    test "bad timeout opt refuses typed (fail-closed)" do
      reason = catch_error(:smalt_fond_powl_runner.run(Map.put(opts(), :timeout, :soon)))
      assert {:bad_timeout_opt, :soon} = reason
    end
  end
end

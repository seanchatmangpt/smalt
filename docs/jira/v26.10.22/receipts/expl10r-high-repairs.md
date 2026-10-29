# EXPL10-R — F1/F2/F3 High-Repairs (fond runner planner + Executor)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: EXPL10-R, canonical checkout /Users/sac/smalt, MIX_BUILD_ROOT=_build-expl10r (left in place for coordinator `just lane-clean`)

Repairs EXPL-10 findings F1/F2/F3
(docs/jira/v26.10.22/receipts/expl10-pipeline-powl-errc.md, all witnessed).

## Changes

1. **F1** `lib/smalt/pipeline/smalt_fond_plan.erl` — `assert_acyclic/1` now
   refuses a plan whose step needs a term no step provides:
   `erlang:error({unprovided_need, SortedPairs})` (typed plan error, refuse
   before any execution — never seal a partial run). Additionally closed the
   full satisfiability divergence: Kahn's `Resolve` used to check need-terms
   against the done-set of step *ids* only (a need satisfied via another
   step's `provides` under a different term, e.g. `:a_out`, was mis-classified
   `cyclic_plan`); the new `needs_sat/3` mirrors `next_ready/2` exactly
   (need is a done id, or a done step provides it).
2. **F2** `lib/smalt/powl2/executor.ex` `pre_admit/2` — `Code.ensure_loaded`
   failure → `{:error, {:admit_module_unloadable, mod}}` typed admission
   refusal (was fail-open `:ok`).
3. **F3** `lib/smalt/powl2/executor.ex` `run_op/4` — the success-on-unknown
   catch-all is gone. Enumerated shapes: `{:ok, ctx}`, `{:ok, ctx, outcome}`,
   `{:error, reason}`, `{:error, a, b}` → `{:error, {:transition_failed, id,
   {:error, a, b}}}`, the one documented non-error class `{:ok_outcome,
   outcome}` passes as an outcome, and ANY other shape refuses typed
   `{:transition_failed, id, {:bad_op_result, other}}`.

## Court

`MIX_BUILD_ROOT=_build-expl10r mix run --no-start <probe>` + `mix test`
(47 tests: the new court + fond runner court + powl2 executor/andon-wire/
law-guard suites) + 7 integration courts (powl2_gates, gld7, graphlaw×4,
ath3) exit 0.

### Embedded real probe output (verbatim)

W1 pre-fix (witness, bug present):

```
W1 PRE: sealed partial — step_count=1 plan_len=2
W1 VERDICT: BUG PRESENT (partial run sealed as complete)
```

W1 post-fix (flip):

```
W1 POST: refused typed — crash={{:unprovided_need, [b: :never_provided]}, [{:smalt_fond_plan, :assert_acyclic, 1, [file: ~c"lib/smalt/pipeline/smalt_fond_plan.erl", line: 60]}, {:smalt_fond_powl_runner, :handle_event, 4, [file: ~c"lib/smalt/pipeline/smalt_fond_powl_runner.erl", line: 91]}, ...
```

W2 pre-fix (both bugs present):

```
W2a return: :ok
W2a caller msg: {:orchestration_completed, :w2a, %{x: 1}, %{id: :w2a, status: :completed, steps: [%{node: :w2a, kind: :transition, at_ms: 2369132943075, outcome: :ok}], phi_lease_final: 1}}
W2b return: :ok
W2b caller msg: {:orchestration_completed, :w2b, %{last_outcome: {:error, :throttled, :retry_after_5}}, %{id: :w2b, status: :completed, steps: [%{node: :w2b, kind: :transition, at_ms: 2369132943074, outcome: {:error, :throttled, :retry_after_5}}], phi_lease_final: 1}}
W2 VERDICT: BUGS PRESENT (both runs completed)
```

W2 post-fix (both flipped):

```
W2a return: {:error, {:admit_module_unloadable, This.Reticle.Does.Not.Exist}}
W2a caller msg: {:orchestration_refused, :w2a, {:admit_module_unloadable, This.Reticle.Does.Not.Exist}}
W2b return: {:error, {:transition_failed, :w2b, {:error, :throttled, :retry_after_5}}}
W2b caller msg: {:orchestration_failed, :w2b, {:transition_failed, :w2b, {:error, :throttled, :retry_after_5}}}
W2 VERDICT: refused
```

Court output:

```
Finished in 0.4 seconds (0.00s async, 0.2s sync)
Result: 47 passed
```

(`mix test test/internal/expl10r_court_test.exs test/pipeline/fond_powl_runner_court_test.exs test/internal/powl2_executor_test.exs test/internal/powl2_andon_wire_court.exs test/internal/powl2_law_guard_court.exs --include internal`)

Integration courts (exit 0): powl2_gates_court, gld7_ingest_to_settlement_court,
graphlaw_powl_business_net, graphlaw_fullstack_court, ath3_law_court,
graphlaw_rule_change, graphlaw_skeptic_court. Plus kd_conformance_test,
coldchain_sql_seed_court, internal_tier_census (see Disclosures).

## Court file

`test/internal/expl10r_court_test.exs` — F1 legs (witness shape refuses
`{:crash, {{:unprovided_need, _}, _}}`; linear and custom provider plans
unchanged, custom-provider plan pins the needs_sat/3 divergence closure),
F2 legs (unloadable mod → `{:error, {:admit_module_unloadable, mod}}` +
`orchestration_refused`; default-reticle admitted path unchanged), F3 legs
(3-tuple error → transition_failed; bare-atom op result → bad_op_result;
`{:ok_outcome, _}` still passes; `{:error, r}`, `{:ok, ctx}`, `{:ok, ctx,
outcome}` unchanged). Non-vacuity: every leg failed on the pre-repair tree
(W1/W2 transcripts above).

## Disclosures

- **Compile-freeze event (no fix applied)**: first fresh-root compile failed
  on `lib/smalt/attestation/maa.ex` (guard `:ets.info/2` — another lane's
  in-flight edit); the file self-healed on disk between compile and read, so
  no cross-lane unblock was applied. No other lane's file was edited except
  the census registration below.
- **Census registration** (shared file, minimal additive diff):
  `test/internal/internal_tier_census_test.exs` — registered
  `expl10r_court_test.exs => :internal` and added
  `Smalt.EXPL10R.HighRepairsCourtTest` to `@observables`. Post-registration,
  the only census failures cite other lanes' unregistered in-flight files
  (`bkmaap6_nonce_bounds_court_test.exs`, `expl11r3_court_test.exs`) — not
  this lane's, left for their owners.
- Scratch: `/tmp/expl10r_w1.exs`, `/tmp/expl10r_w2.exs`, `/tmp/expl10r_dbg.exs`,
  `/tmp/expl10r_*.log`; dets probes self-clean (`rm -f` per run).

## Falsifiers (standing checks)

- W1 shape must refuse `{:crash, {{:unprovided_need, _}, _}}` — a seal or an
  `{:ok, receipt}` re-opens F1.
- Nonexistent reticle mod must return `{:error, {:admit_module_unloadable, _}}`
  — any `:ok`/`orchestration_completed` re-opens F2.
- Op result `{:error, :throttled, :retry_after_5}` must fail the run — any
  `:completed` re-opens F3.

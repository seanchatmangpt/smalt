# EXPL-10 — pipeline/ + powl2/ ERRC Read-Only Sweep

- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: EXPL-10, canonical checkout /Users/sac/smalt, MIX_BUILD_ROOT=_build-expl10 (deleted post-run)

## Scope & exclusions

Audited `lib/smalt/pipeline/` (smalt_fond_powl_runner / _plan / _seal) edges and
`lib/smalt/powl2/law_compiler.ex` consumers (Executor GL-2 seam, EventGrid
PushRouter, DTDL converter). Excluded as covered: BK-4 (fond happy path,
bound exhaustion, seal determinism, cyclic_plan), EXPL5-R2/T3 (guard non-map
fail-closed, `ctx_value` atom law), BK-7/7b (warnings), GL-KILL F1/F2 (struct
fields, canonical equality).

## Court command

Real compiled-module probes, `MIX_BUILD_ROOT=_build-expl10 mix run --no-start /tmp/expl10_w*.exs`, no tree writes.

### Embedded real probe output (verbatim)

W1 — fond runner executor/planner satisfiability divergence (silent step drop):

```
assert_acyclic -> :ok
next_ready(before any done) -> %{id: :a, action: :go, needs: [], provides: [:a_out]}
RUN -> {:ok, receipt}
  step_count=1 plan_len=2 event_count=6
  merkle=<<217, 156, 3, 139, 232, 77, 113, 155, 199, 96, 197, 81, 110, 197, 28, 75, 77, 134, 60, 45, 218, 43, 184, 30, 194, 105, 20, 134, 168, 27, 190, 185>>
VERDICT: sealed receipt claims 1/2 steps — step :b silently skipped, seal is still ALIVE
```

W2a — Executor `pre_admit` fail-open on unloadable reticle module:

```
W2a return: :ok
W2a caller msg: orchestration_completed id=:w2a status=:completed
```
(called with reticle_mod `This.Reticle.Does.Not.Exist` — admission skipped, model ran)

W2b — Executor `run_op` 3-tuple error counted as success:

```
Reticle.admit -> :ok
W2b COMPLETED id=:w2b status=:completed
  steps=[%{node: :n1, kind: :transition, at_ms: 2369132238811, outcome: {:error, :throttled, :retry_after_5}}]
  VERDICT: op returned {:error, :throttled, :retry_after_5} but run is status=:completed
```

W3a — LawCompiler accepts a TRUNCATED TTL (statement without final `.`):

```
W3a RESULT: truncated TTL compiled ok; guard over %{"total" => 999} = {:violation, "A/maxInclusive/total", "total: value 999 e...}
```

W3b — PushRouter scope prefix over-match:

```
W3b control (non-matching source) -> %{matched: 0, delivered: 0, no_match_events: 1}
W3b RESULT: scope '/smalt/prod' vs source '/smalt/prod2/x' -> %{matched: 1, delivered: 1, no_match_events: 0}
```

## Findings (ranked, with repair tickets)

**F1 (HIGH, witnessed W1) — fond runner: planner/executor satisfiability
divergence → sealed partial run.** `smalt_fond_plan:assert_acyclic/1` treats a
need provided by nobody as EXTERNAL and satisfiable (Kahn `External/1`), but
`next_ready/2` requires needs ∈ done-set or provided by a DONE step. A step
whose needs are never produced is silently skipped, and the pipeline still
seals a 32-byte merkle with `step_count < length(plan)`. Success-on-unknown:
the seal certifies a partial run as complete. Repair: `next_ready/2` must
return `{blocked, Id, unmet_need}` when no ready step exists but steps remain
(`Done =/= all`), and the runner must crash `fond_blocked_step` instead of
advancing to `powl`. Owner: pipeline lane.

**F2 (HIGH, witnessed W2a) — Executor `pre_admit/2` fail-open.** `Code.ensure_loaded`
error → `:ok` (lib/smalt/powl2/executor.ex:84-88). An unloadable reticle
module SKIPS admission and the model runs unadmitted (`:ok` +
`orchestration_completed`, witnessed). Repair: `{:error, _} ->
{:error, {:admit_module_unloadable, mod}}` typed refusal. Owner: powl2 lane.

**F3 (HIGH, witnessed W2b) — Executor `run_op` catch-all is success-on-unknown.**
The `other` clause (executor.ex:284-286) converts ANY non-`{:ok,...}`/
`{:error,tuple}` op result — e.g. `{:error, :throttled, :retry_after_5}` — into
an OK step (`{:ok, ctx2, [step...]}`) and the run completes with
`status: :completed`. A 3-tuple error is a common API shape. Repair: `other`
clause must classify: `{:error, _, _}` tuples → `{:error, {:transition_failed, ...}}`;
only a documented class (e.g. `{:ok_outcome, ...}`) may pass as non-error
outcome; unknown shapes refuse `{:error, {:bad_op_result, other}}`. Owner: powl2 lane.

**F4 (MED, witnessed W3b) — PushRouter scope prefix over-match.**
`String.starts_with?(source, sub.scope)` matches `/smalt/prod2/x` under scope
`/smalt/prod` (no path-boundary check). Over-delivery to a subscription's WAL
or SB queue. Repair: compare on `source == scope or
String.starts_with?(source, scope <> "/")` (or tokenize). Owner: eventgrid lane.

**F5 (MED, witnessed W3a) — LawCompiler accepts truncated TTL.** `split_statements/1`
recurses on a token tail with no terminal `.` and parses the trailing partial
statement anyway; a remote-supplied TTL cut mid-stream compiles the truncated
tail as a complete shape. Typed posture: require the last statement to be
terminated (parse the tail empty-or-refuse). Owner: powl2 lane.

**F6 (LOW, code-cited) — runner `run/1` receive has no timeout.** A contingency
fun that never returns hangs the caller forever (smalt_fond_powl_runner.erl:44-53).
Repair: optional `timeout` opt with typed `{:crash, :runner_timeout}`.

**F7 (LOW, code-cited) — Latent function_clause in `next_ready/2` Providing
closure.** `#{id := ID, provides := W}` fun head requires `provides`;
`assert_acyclic` defaults it. A step WITH `needs` plus any step WITHOUT
`provides` crashes untyped (W3c probe could not trigger without a needs-step; latent). Repair:
`maps:get(provides, S, [])` — same defaulting as the planner.

**F8 (LOW, code-cited) — `guard_table!/1` whereis→new race.** Two concurrent
first callers both see `:undefined` → second `:ets.new` badarg. Repair:
attempt `:ets.new` first, on `:error` re-`whereis` (or wrap in a named
GenServer).

**F9 (LOW, code-cited) — `swap_guard`/`lookup_guard` @spec `:ets.table()`** is not
a real type (`:ets` has no `table/0`); dialyzer-invalid. Repair: spec the
tables as `atom()`. Owner: powl2 lane.

**F10 (LOW, code-cited) — PushRouterPlug route/3 PUT/POST passes `params["name"]`**
(may be nil/non-binary) into `put_subscription` whose guard raises
FunctionClauseError → untyped 500 instead of typed 400. Same class for
`destination["ttl_seconds"]` non-integer → `maybe_ttl/2` FunctionClauseError
inside the server → caller exit. Repair: guard-tolerant `is_binary` checks in
the Plug with typed 400s.

## ERRC disposition

- Eliminate: F1 partial-run seal (block instead of skip), F3 catch-all
  success clause (classify or refuse).
- Reduce: F5 parser must refuse unterminated final statement.
- Raise: F2 admission must fail closed on module-load failure.
- Create: none needed — all repairs are tightenings, no new machinery.

## Non-vacuity

Each witness flips an observable: W1 flips seal-with-skip vs blocked crash;
W2a flips run-proceeds vs typed refusal; W2b flips completed vs failed; W3a
flips compile-ok vs parse_error; W3b flips matched=1 vs no_match_events. A
post-repair rerun of these probes must flip every line to the refused verdict;
no flip ⇒ the repair is vacuous.

## Cleanup

Scratch left on disk (lane rm denied by session permissions — coordinator may
reclaim): `/tmp/expl10_w{1,2,2b,3}.exs`, `/tmp/expl10_w2{,b}.dets`,
`/tmp/x3.dets`, `/tmp/expl10-wal/`, and lane build root `/Users/sac/smalt/_build-expl10`
(`just lane-clean` reclaims it). No tree writes outside the receipt.

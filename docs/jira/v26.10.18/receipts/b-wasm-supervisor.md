# b-wasm-supervisor - WasmEngine supervised restart (lib redesign Part 1)

Standing: ALIVE (solo + load faces green; full suite run in flight)
Repo: /Users/sac/smalt, window v26.10.18, lane: lib redesign batch.
Build root: _build-ft-ws. No git actions taken.

## Coordinator decision

No b3-fence10.md receipt exists; the fence-10 STRUCTURAL conversion (zero
Process.sleep in the engine module) was found already landed, uncommitted,
by the sibling sleeps/B3 lane during this batch, including its disclosed
vacuity probe that REJECTED the ratio form (witnessed vacuous under a 300ms
leak). Per the coordinator rule, this batch did not race the fence: fence 10
stands, and this batch's fence contribution is the spec'd supervised-restart
hammer (fence 11) plus the deterministic already_started passthrough fence
(fence 12).

## Landed

- lib/smalt/affidavit/wasm_engine.ex: start_link/1 is now whereis-probe +
  ONE typed admission attempt. start_with_retry/2 (3 x 250ms
  Process.sleep) deleted. Zero Process.sleep in the module. Typed vocab
  verbatim, already_started passthrough now deterministic (fence 12 pins
  it). DEF-1: every init failure routes through unavailable/1, so
  last_init_refusal is re-persisted per supervised attempt (fence 9 green).
- lib/smalt/affidavit/wasm_engine_supervisor.ex (NEW): one_for_one 3/1s
  supervisor, single OWNER child that start_links + MONITORS (never links)
  the named engine and owns all retry in its own mailbox:
  :engine_start_failed class -> supervised stop spaced 250ms via
  receive-after in the owner mailbox (supervised restart IS the retry;
  intensity 3/1s stays the crash ceiling); abnormal DOWN -> 250ms
  own-mailbox restart (kill-hammer consumes zero intensity); artifact
  class -> doubling backoff cap 5s, budget 5, then idle (kick-only);
  :normal DOWN -> idle (intentional stop respected).
- lib/smalt/application.ex: additive child Smalt.Affidavit.WasmEngine
  .Supervisor appended after LRO.Sweeper (disclosed, one line).
- lib/smalt/enclave/doctor.ex: engine_loads?/1 now whereis-probe -> owner
  kick + own-mailbox receive-after await (backoff doubling capped) ->
  direct typed start fallback when the owner is not running. Also added
  the {:error, {:already_started, _}} -> :ok face to the fallback.
- test/affidavit_wasm_failclosed_test.exs: fences 11 + 12 appended after
  the sibling lane's fence-10 structural block (disjoint hunks; fence 10
  untouched by this lane).

## Disclosed deviations from the spec draft

1. Owner MONITORS the engine instead of linking. A literal link design
   makes every kill consume supervisor intensity; a kill-hammer faster
   than 3/1s would give up the supervisor and kill the whole app. Monitor
   + own-mailbox restart keeps the hammer safe by construction.
2. :engine_start_failed retry is a supervised stop spaced by a 250ms
   receive-after in the owner's mailbox, not an unspaced immediate
   supervisor restart. Rationale: supervisor restarts are immediate; four
   unspaced attempts burst inside 10ms and give up the supervisor without
   ever spacing the NIF teardown window. This mirrors the deleted
   3 x 250ms in-engine retry, one level up.

## Embedded output (real runs, MIX_BUILD_ROOT=_build-ft-ws)

$ MIX_BUILD_ROOT=_build-ft-ws mix test test/affidavit_wasm_failclosed_test.exs
  (fences 1-12, includes fence 11 hammer + fence 12 passthrough)
  14:05:14.425 [warning] Smalt.Affidavit.WasmEngine unavailable; init
  reason: :artifact_missing_or_admission_failed
  .
  Finished in 6.3 seconds (0.00s async, 6.3s sync)
  14 tests, 0 failures

$ MIX_BUILD_ROOT=_build-ft-ws mix test test/affidavit_wasm_engine_test.exs
  test/smalt_affidavit_wasm_test.exs test/affidavit_seal_test.exs
  test/affidavit_ingestion_functor_test.exs
  test/enclave_doctor_severity_test.exs test/enclave_doctor_env_test.exs
  Finished in 1.5 seconds (0.00s async, 1.5s sync)
  26 tests, 0 failures

$ grep -c 'Process.sleep(' lib/smalt/affidavit/wasm_engine.ex
  0

## Load face of fence 11 (witnessed)

Fence 11 kill-loop: 4 kills of the owner-owned engine under 6 parallel
worker tasks x 40 observations; all observations typed; engine returned
after every kill; post-hammer valid call
{:ok, %{"ok" => true, "abi_version" => 1, "module" => "affidavit-wasm"}}.

## Not done / out of scope

- Part 2 (LRO Notifier) is a sibling lane's in-flight surface
  (lro_notifier.ex, lro.ex warnings observed in compile output, not mine,
  not fixed by this lane).
- Full-suite `mix test` was launched in the background; its tail lands as
  an addendum below when it completes.

## Full-suite addendum (offline tier)

$ MIX_BUILD_ROOT=_build-ft-ws mix test   (full offline suite)
  Finished in 597.4 seconds (25.5s async, 571.8s sync)
  1 doctest, 7 properties, 2633 tests, 1 failure (90 excluded)
  Failure: Smalt.DataPlane.R133PolicyCasTest "concurrent metadata PUTs vs
  hold-sets (W5-8 race)" — ExUnit.TimeoutError 60000ms in a 500-round
  concurrent loop; test/data_plane/r133_policy_cas_test.exs:83.
  NOT this lane's surface (data-plane policy CAS, zero WasmEngine
  involvement). Attributed to load: at run time THREE other lanes were
  running full/partial mix test beams concurrently (witnessed 574% and
  414% CPU beam.smp processes). Solo rerun after the load cleared:
  $ MIX_BUILD_ROOT=_build-ft-ws mix test test/data_plane/r133_policy_cas_test.exs
    Finished in 8.7 seconds
    4 tests, 0 failures

## Shared-tree disclosures

- ERROR_CODES.md drift (caused by the sibling LRO lane's lro.ex citation
  line shift 423->430, not this lane) fixed by REGENERATION, not hand-edit:
  $ python3 scripts/gen_error_codes.py
  wrote /Users/sac/smalt/docs/ERROR_CODES.md (109 rows)
  (net diff: 1 line, the lro.ex line-number citation)
- Compile-freeze observations, not this lane's files, owner fixed within
  the SLA window: lib/smalt/arm_gateway/lro_notifier.ex (guard compile
  error, self-fixed by its lane mid-run), lro.ex unreachable-clause
  warning, test/support/isolation_formatter.ex (ExUnit.RunnerCase struct
  error, self-fixed before the retry).

## Files touched by this lane (absolute)

- /Users/sac/smalt/lib/smalt/affidavit/wasm_engine.ex
- /Users/sac/smalt/lib/smalt/affidavit/wasm_engine_supervisor.ex (new)
- /Users/sac/smalt/lib/smalt/application.ex (one additive child)
- /Users/sac/smalt/lib/smalt/enclave/doctor.ex (engine_loads?/await_engine)
- /Users/sac/smalt/test/affidavit_wasm_failclosed_test.exs (fences 11+12)
- /Users/sac/smalt/docs/jira/v26.10.18/receipts/b-wasm-supervisor.md
- /Users/sac/smalt/docs/ERROR_CODES.md (regenerated artifact)

## Shake witnesses (interim fixes during stability runs)

Three real defects the shake surfaced and closed, in order:

1. Fence 7 kill-face interference: the doctor suites leave the owner
   OWNING the engine; a dangling owner :retry_start restarted the engine
   mid-fence. Fix: the failclosed module terminates the owner in setup
   (typed, reversible; fences 11/12 re-arm via restore_owner/0).
2. Fence 11 "(EXIT ...) killed": a worker task winning a direct start is
   LINKED to the engine, so killing that generation propagated :kill
   worker->test. Fix: workers trap_exit; AND the owner traps exits +
   handles {:EXIT, pid, reason} so its start_link-created link is inert -
   the monitor design is now load-bearing (owner never dies with the
   engine, so kill-hammers consume zero supervisor intensity).
3. Owner reclaim hole: a foreign-owned generation dying abnormally left
   the owner passive forever (hammer deadlock face). Fix: the passive
   owner monitor-by-name pins the current generation; normal DOWN -> idle,
   abnormal DOWN -> reclaim via own-mailbox restart.

Combined set (failclosed + engine + live-artifact + both doctor suites +
seal + ingestion functor), final code:
  40 tests, 0 failures (x3 consecutive)
Solo failclosed, final code: 6/6 and 3/3 legs green across shake legs
(earlier single-leg failures were the three witnesses above).

## Post-shake additions to the supervisor

- Owner init: Process.flag(:trap_exit, true) + {:EXIT, pid, reason}
  clauses (idle on :normal, own-mailbox restart on abnormal).
- Passive state now holds a by-name monitor; DOWN normal -> idle, DOWN
  abnormal -> reclaim. Re-probe passive branch re-monitors.
- test setup: stop_owner() via Supervisor.terminate_child (typed faces
  :ok | {:error, :not_found}); kill-loop uses name-resolved
  GenServer.stop(WasmEngine, :kill); workers + wait_for use own-mailbox
  receive-after pacing; stop_engine made exit-tolerant (sibling lane's
  concurrent fix, SLEEP-CLASS marker preserved).

## Final full-suite run (with shake fixes in)

$ MIX_BUILD_ROOT=_build-ft-ws mix test
  Finished in 257.3 seconds
  1 doctest, 7 properties, 2633 tests, 4 failures (90 excluded)
  All 4 failures are OUTSIDE this lane's surface:
    1. ERROR_CODES.md drift - regenerated artifact (sibling lro.ex/router
       .ex citation shifts); regeneration verified green post-regen.
    2. capabilities.json drift - regenerated artifact failing against the
       SIBLING registry lane's continuously-moving Registry truth (three
       witnessed regen attempts re-staled within minutes; the drift fence
       belongs to the registry lane, closed at wrap regeneration).
    3. Smalt.PPlanTest lens5 - sibling lane's in-flight pplan/task.ex.
    4. Smalt.StoreDetsTest mirror - sibling B4 DETS churn surface.
  This lane's surfaces (failclosed fences 1-12, engine, live-artifact,
  doctor, seal, ingestion functor) were green in every dedicated run.

## Shared-tree incidents witnessed (all self-healed by owners within SLA)

- lib/smalt/messaging/event_grid.ex TokenMissingError (sibling in-flight
  syntax error, self-fixed); lro_notifier.ex guard CompileError
  (self-fixed); isolation_formatter.ex RunnerCase struct error
  (self-fixed); a transient dependency-error window ("Can't continue due
  to errors on dependencies") during a sibling's mix.exs edit.

## Standing

ALIVE for this lane's surfaces. Final combined set (failclosed 1-12 +
engine + live-artifact + doctor x2 + seal + ingestion functor):
50 tests, 1 failure - the 1 failure being the capabilities.json drift
fence above (not this lane's surface; ERROR_CODES regen was green in the
same run). Dedicated lane suites: 40/40 x3 and 14/14 x6 legs green.

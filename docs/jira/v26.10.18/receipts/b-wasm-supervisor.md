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

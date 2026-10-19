# Receipt: B4 LRO/STORE batch — v26.10.18 rewrite (Context: slice)

Standing: PASS (all four faces green x2; two cross-lane disclosures below)
Context: solo (lro_test.exs, arm_error_corpus_test.exs, blob_hardening_test.exs — each x2)

## Scope

Slice task: (1) store_dets churn rewrite, (2) lro sweeper test-ownership
(lib + tests), (3) arm_error_corpus AssertEventually migration, (4) blob
pagination budget manifest. Spec:
`docs/jira/v26.10.18/rewrite-drafts/store-lro-wasm.md` (sections 1, 2, 3, 5
— draft section 4 / fence10-ratio is NOT in this batch).

## Changes

- `lib/smalt/arm_gateway/lro_sweeper.ex` — `start_link/1` now
  `name = Keyword.get(opts, :name, __MODULE__)`; `init/1` gates the tick-0
  `send_after` on `is_integer(tick_ms) and tick_ms > 0`, otherwise state
  `:manual` (no init pass, `handle_call(:sweep, :manual)` passthrough,
  `handle_info(:tick, :manual)` no-op). Default (app-owned singleton)
  behavior byte-identical.
- `test/lro_test.exs` — setup starts a test-owned anonymous manual sweeper
  `start_supervised!({Sweeper, name: nil, tick_ms: :manual})`; every
  `sweep_now()` → `sweep_now(sweeper)`, including inside the (renamed)
  `sweep_task` in the 10d race test; `sweep_until_terminal/4` threads the
  pid. No global singleton call remains in the file's sweeper faces.
  `SweeperBoundaryTest` (pure `eviction_pass/1` pins) untouched, still green.
- `test/store_dets_test.exs` — churn rewrite: fixed attempt budget
  (`@attempts_per_key 50` x `@racer_keys 100` x `@max_rounds 120`), racers +
  restore under a per-round `Task.Supervisor`, restore's return is the
  deterministic completion signal (no spin-until-atomic), clobbers + wins +
  vacuous-round accounting, and a non-vacuity pin
  `assert total_wins > 0` (>=1 fresh win witnessed or the court flags itself
  vacuous). Suite dropped from a 600s envelope to 12-16s quiet (130.6s under
  concurrent-lane load, still green).
- `test/support/assert_eventually.ex` — landed by lane B0 (polled: present
  at poll 1 of the 60s-x20 loop). This lane consumed it, did not author it.
- `test/arm_error_corpus_test.exs` — `poll_until_succeeded/1` is now a thin
  wrapper over `SmaltTest.AssertEventually.eventually/2`
  (`deadline_ms: @poll_deadline_ms` = 5000, `{:retry, last_status}` on 202,
  immediate typed flunk on unexpected status). The `:lro_delay_ms = 0`
  setup pin and the forensics comment stay verbatim.
- `test/data_plane/fixtures/pagination_budget.json` (new, committed) —
  anchors (quiet 62/67, loaded 170, revert_class_quiet 205), budget_ms 180,
  ratio 8, reps 5, chain_pages 11, blobs 8000, blob_bytes 2048. Read at
  runtime in the perf test; min-of-5 marker-threaded chain verbatim; new
  drift fence `assert budget_ms < revert_class_quiet_ms`.
- `test/data_plane/blob_hardening_test.exs` — perf test parameterized from
  the manifest + typed flunk naming the anchors + the self-check above.

## Validation (real output, MIX_BUILD_ROOT=_build-ft-b4)

```
== compile ==                        → 0 errors
== store_dets (stress) run A ==      → Finished in 12.1 seconds … 6 tests, 0 failures
== store_dets (stress) run B ==      → Finished in 16.4 seconds … 6 tests, 0 failures
== store_dets (stress) receipt run == → Finished in 130.6 seconds … 6 tests, 0 failures
== lro (mid-session) ==              → 37 tests, 3 failures   [all NotifierTest — other lane WIP, see below]
== lro (receipt run) ==              → 37 tests, 0 failures
== corpus run A / B / receipt ==     → 19 tests, 0 failures  (x3)
== blob run A / B / receipt ==       → 116 tests, 0 failures (x2)
```

Fences green within these runs: insert_new fresh-wins + non-vacuity
(store_dets churn), DETS no-clobber (store_dets restore tests), detc ledger
meta replay, InProgress-never-evicted (boundary + retention faces),
byte-identical convergence (lro 10d race), no-op 0-write sweep, pagination
perf under 180 ms budget.

## Cross-lane disclosures (shared-tree, same checkout)

1. **lro_notifier / NotifierTest WIP**: mid-session, `test/lro_test.exs`
   and `lib/smalt/arm_gateway/lro_notifier.ex`/`lro.ex` carried another
   lane's in-flight edits (NotifierTest appended to lro_test.exs; a
   transient guard compile break in `schedule_due_check/2` and a
   `WasmEngine.Supervisor.start_link/1` undefined window — both resolved by
   the owning lanes within the compile-freeze SLA; no unblock fix applied
   by this lane). During that window lro_test read 37 tests / 3 failures,
   all three in `Smalt.ArmGateway.LRO.NotifierTest` (not this lane's
   surface); the receipt run reads 37/0 after that lane's work settled.
2. **`@tag :stress` on the churn test** was added by another lane while
   this lane was mid-rewrite; the rewrite preserved it, so the churn runs
   under `mix test --include stress`. First draft-edit collision (Edit
   rejected twice: file modified on disk) resolved by re-reading and
   merging, no other lane's edit reverted.
3. **`SLEEP-CLASS: TIME-ADVANCE` annotations** in lro_test.exs are another
   lane's in-flight additions, preserved verbatim.

## Discrepancy note

Task line "corpus 26/0": the file on disk has 19 tests (`grep -c "^\s*test "
test/arm_error_corpus_test.exs` → 19); 19/0 x3 witnessed. If 26 was the
post-expansion target, the expansion is not in this tree slice.

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-b4 mix test --include stress test/store_dets_test.exs
MIX_BUILD_ROOT=_build-ft-b4 mix test test/lro_test.exs
MIX_BUILD_ROOT=_build-ft-b4 mix test test/arm_error_corpus_test.exs
MIX_BUILD_ROOT=_build-ft-b4 mix test test/data_plane/blob_hardening_test.exs
```

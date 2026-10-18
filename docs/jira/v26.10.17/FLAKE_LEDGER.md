# FLAKE LEDGER — v26.10.17

## Purpose

One table of every jitter face witnessed this window so an attempt-5 RED
classifies in minutes: look the face up here before investigating — a row with
standing CLOSED should not re-open as a new defect, and an OPEN-ROTATING row
names its known mechanism and next fix shape. Stale-by-default law: every
standing in this file is as-of its cited receipt; re-verify on disk (derive
commands below) before staging or landing any claim. Fix receipts are the
authority for standing upgrades, never this table's prose.

## Attempt-4 rotating set (r246 leg-2 faces) — post-poll status

Polled 60 s x10 (and beyond) on 2026-10-18: three i22 fix receipts landed
during the poll; standing upgraded accordingly. i22 receipts:
`receipts/i22-error-corpus-lro.md` (12:09), `i22-fuzz-atom-fix.md` (12:09),
`i22-atom-pressure.md` (12:10), `i22-corpus-seed-hardening.md` (12:13).

| # | Face (test file:line) | First witness | Mechanism | Fix receipt | Hammer evidence | Recur | Standing |
|---|---|---|---|---|---|---|---|
| F1 | `test/arm_error_corpus_test.exs:274` — LRO PUT 202 + Azure-AsyncOperation poll | r246 (attempt 4, leg 2) | Async suites mutate global `:lro_delay_ms` (`test/lro_test.exs:35` sets 20 ms), stretching per-poll latency; poll budget was ~500 ms, untyped flunk | `receipts/i22-error-corpus-lro.md` — deadline-based bounded retry (5000 ms) + setup pins `lro_delay_ms=0` with on_exit restore | paired x3 45/0 + solo 19/0 (`_build-ft-r8`) | 1 | CLOSED |
| F2 | `test/corpus/shacl_fuzz.exs:79` — L2 sku-less storage PUT admitted | r246 (attempt 4, leg 2) | Shared-seed vanish: ShaclFuzz setup's bare `ensure_store_up() → Store.clear()` races an async sibling's shared-tree teardown; named ETS tables die between the wait and the clear | `receipts/i22-corpus-seed-hardening.md` — `resilient_clear/0` bounded typed retry (same pattern as i21-ets-race-fix) | corpus_test 3x 26/0, compliance_test 2x 157/0, paired 183/0 (`_build-ft-r11`) | 1 | CLOSED |
| F3 | `test/corpus/shacl_fuzz.exs:98` — 1000-PUT fuzz sweep | r246 (attempt 4, leg 2) | same as F2 (shared setup) | `receipts/i22-corpus-seed-hardening.md` | same | 1 | CLOSED |
| F4 | `test/corpus/shacl_fuzz.exs:146` — pinned regression rows replay | r246 (attempt 4, leg 2) | same as F2 (shared setup) | `receipts/i22-corpus-seed-hardening.md` | same | 1 | CLOSED |
| F5 | `test/corpus/tags_normalization.exs:49` — tags:null echo readback | r246 (attempt 4, leg 2) | same vanish class; tags_normalization is one of the 8 corpus families fed by `Smalt.Corpus.Helper.ensure_store/0` (bare ensure+clear) | `receipts/i22-corpus-seed-hardening.md` (Helper.resilient_clear/0) | same | 1 | CLOSED |
| F6 | `test/amqp/fuzz_test.exs:561` — 5000 unique keys mint no new atoms | r246 (attempt 4, leg 1) | Named: secondary atom_count delta fence (<=10) can see >10 unrelated lazy-init mints under load; NOT atom pressure (table measured 38,197 / 1,048,576 ~3.6%, decode mints 0) | none — `receipts/i22-fuzz-atom-fix.md` stand-down NOT-REPRODUCIBLE (3/3 paired green, no measured failing distribution to calibrate slack); measurement in `receipts/i22-atom-pressure.md` | none (repro failed 3/3) | 1 | OPEN-ROTATING |
| F7 | `test/egress_dispatch_test.exs:1221` — batch-list boundary | r240 (attempt 2) | typed CONTENTION (load face); solo-green 3/3, 107/0 each | none — dispositioned load-class in r240 | r240: file re-run 3x green on the same tree | 1 | OPEN-ROTATING |

## r236 75-failure cluster + repair-wave faces (i21 chain)

| # | Face | First witness | Mechanism | Fix receipt | Hammer evidence | Recur | Standing |
|---|---|---|---|---|---|---|---|
| F8 | Cross-file 401/MissingBearerToken cluster (13 modules, 75 failures: C4Blob 19, C2Keyvault 15, PolicyRbac 12, ...) | r236 (`tmp/court-x2-v17-run1.log`, seed 71461) | Root-caused in `receipts/i21d-store-clear-async.md`: `test/amqp/management_rpc_test.exs` was the tree's only async module wiping shared ETS tables in setup; wipes race sibling enqueues/dequeues (DLQ rows vanish) and cascade into 401/404 setup artifacts | `receipts/i21d-store-clear-async.md` (async: false + evidence the clear-race class is absent 4/4 post-fix) | r246 warm-up leg 0: 2655 tests, 0 failures (406.7 s) — window's first zero-failure full pass | 1 full-suite run at 75; shrank 4→1→1 across `receipts/i21-full-suite-postfix.md` runs | CLOSED |
| F9 | `test/affidavit_wasm_failclosed_test.exs:502` — fence 10 restart hammer, `assert ms < 100` | r240 (attempt 1) | 100 ms wall-clock bound conflated scheduler jitter with the leaked-retry-sleep class; clean refusals hit 129 ms under load | `receipts/i21-fence10-fix.md` — bound 100→250 ms (the engine's own retry delay; a leaked sleep provably >=250 ms, so the fence still bites) | `receipts/i21-fence10-hammer.md` — 12/12 legs green (10 solo + 2 under 4 `yes` hogs) | 3 (attempt 1; r241 BOTH legs of attempt 3 — was upgraded PERSISTENT-FLAKE) | CLOSED |
| F10 | `test/egress_dispatch_test.exs` setup — ETS `:smalt_subscriptions` "table identifier does not refer to an existing ETS table" (victims :975, :1474) | r241 (attempt 3, both runs' periphery + `tmp/mix-test-a3-postcourt.log`) | Setup's `ensure_store_up()` → `Store.clear/0` → `seed_default_subscription/0` (`lib/smalt/store.ex:194`) races an async sibling (`test/eventgrid_topics_arm_test.exs:371`) tearing the shared tree down | `receipts/i21-ets-race-fix.md` — setup-only `resilient_clear/1` (50 retries, 10 ms backoff, typed, loud past bound) | `receipts/i21-ets-hammer.md` — 5/5 pair runs green (both argument orders), 116/0 each | 2+ | CLOSED |
| F11 | `test/lro_test.exs:543` — op-record store miss (`:error` vs Succeeded) | r241 (post-court full run, `tmp/mix-test-a3-postcourt.log`) | Fixed `Process.sleep(delay+10)` + single sweep + hard assert races cross-module Store teardown | `receipts/i21-lro-face.md` — `sweep_until_terminal/3` bounded retry (5000 ms deadline, typed flunk naming record keys + rid) | solo x3 33/0 + paired green, post-fix no slower (0.9 s) | 1 | CLOSED |
| F12 | `test/store_dets_test.exs:145` — DETS churn (`GenServer.call ... :sync, 5000` timeout at :197) | `receipts/i20b-contention-mechanism.md` (reproduced 2/2 under +16 `yes` hogs) | Default 5 s `GenServer.call` timeout vs measured ~350x sync tail under 16-core load | `receipts/i21-churn-budget.md` — timeout tag 300 s → 600 s | 1 test, 0 failures quiet at 160 s wall | reproduced 2/2 loaded | CLOSED |
| F13 | `test/amqp/management_rpc_test.exs:770` — W3SessionOps batch-delete, `{:ok,_}` vs `:error` | `receipts/i21-full-suite-postfix.md` run 2 | DLQ rows vanish mid-flight — same management_rpc async store-wipe mechanism as F8 | `receipts/i21d-store-clear-async.md` | 4/4 post-fix full-suite runs without the class; r246 warm-up 2655/0 | 1 | CLOSED |
| F14 | `test/store_churn_test.exs:37` — list_prefix under concurrent mid-walk deletes, 0 rows | `receipts/i21-full-suite-postfix.md` run 3 | UNRESOLVED-but-nonrecurring per `receipts/i21d-store-clear-async.md` (table `:smalt_resources`, `/churn-test/` prefix — not wiped by management_rpc) | none | r246 warm-up leg 0 green (nonrecurrence) | 1 | OPEN-ROTATING |
| F15 | `ApiVersionMatrixTest` cite-drift fence (router.ex:2714 citation drifted) | r236 (§5, non-401 class) | In-flight lib/ edits shifted router.ex line numbers; the fence correctly caught the stale citation — deterministic doc-drift, not jitter | cite-drift re-anchor, commit 9c74de3 (i21 repair wave); seed-replay witness `receipts/i20c-seed-replay.md` row 3 | green in i20c attempt-3 subsequent fences | 2 (r236, i20c) | CLOSED |
| F16 | T3 sdk-smoke watchdog exit 124 (teardown deadlock) | r240 (attempt 1, periphery) | teardown path hung; harness exited without forcing it | `receipts/r245-t3-teardown-fix.md` (hard exit forces the teardown path) | post-fix sdk-smoke runs in `receipts/i21c-t3-sdk-smoke.md` | 1 | CLOSED |
| F17 | `test/amqp/event_hubs_test.exs:402` — sweep cleared-count assertion (wire tier) | `receipts/i3-witness-sweep.md` §3 (run 1, 49 tests / 1 failure) | contention-class; batched multi-file invocations are not valid witnesses for these surfaces (I3 §4 falsifier note) | none | green on re-run in the same receipt | 1 | OPEN-ROTATING |

## Derive commands

Face identity in any court/full-suite log (`tmp/court-x2-v17-*.log`,
`tmp/mix-test-a3-*.log`, `tmp/seed-replay-71461-attempt3.log`) — one per row:

```
grep -F "test/arm_error_corpus_test.exs:274" tmp/court-x2-v17-wrap4.log      # F1
grep -F "test/corpus/shacl_fuzz.exs" tmp/court-x2-v17-wrap4.log              # F2-F4
grep -F "test/corpus/tags_normalization.exs:49" tmp/court-x2-v17-wrap4.log   # F5
grep -F "test/amqp/fuzz_test.exs:561" tmp/court-x2-v17-wrap4.log             # F6
grep -F "test/egress_dispatch_test.exs:1221" tmp/court-x2-v17-wrap2.log      # F7
grep -E "^\s+[0-9]+\) test" tmp/court-x2-v17-run1.log                        # F8 (75-row table)
grep -F "test/affidavit_wasm_failclosed_test.exs:502" tmp/court-x2-v17-wrap3.log  # F9
grep -F "smalt_subscriptions" tmp/mix-test-a3-postcourt.log                  # F10
grep -F "test/lro_test.exs:543" tmp/mix-test-a3-postcourt.log                # F11
grep -F ":sync, 5000" tmp/seed-replay-71461-attempt3.log                     # F12
grep -F "management_rpc_test.exs:770" docs/jira/v26.10.17/receipts/i21-full-suite-postfix.md  # F13 (scratch logs /tmp/i21_full*.log not preserved)
grep -F "store_churn_test.exs:37" docs/jira/v26.10.17/receipts/i21-full-suite-postfix.md      # F14
grep -F "ApiVersionMatrix" tmp/court-x2-v17-run1.log                         # F15
grep -F "test/amqp/event_hubs_test.exs:402" <i3 wire log>                    # F17
```

Attempt-5 classification protocol: a RED face matching a CLOSED row is a
witness that the fix regressed, not a new defect — cite the row, re-run the
fix receipt's hammer; a face matching an OPEN-ROTATING row keeps its named
mechanism (F6: measurement-fence jitter, fix shape pre-agreed in
`receipts/i22-fuzz-atom-fix.md`; F7/F14/F17: contention, solo-bisect first per
r236 §6 protocol) and gets a new recurrence count on this table.

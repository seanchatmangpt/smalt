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
| F6 | `test/amqp/fuzz_test.exs:561` — 5000 unique keys mint no new atoms | r246 (attempt 4, leg 1) | Named: secondary atom_count delta fence (<=10) can see >10 unrelated lazy-init mints under load; NOT atom pressure (table measured 38,197 / 1,048,576 ~3.6%, decode mints 0) | none — `receipts/i22-fuzz-atom-fix.md` stand-down NOT-REPRODUCIBLE (3/3 paired green, no measured failing distribution to calibrate slack); measurement in `receipts/i22-atom-pressure.md` | `receipts/i22-fuzz-atom-fix.md` (repro failed 3/3) + RETIRED at 885c451: fence converted to structural asserts (no atom-count delta bound remains) — `receipts/b3-fence10.md` carries the conversion-method receipt | structural-conversion retired the bound the face rode; 885c451 soak-C + B3 structural-fence conversion (`receipts/b3-fence10.md`) | 1 | RETIRED-CONVERTED |
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

## v26.10.18 window (appended 2026-10-18)

Witnesses: `docs/jira/v26.10.18/receipts/v1-soak.md` (6 full-suite runs across two
instances, 15:0x–15:21 PDT), `v2-soak.md` (3 full + 2 wire legs, 15:29–18:2x PDT),
`burn-soak-live.md` (9 burn attempts, 14:39–19:29 PDT, 10,813 tests / 80 failures /
58 unique faces), fixes `i23-fence11-flip.md`, `i24-store-dets-torn.md`, conversion
`azb-12-ratio.md`. Trees moved under the lanes (HEAD moved 6x mid-v2); every standing
is per-run-tree, stale-by-default per the header law.

| # | Face | First witness | Mechanism | Fix receipt | Hammer evidence | Recur | Standing |
|---|---|---|---|---|---|---|---|
| F18 | `test/store_churn_test.exs:37` — list_prefix mid-walk deletes, 0 rows (ledger F14 identity) | `receipts/v1-soak.md` run 3 (`/tmp/v1-soak-run3.log`) | Same OPEN-ROTATING row F14: concurrent churn deletes vs list_prefix walk; mechanism UNRESOLVED (i21d: table `:smalt_resources`, `/churn-test/` prefix not wiped by management_rpc) | none — recurrence count for F14: **+1** (now 2) | v1 run 3 1/3 runs; quiet 0/5 in v2 | 2 | OPEN-ROTATING (carries F14's solo-bisect-first protocol) |
| F19 | `test/store_dets_test.exs` torn-DETS probe — `{:needs_repair, …}` / `{:not_a_dets_file, …}` from `:dets.open_file(repair: false)` (F12 family, NEW mechanism) | pre-session 2/2 + 1/3; load-witnessed `receipts/i24-store-dets-torn.md` RED run 1 | `DetsMirror` mid-sync rewrites `dm_t_resources.dets`; a `repair: false` closed-read probe lands in the transient header/footer tear and is correctly refused — probe-side race, not mirror corruption; widening `repair: true` rejected (masks real corruption) | `receipts/i24-store-dets-torn.md` — test-side `probe_rows/1` bounded retry (20 x 250 ms, sized to the measured 4008 ms sync tail), retries ONLY the torn tuple shapes; `repair: false` never widened | red→green pair under 4 yes-hogs: RED 1/3 (bare-atom matcher missed tuple shape), corrected matcher GREEN 3/3 under same hogs + solo green | 1 (+2 pre-session) | CLOSED |
| F20 | `test/store_dets_test.exs:27` — `{:not_a_dets_file, ~c"…/dm_t_resources.dets"}` MatchError at probe (`:38`), full-suite fleet load | `receipts/v1-soak.md` Instance B diagnostic run 4 (`/tmp/v1_soak_run5.log`) | Same torn-file mechanism as F19 (per-run mirror dir under ~/.cache/tmp); same-row fix applies | `receipts/i24-store-dets-torn.md` (tuple-shape matcher — this run's exact tuple shape is the one the RED intermediate matcher missed) | i24 GREEN 3/3 under 4 hogs + solo | 1 | CLOSED (merged into F19's fix) |
| F21 | `test/affidavit_wasm_failclosed_test.exs` fence-11 supervisor noproc — setup `GenServer.stop(pid, :normal, :infinity)` EXIT noproc via `stop_engine/0` (`:37`→`:116`; faces at `:532`, `:280`, `:640`) | `receipts/v1-soak.md` run 1 (`:532`) + Instance B run 4 (`:640` EXIT :kill); shaken 5/13 in `receipts/i23-fence11-flip.md` | Two faces, one root: (A) supervisor owner killed/restarted the engine async between `whereis` and the setup stop → noproc; (B) hammer load workers `start_link`ed from `Task.async` bodies, kill-loop `:kill` propagated task→test — (B) closed mid-flight by the owning wasm-supervisor lane's `Process.flag(:trap_exit, true)` | `receipts/i23-fence11-flip.md` — `stop_engine/0` + `typed_start/1` `already_started` branch: bounded 5 s deadline + `{:noproc, _}` tolerance; face B disclosed as owner-lane patch | i23: shake 5/13 RED pre-fix → green gate 7/7 (5 solo + 2 hog) post-fix | 3 witnessed pre-fix (v1 2 legs + i23 shake) | CLOSED |
| F22 | `test/semantic_epoch_test.exs:323` — 10k parse vs raw-decode perf ratio `89.56 >= max 15.0` (subject_us 941,674 / baseline 10,514) | `receipts/v1-soak.md` Instance B diagnostic run 5 (under heavy concurrent load: 2 full-suite beams + ggen replay) | Load skew, not regression: single-shot absolute/ratio bound over an independent baseline is not co-monotonic under desched — solo re-run green confirmed load artifact; closed structurally by the AZB-12 conversion | `receipts/azb-12-ratio.md` — 3 absolute bounds → paired `assert_ratio(min-of-5 rounds, max: 6.0)` (subject and baseline timed back-to-back per round, co-monotonic under load); anti-vacuity shim P3e/P3f RED post-retighten | AZB-12: solo combined 5/5 green quiet-window; burn-chaos 8 hogs — all three converted fences GREEN, 0 of 16 loaded failures were converted fences | 1 | CLOSED |
| F23 | Stress-tier exclusion question — C1 `ExUnit.TimeoutError 60000ms` class: 80 failures / **58 unique faces**, ALL unledgered (mcp_wire 22, auth_enforce 9, pplan 3, azsim/integration 3, tls 2, canonical_projection 2, enclave_lifecycle 2, mcp 2, +10 files x1), load-correlated (load-1 109→442 across the window) | `receipts/burn-soak-live.md` (9 attempts, 4 hogs + AMQP atom-flood) | Saturation-timeout class: 60 s ExUnit budget under hog+flood load with fleet contention on top; per-face mechanism NOT individually bisected — the class question is whether these faces belong to a stress tier excluded from the default suite (v26.10.18 stress-tier draft `docs/jira/v26.10.18/rewrite-drafts/stress-tier.md`) or are per-test budget defects | none — OPEN per burn-soak-live follow-up (1): "ledger the C1 saturation-timeout faces or fix the owning tests"; C6 soak.sh per-leg-log truncation destroyed per-face evidence for attempts 6/9 | attempt-5 leg log witnessed 16/16 as `ExUnit.TimeoutError … timed out after 60000ms`; i22 atom-flood fix WITNESSED holding through the same window (290,458 flood closes, 0 error-level lines) | 80 failures / 58 faces, one window | OPEN — needs a disposition decision (stress-tier exclusion vs per-test budget fix); no face may be closed without a solo-bisect receipt |

Derive commands (v26.10.18 rows; scratch logs in `/tmp` are ephemeral — the
receipts carry verbatim captures):

```
grep -F "store_churn_test.exs:37" docs/jira/v26.10.18/receipts/v1-soak.md        # F18
grep -F "not_a_dets_file" docs/jira/v26.10.18/receipts/i24-store-dets-torn.md    # F19/F20
grep -F "stop_engine/0" docs/jira/v26.10.18/receipts/i23-fence11-flip.md         # F21
grep -F "89.56" docs/jira/v26.10.18/receipts/v1-soak.md                          # F22
grep -F "58 unique faces" docs/jira/v26.10.18/receipts/burn-soak-live.md         # F23
```

Attempt-5 classification note for this window: F18 keeps F14's protocol
(solo-bisect first); a timeout face matching F23 is load-class pending the
stress-tier disposition, not a new per-face defect; F19/F20/F21/F22 faces
matching their CLOSED rows after a fix regression is a re-open citing the
fix receipt, per the header protocol.

Attempt-5 classification protocol: a RED face matching a CLOSED row is a
witness that the fix regressed, not a new defect — cite the row, re-run the
fix receipt's hammer; a face matching an OPEN-ROTATING row keeps its named
mechanism (F6: measurement-fence jitter, fix shape pre-agreed in
`receipts/i22-fuzz-atom-fix.md`; F7/F14/F17: contention, solo-bisect first per
r236 §6 protocol) and gets a new recurrence count on this table.

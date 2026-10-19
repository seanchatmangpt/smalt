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

## v26.10.18 v2-soak wire/full faces (appended 2026-10-18)

Witnesses (5 legs, fleet-load, 15:32–19:27 PDT): `/tmp/v2_soak_run1.log`,
`/tmp/v2_soak_run2.log`, `/tmp/v2_soak_run3.log` (full suite) and
`/tmp/v2_soak_wire1.log`, `/tmp/v2_soak_wire2.log` (wire tier). Run summaries:
run1 2700 tests / 3 failures, run2 2674/17, run3 2026 tests / 17 failures, wire
legs 2747/2755 tests / 11 failures each. Trees moved under the lanes
(HEAD 014bb7a mid-window); every standing is per-run-tree, stale-by-default per
the header law. Cross-ref: `receipts/i27-deterministic-pair.md` is NOT landed
(no such file in `docs/jira/v26.10.18/receipts/`); the landed solo-bisect
sibling `receipts/i27-rotating-bisect.md` (tree 014bb7a, ~20:55 PDT) is cited
where its per-file verdicts cover a face's identity. Classification labels:
DETERMINISTIC-PAIR-KNOWN = face recurred with the same signature on paired legs
and the mechanism is registered (this ledger or i27); NEW-UNTRIAGED = no
registered mechanism yet.

### Proposed rows (F24–F57, 34 faces)

| # | Face | First witness | Mechanism hypothesis | Witness log | Classification |
|---|---|---|---|---|---|
| F24 | `test/stress_tier_census_test.exs:13` — stress tier population >= 20 (tag loss fails loudly) | run1 | MIXED SIGNATURES: run1 `File.Error` could not read `test/tiny_iso_probe_test.exs` (probe file absent on the run tree — the census correctly refused a missing stress-tier probe); run2/run3 `ExUnit.TimeoutError 60000ms` under fleet load. Both faces sit inside the F23 stress-tier disposition question | /tmp/v2_soak_run1.log (+run2/run3) | NEW-UNTRIAGED (F23 class) |
| F25 | `test/canonical_projection_test.exs:125/:134` — generated artifact drift fence docs/capabilities.json stale vs Registry truth | run1 (all 5 legs) | DETERMINISTIC doc drift: lanes moved Registry truth (lib/) without re-running `Smalt.Projection.Canonical.write()`; the fence correctly refuses the stale projection — same class as F15 cite-drift. Fix shape: regenerate, never hand-edit | /tmp/v2_soak_run1.log (+all legs) | DETERMINISTIC-PAIR-KNOWN |
| F26 | `test/pplan_test.exs:2490` — lens5 interaction lattice under a live sweeper: open-world law, `Enum.count(results, &match?({:ok,_})) <= 2` got 9 | run1 | Post-destroy sweep did not reclaim interaction rows before the count assertion — sweep-timing vs assertion ordering under load; unrelated to lens7 (F27) despite same module | /tmp/v2_soak_run1.log | NEW-UNTRIAGED |
| F27 | `test/pplan_test.exs:2875` — lens7 half-degraded window Store down, CAS paths exit `{:noproc, _}` typed (MatchError) | wire1 (wire tier, 2/2) | i27-rotating-bisect solo 2/2 DETERMINISTIC, new solo signature: `Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)` → `{:error, :not_found}` — `Smalt.Store` is not a live child of `Smalt.Supervisor` in the solo boot; supervision-tree shape drift | /tmp/v2_soak_wire1.log (+wire2) | DETERMINISTIC-PAIR-KNOWN (i27) |
| F28 | `test/azsim/data_plane_test.exs:156` — conditional HEAD/GET If-Modified-Since: unmodified -> 304 (assert / `nil.datetime_to_gregorian_seconds/1` UndefinedFunctionError run3) | run2 (2/3 full legs) | Setup chain: prior step returns nil HTTP-time and the conditional helper dereferences it — the run2 assert-fail and run3 nil-deref are two symptoms of one nil-time setup face | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED (pair presence) |
| F29 | `test/azsim/data_plane_test.exs:107` — range GET (wire) suffix range bytes=-5 returns 206 + Content-Range (MatchError) | run2 | Wire-tier range handler returned a shape the test's `=` did not admit; single witness | /tmp/v2_soak_run2.log | NEW-UNTRIAGED |
| F30 | `test/azsim/integration_plane_test.exs:37` — send/receive/complete round-trip (run2 `:ok` vs `{:ok, 1}`; run3 `delivery_count == 0` got 1) | run2 (2/3) | Two signatures: run2 is API-drift-deterministic (QueueStore.enqueue returns `{:ok,1}`, test pins `:ok`); run3 saw delivery_count 1 — a redelivery-face sibling in the same test | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED (pair presence) |
| F31 | `test/azsim/integration_plane_test.exs:261` — event grid: event published while down is delivered after recovery (falsifier guard) | run2 (2/3) | Recovery-delivery ordering under load; assert detail truncated in log capture — needs solo-bisect capture before mechanism call | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED |
| F32 | `test/azsim/integration_plane_test.exs:48` — abandon requeues; deadletter after max-delivery-count (run2 enqueue `:ok` vs `{:ok,1}`; run3 `delivery_count == 0` got 1) | run2 (2/3) | Same enqueue-return drift family as F30 plus delivery-count face — one shared setup/assert drift across the IntegrationPlane enqueue-assert cluster (F30/F32/F34 share the signature) | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED (pair presence) |
| F33 | `test/azsim/integration_plane_test.exs:212` — event grid: subscriber crash => redelivery with same id (never loss) | run2 (2/3) | Crash-redelivery timing under load; assert detail not captured — solo-bisect first | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED |
| F34 | `test/azsim/integration_plane_test.exs:137` — partition detach sends amqp:link:detach-forced; relink delivers (CaseClauseError, 2/3) | run2 (2/3) | Identical CaseClauseError on both legs — relink receive admitted an unexpected shape; pair-signature deterministic pending identity of the unmatched clause | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED (pair presence) |
| F35 | `test/azsim/control_plane_test.exs:110` — strict_version_validation unadmitted provider type refused 400 InvalidApiVersionParameter, got `InvalidResourceShape` | run2 | Route-order/shape-check fired before api-version validation on the run tree — deterministic-per-tree ordering face | /tmp/v2_soak_run2.log | NEW-UNTRIAGED |
| F36 | `test/tls_test.exs:215` — concurrency falsifier TLS-261014-01 paired boots N=20 zero crashes (ExUnit.TimeoutError 60000ms, 2/3) | run2 (2/3) | F23 saturation-timeout class: 60 s budget under hog+flood load; the 20-paired-boot falsifier is the intended stress face | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED (F23 class) |
| F37 | `test/azsim/identity_plane_test.exs:298` — key rotation re-create issues a new version; old still decrypts (failed at `v1 = create_key(name)`) | run2 | Setup call failed before any assertion — create_key transport/setup face, likely shared with F38 | /tmp/v2_soak_run2.log | NEW-UNTRIAGED |
| F38 | `test/azsim/identity_plane_test.exs:343` — key rotation versions listing carries every issued version (failed at `v1 = create_key(name)`) | run2 | Same create_key setup face as F37 — one mechanism, two identities | /tmp/v2_soak_run2.log | NEW-UNTRIAGED |
| F39 | `test/azsim/identity_plane_test.exs:195` — KD-15 mode-blind challenge (AZB-08) challenge echoes request origin; no authorization_uri | run2 | WWW-Authenticate echoed `http://vault.smalt.local:59338/...` — the inbound Host (ephemeral per-run-tree port, http scheme) instead of the canonical TLS-twin 8443 shape the test pins; deterministic-per-tree echo face | /tmp/v2_soak_run2.log | NEW-UNTRIAGED |
| F40 | `test/data_plane/r133_policy_cas_test.exs:24` — concurrent metadata PUTs vs hold-sets, committed holds never lost (W5-8 race) (ExUnit.TimeoutError 60000ms) | run2 | F23 saturation-timeout class; race falsifier under hog load | /tmp/v2_soak_run2.log | NEW-UNTRIAGED (F23 class) |
| F41 | `test/compliance/c1_arm.exs:386` — 429 + Retry-After when :smalt, :arm_rate_limit configured (statuses were all 200, 2/3) | run2 (2/3) | DETERMINISTIC pair: identical left/right both legs — the run tree had the rate limiter unconfigured (or config read drifted); the falsifier correctly refused the un-enforced contract | /tmp/v2_soak_run2.log (+run3) | DETERMINISTIC-PAIR-KNOWN |
| F42 | `test/data_plane/blob_hardening_test.exs:1665` — ST6 D2 pagination perf contract: 10-page chain over 8000x2KiB under budget (2/3) | run2 (2/3) | Perf-budget face under fleet load; if solo re-run is green, load-class per F22/AZB-12 conversion (paired-ratio shape) | /tmp/v2_soak_run2.log (+run3) | NEW-UNTRIAGED (pair presence) |
| F43 | `test/amqp/lock_manager_test.exs:211` — session locks renew by token updates BOTH :smalt_sb_locks and :smalt_sb_sessions (F2) | run3 | Lock renew returned non-`{:ok,_}`; sibling of the F2 lock mechanism family | /tmp/v2_soak_run3.log | NEW-UNTRIAGED |
| F44 | `test/smalt_affidavit_wasm_test.exs:89` — mutated payload / garbage delta fail closed typed, no crash-loop (GenServer.stop EXIT noproc) | run3 | F21 family: `stop_engine/0` noproc tolerance was landed in `receipts/i23-fence11-flip.md` — this is a POST-fix noproc witness; per header protocol this is a fix-regression check citing i23, not a new defect, until i23's hammer is re-run | /tmp/v2_soak_run3.log | NEW-UNTRIAGED (F21/i23 re-open check) |
| F45 | `test/amqp/sweeper_test.exs:77` — message-lock tombstone grace (audit Finding 3): past grace, renew is 404 :not_found | run3 | Assert on `LockManager.get` result did not match; tombstone-grace timing vs sweeper cadence under load | /tmp/v2_soak_run3.log | NEW-UNTRIAGED |
| F46 | `test/mcp_test.exs:1247` — lens6 concurrent tools/call under descriptor module reload stays payload-faithful (Task.await_many 30000ms EXIT time out) | run3 | 30 s await budget exceeded under fleet load; hammer+reloader tasks starved — load-class candidate | /tmp/v2_soak_run3.log | NEW-UNTRIAGED |
| F47 | `test/auth_enforce_test.exs:2165` — lens4 cap side: at the cap the mint still succeeds (ExUnit.TimeoutError 60000ms) | run3 | F23 saturation-timeout class | /tmp/v2_soak_run3.log | NEW-UNTRIAGED (F23 class) |
| F48 | `test/apiversion_matrix_test.exs:278` — generic_provider_put PUT api-version 2099-12-31 -> 400 InvalidApiVersionParameter (ArgumentError) | run3 | ArgumentError raised inside the handler on the run tree — deterministic-per-tree shape face (sibling of F35's ordering class) | /tmp/v2_soak_run3.log | NEW-UNTRIAGED |
| F49 | `test/error_codes_doc_test.exs:46` — docs/ERROR_CODES.md byte-identical projection of sources | wire1 (wire tier, 2/2) | DETERMINISTIC doc drift: error-code sources moved without `just gen-error-codes` regeneration; fence correct. Wire legs pair 2/2 with identical identity | /tmp/v2_soak_wire1.log (+wire2) | DETERMINISTIC-PAIR-KNOWN |
| F50 | `test/enclave_ocel_test.exs:52` — a real lifecycle run emits one stage event per stage (assert {:ok, report} = Lifecycle.run) | wire1 (2/2) | i27-rotating-bisect solo 2/2 DETERMINISTIC: destroy stage leaves residue `:smalt_sb_queues: ["resourcewritesuccess"]` → `ORPHANED_DATA_PLANE_ROWS_DETECTED`, Lifecycle.run `{:error, {:stage_failed, :lifecycle, _}}` — one shared enclave-residue cause (F50/F51/F53/F54) | /tmp/v2_soak_wire1.log (+wire2) | DETERMINISTIC-PAIR-KNOWN (i27) |
| F51 | `test/enclave_state_test.exs:173` — destroy: reverse-topological deletes, all 404, residue zero | wire1 (2/2) | Same i27 enclave-residue mechanism as F50 | /tmp/v2_soak_wire1.log (+wire2) | DETERMINISTIC-PAIR-KNOWN (i27) |
| F52 | `test/mcp_test.exs:420` — doctor.summary reports real supervisor children, table readiness (`Smalt.Store` child missing) | wire1 (2/2; also hyphen-log runs 1–3) | Store child absent from doctor summary on the wire-tier boot — supervision-tree/doctor-agreement face; i27 did not cover McpTest solo, mechanism unregistered | /tmp/v2_soak_wire1.log (+wire2) | NEW-UNTRIAGED (pair evidence) |
| F53 | `test/enclave_lifecycle_test.exs:106` — OCEL stage emission fail-safe, registry-gated, never lifecycle-failing | wire1 (2/2) | Same i27 enclave-residue mechanism as F50 | /tmp/v2_soak_wire1.log (+wire2) | DETERMINISTIC-PAIR-KNOWN (i27) |
| F54 | `test/enclave_lifecycle_test.exs:56` — composite baseline fixture lifecycle green end to end | wire1 (2/2) | Same i27 enclave-residue mechanism as F50 | /tmp/v2_soak_wire1.log (+wire2) | DETERMINISTIC-PAIR-KNOWN (i27) |
| F55 | `test/mcp_wire_test.exs:806` — doctor.summary agrees with scripts/doctor.py --json (`Smalt.Store` child missing) | wire1 (2/2; also hyphen-log runs 1–3) | Same doctor-summary face as F52 across both doctor identities | /tmp/v2_soak_wire1.log (+wire2) | NEW-UNTRIAGED (pair evidence) |
| F56 | `test/azsim/adversarial_joe_test.exs:121` — Vector 3: half-open TCP silent partition unlinks broker resources cleanly (FrameCodec decode assert) | wire1 (2/2) | Identical decode-shape assert both legs — pair-deterministic; the relink frame arrived in a shape the codec assert refused | /tmp/v2_soak_wire1.log (+wire2) | NEW-UNTRIAGED (pair evidence) |
| F57 | `test/azsim/adversarial_joe_test.exs:32` — Vector 1: mailbox overload/backpressure flood (ArgumentError from linked pid) | wire1 (2/2) | ArgumentError raised in a linked process under flood both legs; identical pair signature | /tmp/v2_soak_wire1.log (+wire2) | NEW-UNTRIAGED (pair evidence) |

Derive commands (v2-soak wire/full rows; logs are ephemeral `/tmp` scratch —
identities above were captured verbatim from the live logs at ledger time):

```
grep -E "^\s+[0-9]+\) test" /tmp/v2_soak_run1.log     # F24-F26
grep -E "^\s+[0-9]+\) test" /tmp/v2_soak_run2.log     # F25, F28-F42
grep -E "^\s+[0-9]+\) test" /tmp/v2_soak_run3.log     # F25, F28, F30, F43-F48
grep -E "^\s+[0-9]+\) test" /tmp/v2_soak_wire1.log    # F25, F27, F49-F57
grep -E "^\s+[0-9]+\) test" /tmp/v2_soak_wire2.log    # same 11 as wire1 (pair evidence)
grep -F "resourcewritesuccess" docs/jira/v26.10.18/receipts/i27-rotating-bisect.md  # F50/F51/F53/F54
```

Ledger-integrity notes for this block: (1) the failure-count drift vs the
`v2-soak.md` receipt's 9/9/8 full-leg counts is a filename disambiguation — the
receipt counts the LATER hyphen-named logs `/tmp/v2-soak-run{1,2,3}.log`
(20:11–20:52 PDT); this block ledgers the EARLIER underscore-named
`/tmp/v2_soak_run{1,2,3}.log` + `/tmp/v2_soak_wire{1,2}.log` legs (15:32–19:27
PDT) as directed, whose unique-face superset includes most hyphen-log
identities (enclave cluster, doctor-summary pair, lens7). (2) The wire legs
failed the identical 11 faces in the identical order — that identity is itself
the pair evidence behind the wire-tier classifications. (3) F44 (post-i23
noproc witness) must be dispositioned against `receipts/i23-fence11-flip.md`'s
hammer, not closed as a new mechanism. (4) All NEW-UNTRIAGED faces follow the
solo-bisect-first protocol (r236 §6 / i27 method) before any fix lands.

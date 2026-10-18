# REWRITE-STATUS — v26.10.18 test-surface rewrite wave

Live tracker for the batch wave defined in `rewrite-drafts/00-MASTER-PLAN.md`.
Updated per wake (120s x40) by the milestone-doc tracker lane. No other edits.

Statuses: BLOCKED (prerequisite unmet / not started), RUNNING (in-flight work
observable), LANDED (receipt + validation evidence on disk), FAILED (receipt
records failure).

Last wake: 2026-10-18 wake 4. Receipts dir now live
(docs/jira/v26.10.18/receipts/).

## Batch table

| Batch | Spec (drafts) | Status | Receipt | Validation evidence |
|---|---|---|---|---|
| B0 | foundations P0 (+c567 uid/1) | LANDED (ALIVE) | receipts/b0-foundations.md | test_helper smoke 2/0; 37/37 reference suites; real test_helper path |
| b-await-migration | lib await-migration (sites 4+5) | LANDED (PARTIAL_ALIVE: sites 4+5 landed, sites 1-3 gated on b-lro-notifier) | receipts/b-await-migration.md | mix compile --warnings-as-errors exit 0; pplan 70/0; enclave 15/0 x2; 92-162/0 x2; sleep-grep zero hits both files |
| B1 | corpus-compliance | LANDED (ALIVE) | receipts/b1-corpus.md | corpus 26/0 x3 (verdicts 668/214/118 byte-equal across runs); compliance 157/0 x2; c3 divergence closed by construction |
| B2 | amqp.md x5 files | LANDED (ALIVE; draft deviations verified-then-landed; hang fail-safes kept with role comments) | receipts/b2-amqp.md | amqp 331/0 (45 excluded); wire tier 376/0 passes A+B |
| B3 | fence10-ratio + sleeps A5 | LANDED (ALIVE — structural conversion (lib-redesign path per R4), vacuity-probed, 12x-green; ratio fence NOT landed, per R4 alternatives) | receipts/b3-fence10.md | fence-10 sleep-free; affidavit suite green incl. fence line-numbered failure output |
| B4 | store-lro-wasm §1/§2 + lro backdate + sleeps A1-A7/B2 | LANDED (PASS; mid-session lro 37/3 were sibling WIP — receipt run 37/0) | receipts/b4-lro-store.md | store_dets stress 6/0 x2 + receipt run; lro 37/0; corpus 19/0 x3; blob 116/0 x2; MIX_BUILD_ROOT=_build-ft-b4 |
| b-wasm-supervisor | lib-redesign-wasm-lro Part 1 | LANDED (ALIVE; full suite run was in flight at wake 15) | receipts/b-wasm-supervisor.md | affidavit fences 1-12 green incl. fence-11 hammer + fence-12 already_started passthrough, MIX_BUILD_ROOT=_build-ft-ws |
| b-lro-notifier | LRO one-writer convergence (Notifier + await) — unblocks b-await-migration sites 1-3 | LANDED (PARTIAL_ALIVE -> ALIVE pending full-suite receipt, per receipt self-note) | receipts/b-lro-notifier.md | 37/0; 23/0 (2 excluded); B0-3 notifier-down typed fail-safe fence |
| B5 | auth-wire-egress + e2e-wire D1/D4 | LANDED (ALIVE; one order-dependent leak-batch defect (token_audiences) found+fixed in-batch) | receipts/b5-auth-wire.md | all touched files green x2; full wire tier green; eventgrid pair 21/0; MIX_BUILD_ROOT=_build-ft-b5 |
| v-pinion-audit | wire-pinion audit (§3 risk note) | LANDED (PASS 16/16 pinions, 0 dropped, 0 CRITICAL; pins 5-9 were PENDING-RECEIPT at audit time — b5 has since filed, b2 still owed) | receipts/v-pinion-audit.md | per-pinion verdict table; textual survival re-verified after each observed mtime change |
| B6 | apiversion-refusal + arm_error_corpus 2nd pass + mcp-ash-misc §1/§2 | LANDED-PARTIAL (PASS files 1+2 cite-system; arm_error_corpus 2nd pass + mcp-ash-misc §1/§2 + trust_profile deferred to post-B4 sequential pass) | receipts/b6-cites.md | apiversion_matrix 243/0 x2; wire_tier_refusal_sweep 3/0 x2; RouteCites registry 17 keys, fence fails on handler rename |
| b-e2e-wire | e2e-wire D1/D4 | LANDED (ALIVE) | receipts/b-e2e-wire.md | touched suites 57/0 x2 exit 0; s6 mix-run exit 0 EXACTLY_ONCE_OK; leak gate FAIL-TREE-LEAKS = pre-existing baseline, non-regression |
| B7 | gates-python + js-harness + e2e-wire D2/D3 + stress tagging + budget-gate | BLOCKED (B0) | — | — |
| B8 | NO-SLEEP-DOCTRINE sleep gate + lib WOs + c567 c6 + docs wrap | LANDED (PARTIAL_ALIVE — gate ALIVE+non-vacuous; full-tree honest red: 38 unclassified test/ sites) | receipts/b8-doctrine.md | sleep_gate lib/ PASS 135 files 0 sleeps; MIX_BUILD_ROOT=_build-b8 compile exit 0; doctor+lro 40/0; court shim + loud-skip wiring |
| b-js-harness | js-harness node harnesses + gates-python slice (run.sh excluded per R7) | LANDED (ALIVE) | receipts/b-js-harness.md | sdk-smoke pass 7 fail 0 x2; pytest 102 passed; typed exit 2 SUBSTRATE_TIMEOUT fast-fail witnessed |
| b-e2e-wire | e2e-wire D1/D4 (in B5), D2/D3 (in B7) | BLOCKED (B0) | — | — |
| b-wasm-supervisor | lib-redesign-wasm-lro Part 1 (coordinator call, 2.1) | BLOCKED (coordinator decision) | — | — |
| b-lro-notifier | lib-redesign-wasm-lro LRO Notifier | BLOCKED (coordinator decision) | — | — |
| b-await-migration | — (await migration tier) | BLOCKED | — | — |
| v1-soak | validation gate seq (§4) soak leg 1 | NOT STARTED | — | — |
| v2-soak | validation gate seq (§4) soak leg 2 | NOT STARTED | — | — |
| v-pinion-audit | wire-pinion audit (§3 risk note) | NOT STARTED | — | — |

## Dependency violations

None observed. B8 landed before B1/B5 as PARTIAL_ALIVE with an honest-red
full-tree sleep census (38 unclassified test/ sites) — sequenced early but
self-declared as the repair surface, not a violation. B6's arm_error_corpus
second pass correctly deferred to post-B4 per master plan §1.3.

## Completion

11/18 batches LANDED (61%): B0, B1, B3, B4, B6 (partial), B8 (partial),
b-await-migration, b-e2e-wire, b-js-harness, b-wasm-supervisor, b-lro-notifier.
Outstanding: B2 (amqp), B5 (auth-wire-egress), B7 (gates-python/budget/stress
non-JS slice), v1-soak, v2-soak, v-pinion-audit. W-review lanes: 17/18
(w14-review.md ABSENT — _build-ft-w14 lane in flight, coordinator WORKQUEUE
also flags it).

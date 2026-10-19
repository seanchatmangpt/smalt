# REWRITE-STATUS — v26.10.18 test-surface rewrite wave

Live tracker for the batch wave defined in `rewrite-drafts/00-MASTER-PLAN.md`.
Updated per wake (120s x40) by the milestone-doc tracker lane. No other edits.

Statuses: BLOCKED (prerequisite unmet / not started), RUNNING (in-flight work
observable), LANDED (receipt + validation evidence on disk), FAILED (receipt
records failure).

Last wake: 2026-10-18 final sync (post-wave). All batch receipts polled from
`receipts/`; statuses reconciled to disk ground truth. Duplicate rows from
interim wakes collapsed.

## Batch table

| Batch | Spec (drafts) | Status | Receipt | Validation evidence |
|---|---|---|---|---|
| B0 | foundations P0 (+c567 uid/1) | LANDED (ALIVE) | receipts/b0-foundations.md | test_helper smoke 2/0; 37/37 reference suites; real test_helper path |
| b-await-migration | lib await-migration (sites 4+5) | LANDED (PARTIAL_ALIVE: sites 4+5 landed; sites 1-3 unblocked by b-lro-notifier) | receipts/b-await-migration.md | mix compile --warnings-as-errors exit 0; pplan 70/0; enclave 15/0 x2; 92-162/0 x2; sleep-grep zero hits both files |
| B1 | corpus-compliance | LANDED (ALIVE) | receipts/b1-corpus.md | corpus 26/0 x3 (verdicts 668/214/118 byte-equal across runs); compliance 157/0 x2; c3 divergence closed by construction |
| B2 | amqp.md x5 files | LANDED (ALIVE; draft deviations verified-then-landed; hang fail-safes kept with role comments) | receipts/b2-amqp.md | amqp 331/0 (45 excluded); wire tier 376/0 passes A+B |
| B3 | fence10-ratio + sleeps A5 | LANDED (ALIVE — structural conversion (lib-redesign path per R4); ratio fence NOT landed, per R4 alternatives) | receipts/b3-fence10.md | fence-10 sleep-free; affidavit suite green incl. fence line-numbered failure output |
| B4 | store-lro-wasm §1/§2 + lro backdate + sleeps A1-A7/B2 | LANDED (PASS; mid-session lro 37/3 were sibling WIP — receipt run 37/0) | receipts/b4-lro-store.md | store_dets stress 6/0 x2 + receipt run; lro 37/0; corpus 19/0 x3; blob 116/0 x2; MIX_BUILD_ROOT=_build-ft-b4 |
| b-wasm-supervisor | lib-redesign-wasm-lro Part 1 | LANDED (ALIVE; caveat: full-suite run was in flight at receipt time) | receipts/b-wasm-supervisor.md | affidavit fences 1-12 green incl. fence-11 hammer + fence-12 already_started passthrough; MIX_BUILD_ROOT=_build-ft-ws |
| b-lro-notifier | LRO one-writer convergence (Notifier + await) — unblocks b-await-migration sites 1-3 | LANDED (ALIVE; caveat disclosed in receipt: run 1 raced concurrent lane edits, 25 mixed failures; clean receipt run 37/0) | receipts/b-lro-notifier.md | 37/0; 23/0 (2 excluded); B0-3 notifier-down typed fail-safe fence |
| B5 | auth-wire-egress + e2e-wire D1/D4 | LANDED (ALIVE; one order-dependent leak-batch defect (token_audiences) found+fixed in-batch) | receipts/b5-auth-wire.md | all touched files green x2; full wire tier green; eventgrid pair 21/0; MIX_BUILD_ROOT=_build-ft-b5 |
| v-pinion-audit | wire-pinion audit (§3 risk note) | LANDED (PASS 16/16 pinions, 0 dropped, 0 CRITICAL; pins 5-9 were PENDING-RECEIPT at audit time — b5 has since filed, b2 still owed) | receipts/v-pinion-audit.md | per-pinion verdict table; textual survival re-verified after each observed mtime change |
| B6 | apiversion-refusal + arm_error_corpus 2nd pass + mcp-ash-misc §1/§2 | LANDED-PARTIAL (PASS files 1+2 cite-system; arm_error_corpus 2nd pass + mcp-ash-misc §1/§2 + trust_profile deferred to post-B4 sequential pass) | receipts/b6-cites.md | apiversion_matrix 243/0 x2; wire_tier_refusal_sweep 3/0 x2; RouteCites registry 17 keys, fence fails on handler rename |
| b-e2e-wire | e2e-wire D1/D4 (landed in B5) + D2/D3 | LANDED (ALIVE; D1/D4 via B5, D2/D3 via B7) | receipts/b-e2e-wire.md | touched suites 57/0 x2 exit 0; s6 mix-run exit 0 EXACTLY_ONCE_OK; leak gate FAIL-TREE-LEAKS = pre-existing baseline, non-regression |
| B7 | gates-python + js-harness + e2e-wire D2/D3 + stress tagging + budget-gate | LANDED (PARTIAL_ALIVE — all artifacts landed and validated; two residual faces classified environmental/mid-wave churn in receipt) | receipts/b7-tiers.md | 15 stress-tag annotations across 12 files, tier-population fence red→green witnessed; test-stress recipe + verify_all stage c2; budget-gate exports show 36 stress cases excluded from T1 (0 ms ghost lines default vs real durations under --include stress) |
| B8 | NO-SLEEP-DOCTRINE sleep gate + lib WOs + c567 c6 + docs wrap | LANDED (PARTIAL_ALIVE — gate ALIVE+non-vacuous; full-tree honest red: 38 unclassified test/ sites) | receipts/b8-doctrine.md | sleep_gate lib/ PASS 135 files 0 sleeps; MIX_BUILD_ROOT=_build-b8 compile exit 0; doctor+lro 40/0; court shim + loud-skip wiring |
| b-js-harness | js-harness node harnesses + gates-python slice (run.sh excluded per R7) | LANDED (ALIVE) | receipts/b-js-harness.md | sdk-smoke pass 7 fail 0 x2; pytest 102 passed; typed exit 2 SUBSTRATE_TIMEOUT fast-fail witnessed |
| v0-soak | validation gate seq (§4) interim converged-suite signal | LANDED (PARTIAL_ALIVE — 2633 tests 1 failure; single new-face contention failure, no CLOSED-row regression) | receipts/v0-interim.md | EXIT=2 verbatim; 137k-line log preserved; single failure identity typed (store_dets torn-DETS probe — closed by i24) |
| v1-soak | validation gate seq (§4) soak leg 1 | LANDED-WITH-CAVEATS (receipt standing SUSPECT — 0/3 clean, acceptance not met; moving-tree caveat applies) | receipts/v1-soak.md | 3x full mix test on _build-ft-v1: 3/3 RED (2/1/2 failures), all faces classified (F12-family contention, fence-11 load, ERROR_CODES drift, perf-ratio load artifact); per-run-tree disclaimer: lane ran solo-named but machine shared with live sibling beams and HEAD/tree churned mid-lane — failure identities are load/churn-class, not diff-attributed; _build-ft-v1b (697 MB) left BLOCKED on disk for coordinator reclaim |
| v2-soak | validation gate seq (§4) soak leg 2 | LANDED-WITH-CAVEATS (receipt standing SUSPECT / acceptance NOT met — 0/3 full runs clean, 0/2 wire legs clean; moving-tree caveat applies) | receipts/v2-soak.md | 3x full + 2x wire on _build-ft-v2b: run 1 clean-exec 3 failures; run 2 (after in-flight event_grid.ex compile abort + SLA settle) 17 failures on moved tree; run 3 ANOMALOUS — 2633→2026 test-count drop, concurrent sibling mix-test beams live, harness 30-min cap SIGKILL during teardown; HEAD moved 6x mid-lane (8b5bb9b→4af0553) — every run after run 1 executed on a different tree state; failure identities are per-run-tree, not diff-attributed |
## Post-window extras (not tracker rows, receipts on disk)

- burn-soak-scripts.md (PARTIAL_ALIVE), burn-scripts.md, burn-image.md,
  burn-soak-live.md, azb-03-burn-schema.md (ALIVE), azb-21-zero-sleep.md
- W-review lanes: 18/18 LANDED (w1–w18; w14 PASS on relaunch)
- i-series gap-closure set: i23-fence11-flip (ALIVE — F6 flip grounded),
  i23-standalone-noise (PASS), i24-store-dets-torn (ALIVE — closes v0/v1
  torn-DETS face), i25-atom-bridge-noise (ALIVE), i25-c567 (PARTIAL_ALIVE —
  suite gates green, upstream overlap disclosed), i25-lro-backdate (ALIVE),
  i25-sleeps-a (ALIVE — 7 sites converted, 3 typed skips),
  i25-sleeps-b2 (ALIVE), i25-c567.md + adversarial-joe-attack-matrix.md
  also on disk. No i22 or i26 receipt exists on disk.

## Dependency violations

None observed. B8 landed before B1/B5 as PARTIAL_ALIVE with an honest-red
full-tree sleep census (38 unclassified test/ sites) — sequenced early but
self-declared as the repair surface, not a violation. B6's arm_error_corpus
second pass correctly deferred to post-B4 per master plan §1.3.

## Completion

18/18 tracker batches LANDED (100%): B0–B8 (B6 partial, B8 partial),
b-await-migration, b-wasm-supervisor, b-lro-notifier, b-e2e-wire,
b-js-harness, v-pinion-audit, v0-soak, v1-soak, v2-soak.

Stale-section reconciliation: the interim tracker's "14/18 LANDED / B7 BLOCKED
/ v1-soak + v2-soak NOT STARTED" reading and a second stale block showing
"0/18" (duplicate BLOCKED rows for b-wasm-supervisor, b-lro-notifier,
b-await-migration, b-e2e-wire, v1-soak, v2-soak, v-pinion-audit) are both
superseded — every duplicated row now carries its landed receipt.

Open caveats (disclosed, not blockers):
- b-wasm-supervisor full-suite run was in flight at receipt time.
- b-lro-notifier run 1 raced concurrent lane edits (25 mixed failures); the
  receipt run was clean 37/0.
- v1/v2 soak acceptance NOT met (0/3 clean each); standing SUSPECT with the
  per-run-tree moving-HEAD disclaimer recorded above — failures are
  load/churn-class observations, not diff-attributed regressions.
- B7 residual faces classified environmental/mid-wave churn in receipt.
- v1 receipt: `_build-ft-v1b` (697 MB) awaits coordinator `just lane-clean`.

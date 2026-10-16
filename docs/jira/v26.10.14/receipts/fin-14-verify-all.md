# fin-14 verify-all witness receipt

Lane: fin-14 (DoD-only finish lane, no commits) · Checkout: /Users/sac/smalt · Date: 2026-10-15 · Head at witness: 518b31a (moving — coordinator landing mid-run)

## Command

`just verify-all` (recipe present in `just --list` on first poll; no script fallback needed).

## Stage table (witnessed)

| stage | verdict | detail |
|---|---|---|
| doctor | PASS | 0 FAIL, 2 WARN |
| doctor-dod | PASS | — |
| test-offline | FAIL exit 2 | 1898 tests, 3 failures (run 1); rerun: 1 failure |
| workspace-court | PASS | node workspace/scripts/e2e-court.mjs, 40 PASS / 0 FAIL / 1 SKIP |
| smalt-cli-pytest | FAIL exit 2 | run 1: collection error — SUBSTRATE_LOCK_TIMEOUT on /tmp/smalt-substrate-cli5.lock (120s); rerun: 6 failed / 114 passed / 9 errors (cosmos fixture substrate contention) |
| naming-sweep | FAIL exit 1 | run 1: 1 violation (eh-run.mjs:144) ; post-commit rerun: 160 (see classification) |
| invariant-gates | PASS | all gates ok |

`[VERIFY-ALL] FAIL: 3 stage(s) failed.` — exit 1.

## Classification

### test-offline — REAL (flaky, timing), reported
- Run 1 (in verify-all): 3 failures. Isolated rerun (`just test-offline`): 1 failure —
  `Smalt.Amqp.BrokerFacadeTest "test Sweeper GCs expired Event Hubs processing claims"` —
  `assert EventHubs.sweep() >= 1` returned 0 (test/amqp/broker_facade_test.exs:151).
  Failure count varies run to run (3 → 1) under concurrent-lane load: timing-sensitive
  sweep/claim-expiry assertions. Not mechanical; needs owner fix (deterministic clock or
  expiry-boundary control), not a regen/pin.

### smalt-cli-pytest — MECHANICAL-FROM-SESSION (cross-lane substrate-lock contention)
- Run 1: collection aborted after 120s waiting on /tmp/smalt-substrate-cli5.lock, holder
  identified via lsof as another lane's Python (pid 72527) plus a bash/flock pair on
  /tmp/smalt-substrate.lock. Rerun got through collection but cosmos fixture tests errored
  (9 errors, all test_cosmos.py, azure data-plane substrate contention; 114 passed).
  Fix locus: coordinator-level serialized substrate lease across lanes, not code.

### naming-sweep — MIXED: 1 mechanical (FIXED), 160 coordinator-integration churn
- Fixed (this lane): `test/sdk-smoke/eh-run.mjs` had `REPO = "/Users/sac/smalt"` and
  `SMALT_SDK_ROOT` fallback literal `/Users/sac/cai/athena/...`. Replaced REPO with
  `path.resolve(HERE, "../..")`, fallback with `path.join(os.homedir(), ...)`;
  `node --check` clean. Retired stale allowlist pins `eh-run.mjs:143`/`:14`, added `:145`
  (homedir fallback still contains literal `cai`, allowlisted) in scripts/naming_sweep.sh.
- Remaining 160: /Users/sac/smalt mentions inside docs/jira/v26.10.14/receipts/*.md and
  workspace/ lane notes that became git-tracked only when coordinator landed 518b31a
  mid-run (first witness run saw 1 violation; post-commit tree shows 160). These are
  other lanes' receipt prose deliberately quoting the checkout path — same self-quote
  class the sweep already excludes for other receipt surfaces. Fix locus: coordinator /
  naming-sweep owner (lane 14): extend the sweep's machine-receipt/self-quote exclusion
  to docs/jira/v26.10.14/receipts/ + workspace/ (or scrub prose), not this lane.

## Session deltas (this lane only)

- test/sdk-smoke/eh-run.mjs (absolute-path removal, syntax-verified)
- scripts/naming_sweep.sh (allowlist repin :143/:14 → :145)
- docs/jira/v26.10.14/receipts/fin-14-verify-all.md (this file)

## Verdict

VERIFY-ALL: FAIL — 1 real flaky stage (test-offline, EventHubs sweep timing),
1 mechanical contention stage (smalt-cli-pytest, substrate lock), 1 mixed gate
(naming-sweep: eh-run.mjs fixed here; 160 doc-receipt hits = coordinator scope).

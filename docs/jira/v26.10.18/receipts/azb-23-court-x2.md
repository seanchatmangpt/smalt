# AZB-23 — court-x2 final close (typed-RED, gate carried)

- **Window**: v26.10.18 / i29
- **Subject**: AZB-23 court-x2 at the v26.10.18 wrap tree (receipt of record:
  `docs/jira/v26.10.18/receipts/i29-court-x2-final.md`; per-attempt logs
  `tmp/court-x2-1792*.log`)
- **Standing**: TYPED-RED (gate carried)
Context: solo(/Users/sac/smalt)
- **Date**: 2026-10-19

## Verdict

No two-consecutive-greens were witnessed at the gate. The gate is closed
typed-RED and CARRIED to v26.10.19 as its first work order (alongside WO-1,
the burn-ring re-run): the residual is a bounded family of 4-6 genuine
cross-plane boot-order races — solo-green everywhere, failing under
fresh-boot ordering — not load flake and not premise rot.

## Attempt ledger

The court-x2 attempt ledger is `docs/jira/v26.10.18/receipts/i29-court-x2-final.md`
(8 gate entries, 1792397604 → 1792402305), each backed by a verbatim log
`tmp/court-x2-<id>.log`. Real verdict lines from the logs:

```
tmp/court-x2-1792397604.log   1 doctest, 7 properties, 2755 tests, 5 failures (99 excluded)
tmp/court-x2-1792398603.log   run1 NOT GREEN / run2 0 failures — GREEN
tmp/court-x2-1792399039.log   run1 NOT GREEN / run2 NOT GREEN (1 / 4 failures + 1 invalid)
tmp/court-x2-1792399378.log   run1 NOT GREEN / run2 0 failures — GREEN
tmp/court-x2-1792399870.log   run1 NOT GREEN / run2 NOT GREEN (8+1 / 5+1)
tmp/court-x2-1792400897.log   run1 0 failures — GREEN / run2 NOT GREEN (2 failures)
tmp/court-x2-1792401910.log   run1 0 failures — GREEN / run2 NOT GREEN (2 failures)
tmp/court-x2-1792402305.log   run1 NOT GREEN / run2 NOT GREEN (4 / 5 failures)
```

Note on the ledger's UNPARSED lines: the sed verdict patterns in
`scripts/court23.sh` (lines 40-41) did not match `court_x2.sh`'s actual
"Run N summary line: … — GREEN/NOT GREEN" text, so
`i29-court-x2-final.md` records every entry UNPARSED; the verbatim verdicts
above are read directly from the logs (parser note first recorded in
`i29-colima-stop-runbook.md` §gate @ 1792399378).

## Green witnesses (run-level, never two-consecutive)

- Attempt @1792400897 run1 GREEN — 2755 tests / 0 failures (1 invalid)
  (`tmp/court-x2-1792400897.log`, "Run 1 summary line: 0 failures — GREEN").
- Attempt @1792399378 run2 GREEN — 0 failures, full suite after passing the
  tf-plan-smoke stage (`tmp/court-x2-1792399378.log`, "Run 2 summary line:
  0 failures — GREEN"; run1 aborted pre-suite in tf apply, detail in
  `i29-colima-stop-runbook.md` §gate @ 1792399378).
- Attempt @1792401910 run1 GREEN — 0 failures
  (`tmp/court-x2-1792401910.log`, "Run 1 summary line: 0 failures — GREEN").
- Dry5 rehearsal leg both-green ×2 — 2733 tests / 0 failures, exit 0 both
  runs (`i29-court-dry5.md` §Runs).
- Full-soak leg C — 2728 tests / 0 failures (`i29-full-soak-d.md`
  §"Leg C: 0 failures at 2728 tests").
- Courtface solo-green baseline ×6 ×2 files, post-harden
  (`i29-courtface-harden.md` §Verification: topology 8 tests / 0 failures ×6,
  arm_wire 6 tests / 0 failures ×6; re-verified `i29-courtface-verify.md`
  PASS).

Every green is single-run. Across 8 gate entries no attempt produced GREEN
in both runs of the same gate.

## Residual failure family (from the logged failure sets)

Across the ledger the failures concentrate on a bounded family:

- DrScenarios scenarios 1-4 subtree-kill recovery
  (`test/azsim/dr_scenarios_test.exs:104/187/232/279`) — the recurring
  run-vs-run diff core (`tmp/court-x2-1792398603.log`,
  `tmp/court-x2-1792399039.log`, `tmp/court-x2-1792402305.log`).
- KV/store foreign-key 401 faces (`test/semantic_projection_test.exs:472`,
  `test/azsim/topology_test.exs:121/103`,
  `tmp/court-x2-1792398603.log`, `tmp/court-x2-1792399870.log`).
- Throttle `:cosmos` 429 face (`test/compliance/c3_cosmos.exs:746`,
  `tmp/court-x2-1792402305.log`).
- Identity STS-over-wire readiness (`test/azsim/topology_test.exs:82`,
  `tmp/court-x2-1792399870.log`; hardened to a bounded poll in
  `i29-courtface-harden.md` yet still surfacing as a run-2 face in later
  gates).

Classification: solo-green everywhere (courtface baseline ×6 green;
dry5 both-green; leg C green; gates re-run at release SHA exit 0,
`i29-gates-release-sha.md`) but failing under fresh-boot ordering — a
cross-plane boot-order race family, not load. `just quiet-check` cleared
before every gate attempt (driver logs `tmp/court23-run2..6-driver.log`,
e.g. "QUIET-CHECK: clear … load 5.7/5.3 < 16").

Dispatch additionally reported a gate-9 probe showing `SMALT_MAX_CASES=4`
does NOT clear the family (i.e. not pure load). **No receipt or log of that
probe was located on disk** (grep across `docs/`, `tmp/`, `scripts/` at
close time) — recorded here as dispatch-reported, citation UNLOCATED, not
as receipted evidence.

## Close condition

The race family fixed at the structural level. Scheduled as the first
v26.10.19 work order alongside WO-1 (burn-ring re-run); the gate re-runs
only after that fix lands. Until then AZB-23 stands TYPED-RED-CARRIED per
the v26.10.17 WO-2 honest-close precedent.

# FIN-13 — Composite courts section in SDK_MATRIX.md

Subject: `/Users/sac/smalt` @ main (tree `3fc2543` + in-flight v26.10.14 wave).
No commits made (DoD-only finish lane).

## Change
Added a "Composite courts" section to `docs/jira/v26.10.14/SDK_MATRIX.md`
below the main table + Findings, documenting composite (multi-surface) court
coverage that the mechanical per-surface table intentionally does not
represent:

- `test/enclave-testbed/` — 9 phases, 9 PASS; receipt
  `sdk-results/enclave-testbed.md`.
- `workspace/scripts/e2e-court.mjs` — 39 PASS / 0 FAIL; receipt
  `receipts/ws-12-e2e.md`.

## Path correction
Dispatch named `test/sdk-full/e2e-court.mjs`. No such file exists; the court
is `workspace/scripts/e2e-court.mjs` (receipts `dod-09-verify-all.md`,
`ws-12-e2e.md` confirm). Section records the grounded path and notes the
dispatch discrepancy. enclave-testbed counts re-read from
`sdk-results/enclave-testbed.md` ("FINAL: 9/9 PASS"); 39 PASS from
`ws-12-e2e.md` falsifier line ("PASS=39 FAIL=0").

## Non-changes
- Mechanical table untouched.
- `scripts/sdk_coverage.py` untouched; grounding unaffected (script parses
  only the table/KD register, not appended prose).

## Verification
- `python3 scripts/sdk_coverage.py` before AND after section: EXIT=1 both
  (pre-existing MISSING/UNREGISTERED-GAP findings; unchanged by this edit).
- Section present at bottom of SDK_MATRIX.md (re-read on disk).

## Concurrency disclosure
Between my before/after runs, the sb census line shifted
(registered_total 17+6 -> 14+3): `test/sdk-smoke/sb-extra.probe.cjs` was
modified by another lane (mtime 17:03) mid-verification. Not caused by this
edit (this lane touched only SDK_MATRIX.md prose + new receipt); exit code
remained 1 across all runs.

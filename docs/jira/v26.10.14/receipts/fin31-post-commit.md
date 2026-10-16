# fin31 — Post-Commit Gate Re-Verification

- Date: 2026-10-15
- HEAD: `518b31a54ccc0829cafb9e04538714e58c287a30` (main)
- Surface: **working tree, NOT the committed tree** — precondition unmet (see Blocker)
- Pre-commit receipt: **fin28 NOT FOUND** — no `fin28*` file exists in `docs/jira/v26.10.14/receipts/`; no pre-commit standing to diff against, so "regression from pre-commit standing" is UNVERIFIABLE on this subject.

## Blocker (precondition failure)

- `fin30-landing.md` never appeared. Polled 2026-10-15 19:20–20:30 PDT (~70 min, beyond the 60-min budget; first background poll was killed at a 10-min timeout mis-set, second ran full).
- Clean-tree poll: never clean. Final state 62 modified + 63 untracked (125 porcelain rows), quiescent — zero files under the repo modified in the trailing 90 minutes. The tree will not go clean on its own; no other lane is active.
- No `git stash` / worktree used (banned). Branching: gates run on the quiescent working tree; verdicts are labeled as such and are NOT a committed-tree verdict.

## Gate verdicts (working-tree surface, HEAD 518b31a)

| # | Gate | Verdict | Witness |
|---|---|---|---|
| 1 | `mix compile --warnings-as-errors` | PASS | exit 0, compiled clean, no warnings |
| 2 | `just doctor-dod` | PASS | 0 FAIL, 2 WARN (orphan `/tmp/smalt-substrate.lock`; 1 lane build root 342.1 MiB → `just lane-clean`) |
| 3 | `python3 scripts/sdk_coverage.py` | PASS | exit 0; cells PASS: 2, MISSING=0, UNREGISTERED-GAP=0, REGISTERED-DIVERGENCE=13, SIM-PASS=0; 52 KD rows loaded; sb census OK |
| 4 | `just gap-sync` | **FAIL** | exit 1 — `justfile.d/10-gap-register-sync.just:25` requires every KD row status `OPEN`, but 5 rows non-OPEN: KD-01, KD-03, KD-07 (CLOSED-WITH-RECEIPT s4-wire-normalization.md), KD-15 (CLOSED s3-kv-challenge.md), KD-52 (CLOSED x1-blocklist-fix.md). Gate census (all-OPEN + 2 strikethrough + 9 live GAP) is out of sync with lanes that closed divergence rows post-census-freeze. NOT mechanically fixable (register semantics, not formatting); left for a semantic lane. |
| 5 | `just sobelow` | PASS (non-blocking) | exit 0; 27 findings recorded, all low-confidence informational, triage at `docs/jira/v26.10.14/receipts/errc8-sobelow.md` |
| 6 | `bash scripts/naming_sweep.sh` | PASS | 0 violations / 52 allowed |
| 7 | `python3 scripts/gen_error_codes.py --check` | FAIL → **PASS after mechanical fix** | Was exit 1, `docs/ERROR_CODES.md` stale vs regenerated (11 diff lines, egress rows). Mechanical fix applied with disclosure: ran `python3 scripts/gen_error_codes.py` (wrote 70 rows); `--check` now exit 0. `docs/ERROR_CODES.md` is modified in the working tree, uncommitted. |

## Score

6/7 PASS. Gate 4 FAIL is a semantic drift (KD register vs gate census contract), not a compile/test failure; it contradicts gate 2 (doctor-dod gap-sync INFO passes while gap-sync fails), which is the exact drift to hand to the owning lane.

## Mechanical fixes applied (disclosed)

1. Regenerated `docs/ERROR_CODES.md` via `python3 scripts/gen_error_codes.py` (gate 7 stale-check now clean). Uncommitted.

## Falsifiers

- Committed-tree verdict remains UNKNOWN: no clean surface was reachable without banned stash/worktree. A lane that lands a clean tree should re-run all seven gates to convert this receipt's verdicts from provisional to committed-tree.
- fin28/fin30 receipts absent — if they are expected, the lanes that own them have not landed.

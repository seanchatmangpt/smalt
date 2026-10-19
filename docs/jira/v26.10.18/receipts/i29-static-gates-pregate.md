# i29 static gates pre-gate sweep — 2026-10-19

Context: solo

Subject: /Users/sac/smalt @ HEAD 2a9ccd4 (branch main). Read-only lane; no edits, no git.

Four-gate static sweep, all commands run verbatim, exits captured:

## Verdicts

| Gate | Exit | Verdict |
|---|---|---|
| `python3 gates/test_isolation_leak_gate.py` | 0 | **GREEN** |
| `just sleep-gate` | 0 | **GREEN** |
| `just naming-sweep` | 1 | **RED** |
| `python3 scripts/gen_error_codes.py --check` | 1 | **RED** |

## GREEN receipts

1. **test_isolation_leak_gate** —
   `verdict=PASS tree=GREEN offenders=0 fixtures_refused=True receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json`.
   Scanned 172 .exs files under test/ (17 allowlisted); 5 positive fixtures ran
   (2 expected PASS both PASS, 3 expected REFUSE all REFUSED — non-vacuous);
   `-- OFFENDERS: none --`.
2. **sleep-gate** — `[SLEEP-GATE] PASS — 338 files, 0 unclassified sleep primitives`, exit 0.

## RED findings (exact)

1. **naming-sweep — 2 violations, 47 allowed, exit 1**
   (`[NAMING-SWEEP] FAIL: 2 violation(s), 47 allowed`; just recipe failed on line 158, exit 1):
   - `/Users/sac/smalt/docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md:4` — Subject line carries
     a SHA (`e916d767c34e916a3444d214e5eada82af0abdbd`) that fails the sweep's pattern.
   - `/Users/sac/smalt/docs/jira/v26.10.18/burn/cgroup-20261019T061643Z.jsonl:6` — run_receipt line
     (work_order_id `AZB-18`, standing ALIVE at sha `806d86e0c29695155de7dada67dd3c74098b9c16`).
2. **gen_error_codes --check — docs/ERROR_CODES.md is stale** (exit 1).
   Drift is line-number-only: every hunk in the diff is the cited source line for
   `lib/smalt/arm_gateway/router.ex` entries shifting (e.g. `router.ex:1365` → `:1450`,
   `:1009` → `:1094`, `:3878` → `:3983`), consistent with the working-tree edit to
   `lib/smalt/arm_gateway/router.ex` (git status: modified). Fix path: run
   `python3 scripts/gen_error_codes.py` (regenerate), not hand-edit.

## Standing

PARTIAL_ALIVE — 2/4 gates green; pre-gate sweep is RED on naming-sweep + error-code drift.
Both reds are untracked/working-tree artifacts (burn jsonl + router.ex edit), not landed
regressions on HEAD itself; the court owner must regenerate ERROR_CODES.md and disposition
the two naming-sweep violations before `just court` will pass its static tier.

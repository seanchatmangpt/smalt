# i29 budget gate verification (NOT re-seed verification)

Date: 2026-10-18 22:31 PDT
Context: solo(/Users/sac/smalt)

## Premise check

- `docs/jira/v26.10.18/receipts/i29-budget-reseed.md`: ABSENT (re-seed not landed).
- `docs/jira/v26.10.18/test_budgets.json` mtime: Oct 18 15:17:17 2026 (older than
  2026-10-18 22:00 PST cutoff) — not freshly re-seeded this window.

## Command + output

```
python3 scripts/test_budget_gate.py --export tmp/test-budget-export.tsv
== Test Budget Gate == (2736 tests)
UNMANIFESTED: 772
STALE:        61
REGRESSION:   0
Gate: FAIL (exit 1)
```

Export: `tmp/test-budget-export.tsv` (2736 rows).

## Verdict

Gate FAIL. Re-seed lane NOT landed — the 772 unmanifested + 61 stale counts are the
pre-re-seed state. Marking [IN-FLIGHT]: the re-seed lane is presumably still running
(absence of receipt + old manifest mtime); I did not re-seed and did not touch
`test_budgets.json` or the re-seed receipt.

Standing: PASS (verification executed as specified, results reported honestly).

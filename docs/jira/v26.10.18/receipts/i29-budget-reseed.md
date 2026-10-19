# i29 budget reseed adoption (orphan manifest ADOPTED)

Date: 2026-10-19 00:25 PDT
Context: solo(/Users/sac/smalt)

## Premise

- Active-vs-orphan: `docs/jira/v26.10.18/test_budgets.json` mtime was
  `Oct 19 00:11:34 2026` at t0 and identical at +9 min (STABLE; no lane
  actively writing).
- Receipt `docs/jira/v26.10.18/receipts/i29-budget-reseed.md`: ABSENT before
  this receipt (reseed landed unreceipted). Prior verify
  (`i29-budget-verify.md`, Oct 18 22:31) had correctly marked the lane
  [IN-FLIGHT] against the pre-reseed state (772 UNMANIFESTED / 61 STALE,
  gate FAIL, manifest mtime Oct 18 15:17).
- Verdict: STABLE + no receipt -> ADOPT.

## Coverage verification (per the recipe)

```
export SMALT_BUDGET_EXPORT=tmp/test-budget-export.adopt2.97842.tsv
mixrc=0; mix test --formatter SmaltTest.BudgetFormatter || mixrc=$?
python3 scripts/test_budget_gate.py --export "$SMALT_BUDGET_EXPORT"
== budget export written: tmp/test-budget-export.adopt2.97842.tsv
PASS budget-gate/fixture:breach (refused)
PASS budget-gate/fixture:unmanifested (refused)
== Test Budget Gate == (2748 tests)
Gate: PASS
gate=0
```

Final counts: 2748 tests, 0 UNMANIFESTED, 0 STALE, 0 REGRESSION, gate exit 0.
Both non-vacuity fixtures refused (gate not vacuous). Manifest covers the
current suite — no further reseed required.

## Notes

- `mix=2` on the formatter run is the documented pre-existing condition
  (see `i29-budget-export-fix.md` lines 53+): zero test failures; the export-only formatter suppresses the
  ExUnit console summary and mix exits 2. Recipe `|| rc=$?` guards it;
  the gate's exit (0) is the verdict.
- Compile-freeze disclosure: attempt 1 hit a transient syntax error in
  `lib/smalt/data_plane/queue_storage.ex:206` (unclosed `{:ok, nil`,
  untracked in-flight file from another lane). The owning lane fixed it
  before any edit of mine; attempt 2 compiled clean. I applied no fix.

## Verdict

Manifest ADOPTED. Standing: **PASS** — budget gate green on a full fresh
export (2748/0/0), fixtures refuse, mtime stable, receipt now exists.

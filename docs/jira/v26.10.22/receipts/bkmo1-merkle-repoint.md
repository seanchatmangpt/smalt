# BK-MO1 — COURT-MERKLE-O1 citation re-point (BK-PRDA F1)

**Standing:** ALIVE — both cells re-pointed, receipts verified on disk, gates exit 0.
**Context:** solo

## Change

Closes BK-PRDA finding F1 (`receipts/bkprda-matrix-audit2.md`): the COURT-MERKLE-O1
cells in PRD §4 and VALIDATION.md cited `../v26.10.21/receipts/pb4-merkle-dual-path.md`,
whose standing line is REFUTED-as-noise (the O(n) sort-variant bench). Re-pointed both
cells to the receipts that actually support the O(1) receipt-size claims:

- `receipts/pb4r-identity-court.md` (ALIVE)
- `receipts/bkrsize-receipt-truth.md` (ALIVE)

PARTIAL_ALIVE standing retained — the named standalone merkle court is still pending;
both cell texts say so explicitly. Re-point notes the origin citation and its
REFUTED-as-noise standing for traceability.

## Before

PRD.md:77 / VALIDATION.md:58:

```
| COURT-MERKLE-O1 | NFR-EVI-001 | PARTIAL_ALIVE — pb4 evidence exists, [named standalone] court pending | `../v26.10.21/receipts/pb4-merkle-dual-path.md` |
```

## After

```
| COURT-MERKLE-O1 | NFR-EVI-001 | PARTIAL_ALIVE — pb4 O(1) evidence exists, [named standalone] court pending | `receipts/pb4r-identity-court.md` + `receipts/bkrsize-receipt-truth.md` (re-pointed from `../v26.10.21/receipts/pb4-merkle-dual-path.md`, REFUTED-as-noise; BK-PRDA F1) |
```

## Verification

- Re-pointed receipts exist on disk; standing lines re-read at use time:
  - `pb4r-identity-court.md`: `**Standing:** **ALIVE** — PB-4 harness exits 0, ground-truth court passes, 16 real rows`
  - `bkrsize-receipt-truth.md`: `**Standing**: ALIVE`
- `just docs-dod-check` → OK (exit 0)
- receipt index → exit 0

## Files

- `docs/jira/v26.10.22/PRD.md` (COURT-MERKLE-O1 cell)
- `docs/jira/v26.10.22/VALIDATION.md` (COURT-MERKLE-O1 row)
- `docs/jira/v26.10.22/receipts/bkmo1-merkle-repoint.md` (this receipt)

# Module 05 Court

**Verdict command** (exit 0 = PASS, exit 1 = FAIL), from the curriculum root
`/Users/sac/smalt/docs/dmedi-bb-curriculum`:

```bash
python3 modules/05-qfd/data/court.py
```

## What the court checks (fail-closed)
1. **Weights re-derive**: CPPC points100 recomputed from ranks by largest-remainder
   (exact `Fraction`) = {18, 20, 9, 16, 13, 11, 7, 4, 2}, sum exactly 100; ranks
   must equal Module 04 `compute.py`'s ranks dict (cross-module pin).
2. **Matrix arithmetic**: row sums per CR; weighted column totals (EC1 241,
   EC2 209, EC3 180, EC4 157, EC5 173, EC6 78); conservation identity
   Σrows = Σcols = 1038; cell vocabulary restricted to {1, 3, 9}.
3. **Roof census**: 15/15 pairs (C(6,2)), vocabulary {++, +, 0, −, −−}, EC5
   conflict count = 4.
4. **Spine targets**: EC4 18.4 → ≤7; EC5 41.80 → ≤28.50; EC1 baseline names the
   pinned Cpk 0.72 (flag carried, never silently inherited).
5. **Cpk math**: 0.008/(3×0.0020) = 1.33; Z vs customer spec = 12.5σ.
6. **Secondary claims QFD**: direct-rating weights re-derived = {22, 20, 7, 15,
   13, 23}, sum 100; row sums, column totals (T1 250, T2 259, T3 147, T4 204,
   T5 138, T6 267), conservation Σ = 1265; roof 15/15.
7. **Upstream module**: re-runs the Module 04 court (`compute.py`) and requires
   exit 0 — the Kano→QFD chain is one court, not two.

## Non-vacuity (mutation probes, each exits 1)
- Change any matrix cell → column totals AND conservation fail.
- Change a rank in `qfd-cppc-weights.csv` → allocation check fails.
- Delete a roof row → pair-count check fails.
- Change EC4 target to "<= 8" → spine-target check fails.
- Change K-10's expected Kano class upstream → Module 04 court inside this
  court fails (K ids are Module 04's Kano-attribute namespace; spine CTQ ids are
  RUNNING-CASE.md's and are never reused for Kano attributes).

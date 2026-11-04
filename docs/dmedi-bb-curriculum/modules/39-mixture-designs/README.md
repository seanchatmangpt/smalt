# Module 39 — Mixture Designs: Simplex Geometry for the Coolant Concentrate

## Module overview

**DMEDI phase:** Develop
**Running case:** CPPC coolant concentrate — tool life (min) as a function of
the oil / emulsifier / water blend. Unlike factorial factors, mixture
components are constrained to sum to 1, so the design space is a simplex and
the model uses Scheffé polynomials.
**Prerequisites:** Module 37 (curvature/interaction thinking), Module 29 (DOE
terminology).

**Dataset:** `data/coolant-mixture.csv` — {3,2} simplex lattice (6 points) +
overall centroid, 2 reps each (14 rows), synthetic (python3 `random`,
**seed 39001**). Regenerate and re-derive with:

```
python3 modules/39-mixture-designs/data/compute.py   # exit 0
```

The script regenerates the CSV byte-identically, then re-derives every
solution-key number from the CSV on disk.

## Session structure

- `slides-outline.md` — "Module 39 — Mixture Designs: Simplex Geometry for
  the Coolant Concentrate".
- `exercises.md` — 3 exercises, 30 min: Scheffé quadratic coefficients from
  lattice identities (b_ij = 4·(y_ij − (b_i + b_j)/2)), synergy vs antagonism
  in plain language (oil+emulsifier synergistic, oil+water antagonistic),
  why vertex points are not the optimum (grid search lands at oil 0.70 /
  emulsifier 0.30 / water 0.00 → 14.45 min).
- `keys/solution-key.md` — full captured `compute.py` output; every number
  re-derives, zero copied.
- `courts/court.py` — exit 0 = court PASS (0 failures); run from the
  curriculum root after any edit to this module.

## Files

- `data/coolant-mixture.csv` — registered in `datasets/MANIFEST.md`
- `data/compute.py` — seeded generator + re-derivation (seed 39001)
- `lab.md` — stepwise lab procedure (compute.py invocations, court-pinned
  checkpoints, receipt format)
- `exercises.md` / `keys/solution-key.md` / `courts/court.py`
- `slides-outline.md`

## See also

Module 30/37 (factorial and curvature designs — the unconstrained-space
counterparts), Module 33 (lean context for consumable cost), RUNNING-CASE.md.

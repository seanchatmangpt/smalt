# Module 37 — DOE: Curvature Detection and the Axial Path

## Module overview

**DMEDI phase:** Develop
**Running case:** CPPC bore deviation (um) — the 2^3 factorial of Module 30 is
re-examined for curvature via center points, then improved by steepest-descent
(axial) steps — deviation from the 12.000 mm target, smaller is better.
**Prerequisites:** Module 30 (2^3 factorial), Module 29 (DOE terminology).

**Dataset:** `data/bore-curvature.csv` — 16 factorial runs + 6 center points,
synthetic (python3 `random`, **seed 37001**). Regenerate and re-derive with:

```
python3 modules/37-doe-curvature/data/compute.py   # exit 0
```

The script regenerates the CSV byte-identically, then re-derives every
solution-key number from the CSV on disk.

## Session structure

- `slides-outline.md` — "Module 37 — DOE: Curvature Detection and the Axial
  Path" (module identity, curvature test mechanics, axial-path theory).
- `exercises.md` — 3 exercises, 30 min: curvature verdict by hand (pooled SD,
  t = 4.223 vs t_crit 2.131 → curvature present), axial unit step
  (|g| = 2.516), why center points carry no planar leverage.
- `keys/solution-key.md` — full captured `compute.py` output; every number
  re-derives, zero copied.
- `courts/court.py` — exit 0 = court PASS (0 failures); run from the
  curriculum root after any edit to this module.

## Files

- `data/bore-curvature.csv` — registered in `datasets/MANIFEST.md`
- `data/compute.py` — seeded generator + re-derivation (seed 37001)
- `lab.md` — stepwise lab procedure (compute.py invocations, court-pinned
  checkpoints, receipt format)
- `exercises.md` / `keys/solution-key.md` / `courts/court.py`
- `slides-outline.md`

## See also

Module 30 (factorial effects, SE/t classification), Module 31 (fractional
factorial), Module 41 (sequential RSM — where the axial path leads),
RUNNING-CASE.md (pinned factors/responses).

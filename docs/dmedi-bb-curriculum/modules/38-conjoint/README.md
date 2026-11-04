# Module 38 — Conjoint Analysis: Card Design, Part-Worths, Importance

## Module overview

**DMEDI phase:** Develop
**Running case:** CPPC gimbal concept trade-offs — respondents rank profiles
across price / lead time / tolerance / finish; the analysis recovers
part-worth utilities and importance shares without asking for them directly.
**Prerequisites:** Module 37 (curvature / response surface thinking), Module
16 (concept selection — the decision context conjoint feeds).

**Dataset:** `data/conjoint-cards.csv` + `data/conjoint-ranks.csv` — an
authored L9 card design (9 profiles, no RNG in the design itself) and one
respondent's rank ordering of the 9 cards (gauss(0, 0.55) noise on true
utility, **seed 38001**). Regenerate and re-derive with:

```
python3 modules/38-conjoint/data/compute.py   # exit 0
```

The script regenerates both CSVs byte-identically, then re-derives every
solution-key number from the CSVs on disk.

## Session structure

- `slides-outline.md` — "Module 38 — Conjoint Analysis: Card Design,
  Part-Worths, Importance".
- `exercises.md` — 3 exercises, 30 min: importance shares from the part-worth
  ranges (price 55.2%, lead 31.0%, tol 6.9%, finish 6.9%, sum 100%), predicted
  best profile scoring, and why tolerance looks unimportant in ranks while
  Module 37 shows bore deviation is highly parameter-sensitive.
- `keys/solution-key.md` — full captured `compute.py` output; every number
  re-derives, zero copied.
- `courts/court.py` — exit 0 = court PASS (0 failures); run from the
  curriculum root after any edit to this module.

## Files

- `data/conjoint-cards.csv`, `data/conjoint-ranks.csv` — registered in
  `datasets/MANIFEST.md`
- `data/compute.py` — seeded generator + re-derivation (seed 38001)
- `lab.md` — stepwise lab procedure (compute.py invocations, court-pinned
  checkpoints, receipt format)
- `exercises.md` / `keys/solution-key.md` / `courts/court.py`
- `slides-outline.md`

## See also

Module 16 (Pugh/AHP — the selection machinery these weights feed), Module 37
(what the process parameters actually move), RUNNING-CASE.md.

# Module 41 — Signature Lab: Paper-Helicopter Sequential RSM

## Module overview

**DMEDI phase:** Develop
**Running case:** CPPC-adjacent signature lab — candidates optimize a paper
helicopter's descent time through a full sequential RSM: resolution-IV screen
→ steepest-ascent path → central composite design (CCD) → confirmation run.
**Prerequisites:** Module 37 (curvature), Module 40 (S/N thinking — optional),
Module 30 (screening effects).

**IMPORTANT — the lab procedure is `lab.md`** (16-run 2^(7-3) resolution-IV
screen → steepest ascent → rotatable CCD alpha = 2 → canonical stationary
point → physical confirmation, with run budget 16 + 4 + 19 + 1 = 40 runs).
This module is a lab-first module. Candidates who fly real helicopters
compare structure, not numbers — the `compute.py` simulation is the reference
result, not the lab itself. The 30-minute exercise sequence in
`exercises.md` drills the lab's accounting.

**Dataset:** `data/helicopter-rsm.csv` — simulated sequential RSM (python3
`random`, **seed 41001**, plus seed+1 for the confirmation stage). Regenerate
and re-derive with:

```
python3 modules/41-helicopter-rsm-lab/data/compute.py   # exit 0
```

## Session structure

- `slides-outline.md` — "Module 41 — Signature Lab: Paper-Helicopter
  Sequential RSM".
- `exercises.md` — the RSM lab procedure (see the IMPORTANT note above).
- `keys/solution-key.md` — full captured `compute.py` output; every number
  re-derives, zero copied.
- `courts/court.py` — exit 0 = court PASS (0 failures); run from the
  curriculum root after any edit to this module.

## Files

- `data/helicopter-rsm.csv` — registered in `datasets/MANIFEST.md`
- `data/compute.py` — seeded generator + re-derivation (seed 41001)
- `lab.md` — stepwise lab procedure (compute.py invocations, court-pinned
  checkpoints, receipt format)
- `exercises.md` / `keys/solution-key.md` / `courts/court.py`
- `slides-outline.md`

## See also

Module 37 (curvature — the CCD's reason to exist), Module 40 (robust design),
Module 42 (prototype/pilot — the next phase), RUNNING-CASE.md.

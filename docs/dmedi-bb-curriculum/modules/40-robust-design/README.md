# Module 40 — Robust Design (Taguchi): Control x Noise, Inner/Outer Arrays, S/N

## Module overview

**DMEDI phase:** Develop
**Running case:** CPPC bore — control factors (speed, feed, coating) crossed
with a noise condition in an inner/outer array; the response is analyzed as
signal-to-noise ratios, not raw means, so the chosen setup is one that barely
moves when the noise moves.
**Prerequisites:** Module 37 (curvature), Module 30 (factorial effects).

**Dataset:** `data/robust-bore.csv` — 8-run inner array x outer noise
repetitions, synthetic (python3 `random`, **seed 40001**). Regenerate and
re-derive with:

```
python3 modules/40-robust-design/data/compute.py   # exit 0
```

The script regenerates the CSV byte-identically, then re-derives every
solution-key number from the CSV on disk.

## Session structure

- `slides-outline.md` — "Module 40 — Robust Design (Taguchi): Control x
  Noise, Inner/Outer Arrays, S/N".
- `exercises.md` — 3 exercises, 30 min: coating S/N_STB effect by hand
  (+4.25 dB, the largest control-factor effect), best setup and what it buys
  (run 6: V9000/F220/coated, S/N −10.26 dB, SD 0.49 um), and why the
  control x noise interaction (coating x hardness: +0.84 um uncoated lift,
  −0.41 um coated) is the robustness mechanism a plain factorial misses.
- `keys/solution-key.md` — full captured `compute.py` output; every number
  re-derives, zero copied.
- `courts/court.py` — exit 0 = court PASS (0 failures); run from the
  curriculum root after any edit to this module.

## Files

- `data/robust-bore.csv` — registered in `datasets/MANIFEST.md`
- `data/compute.py` — seeded generator + re-derivation (seed 40001)
- `lab.md` — stepwise lab procedure (compute.py invocations, court-pinned
  checkpoints, receipt format)
- `exercises.md` / `keys/solution-key.md` / `courts/court.py`
- `slides-outline.md`

## See also

Module 37 (where the within-corner pure-error SD 1.886 um comes from),
Module 41 (the signature lab that sequences screen → ascent → CCD),
RUNNING-CASE.md (pinned factors).

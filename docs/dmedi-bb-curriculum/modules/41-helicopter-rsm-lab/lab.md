# Module 41 Lab — Helicopter Sequential RSM (Signature Lab)

**Objective**: execute the full sequential Response Surface Methodology loop on the paper
helicopter — 16-run resolution-IV screening → steepest ascent → rotatable CCD (alpha = 2) →
canonical stationary point → physical confirmation — and account for every run and every
decibel of improvement.

**Dataset**: `data/helicopter-rsm.csv`, seed 41001 (hardcoded in `data/compute.py`; the
script regenerates the CSV byte-identically — `datasets/manifest_verify.py` confirms the
registered sha256 after the rerun).

**Replay incantation** (from the curriculum root):

```bash
python3 modules/41-helicopter-rsm-lab/data/compute.py; echo RC=$?    # RC=0
python3 modules/41-helicopter-rsm-lab/courts/court.py; echo RC=$?    # RC=0, 42/42 checks
```

**Time: ~40 min** (Lab 1: 10 min, Lab 2: 8 min, Lab 3: 12 min, Lab 4: 10 min).

## Lab 1 — Stage 1: screening (16-run 2^(7−3) res IV) (10 min)

OLS on the 16 corner runs (y = median descent time, s). **Checkpoint (court-pinned,
contrast route)**: intercept = **3.001 s**; effects (2× coef): wing_len **+1.811**,
wing_wid +0.991, tail_len −0.601 (the 3 ACTIVE, |effect| > 0.15); tail_wid +0.149,
body_hgt −0.099, clips +0.054, fold_hgt −0.059 (inactive).

## Lab 2 — Stage 2: steepest ascent (half-unit steps on A, B, C; D–G held 0) (8 min)

**Checkpoint path**:

| step | A | B | C | median |
|---|---|---|---|---|
| 1 | +0.42 | +0.23 | −0.44 | 4.69 s |
| 2 | +0.84 | +0.46 | −0.58 | 4.93 s |
| 3 | +1.26 | +0.69 | −0.72 | **4.93 s** (peak — CCD centered here) |
| 4 | +1.68 | +0.92 | −0.86 | 4.71 s (curvature: step 3→4 LOST 0.22 s) |

## Lab 3 — Stage 3: rotatable CCD (alpha = 2) and canonical optimum (12 min)

19 runs in A, B, C (8 factorial + 6 axial + 5 center). **Checkpoint (court-pinned quadratic
fit, ±0.005)**:

```
T = 4.184 +0.913A +0.506B -0.273C +0.134AB -0.009AC +0.046BC -0.453A² -0.538B² -0.195C²
residual SD = 0.029 s on 9 df
```

Solving ∇T = 0: **stationary point (A, B, C) = (+1.100, +0.579, −0.655) coded,
predicted T = 4.922 s**; natural values A = 133.0 mm (range 70–130 — 3 mm OUTSIDE the tested
region, an extrapolated claim: report it honestly or fall back to the in-range ascent
plateau ~4.93 s), B = 48.7 mm, C = 46.9 mm (both in range).

## Lab 4 — Confirmation and the accounting court (10 min)

- Confirmation drops at the optimum: [4.94, 4.98, 4.95] → median **4.95 s** vs predicted
  4.922 s → model error **0.028 s**, at the fit's residual SD 0.029 s (noise level — model
  adequate at the optimum).
- Improvement: screening grand mean 3.00 s → confirmation median 4.95 s = **+1.95 s**.
- Run budget: screen 16 + ascent 4 + CCD 19 + confirmation 1 = **40 runs**
  (40% screening, 47.5% refinement — sequential refinement spends runs where information is).
- Additive-share caution: wing_len's screening effect 0.906/1.95 = 46.5% of the improvement
  if effects were additive — but −0.453A² means wing length saturates, exactly the curvature
  the linear ascent cannot predict.

## Tool note

Stdlib-only (`csv`, `math`, `statistics`); no Minitab/R required. The court re-derives
screening effects by the contrast route, refits the CCD independently, and solves the
stationary point itself. `--mutate` must exit 1 (MUTATION DETECTED on the pinned grand
mean 3.001); a corrupt constant that still passes exits 2 as VACUOUS COURT.

## Receipt format

```
subject: modules/41-helicopter-rsm-lab lab
identity: sha256 of answers + court exit code
replay:   python3 modules/41-helicopter-rsm-lab/data/compute.py && python3 modules/41-helicopter-rsm-lab/courts/court.py
```

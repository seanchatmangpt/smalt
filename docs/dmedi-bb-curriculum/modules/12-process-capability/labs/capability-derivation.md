# Lab — Deriving Cp/Cpk/Pp/Ppk from raw measurements (bore baseline)

Dataset: `data/cpk072-bore-subgroups.csv` — 25 subgroups × 4 measurements,
rational subgroups (4 consecutive parts each hour). Spec 11.975 / 12.025 mm.
Seed 512. Key: `python3 modules/12-process-capability/keys/capability_key.py`
(exit 0 = all courts pass, including the spine Cpk = 0.72 court).

## Step 1 — stability precondition (control chart first)

X̄-R chart on the 25 subgroups (A₂ = 0.729, D₄ = 2.282, d₂ = 2.059 for n = 4):

| chart | center line | limits |
|---|---|---|
| X̄ | 12.0090 | UCL 12.0201 / LCL 11.9979 |
| R | 0.01525 | UCL 0.0348 / LCL 0 |

Zero out-of-control points on either chart → process is stable → capability
indices are *lawful to interpret*. (Contrast: `data/xbar-r-subgroups.csv`
(module 10) has a PLANTED special cause at subgroups 18-20 — seed 42011,
+0.015 mm mean shift — which surfaces as subgroups 19-20 above the X̄ UCL.
Capability is computed on the in-control prefix per the stability-precondition
law, and the planted shift is the contrast case: an index computed on THAT
chart before the special cause is removed would be fiction.)

## Step 2 — two sigmas

- σ_within = R̄/d₂ = 0.01525/2.059 = **0.007407 mm**
- σ_overall = sample s of all 100 values = **0.006331 mm**

(σ_overall < σ_within here because between-subgroup drift over the 25-hour
window is small relative to within-subgroup spread in this baseline window —
Ppk > Cpk is the visible consequence; the usual industrial case is the
reverse, and the teaching point is that *which sigma you use changes the
index*, not which is "correct".)

## Step 3 — the four indices

| index | computation | value |
|---|---|---|
| Cp | 0.050/(6 × 0.007407) | **1.12** |
| Cpk | min(USL−μ̄, μ̄−LSL)/(3 × 0.007407), μ̄ = 12.0090 | **0.72** ✓ spine |
| Pp | 0.050/(6 × 0.006331) | **1.32** |
| Ppk | min(USL−μ̄, μ̄−LSL)/(3 × 0.006331) | **0.84** |

Spine decomposition: μ̄ − LSL = 0.034 (not binding); USL − μ̄ = 0.016 (binding).
Cpk = 0.016/(3 × 0.007407) = 0.7200.

## Step 4 — expected performance

Z.USL = (12.025 − 12.009)/0.007407 = 2.16 → est 15,398 PPM above USL
(within, normal theory). Observed: 0/100 above USL in this window — small-n
cannot see a 1.5% tail; that reconciliation gap is itself the lesson.

## Step 5 — verdict

Baseline Cpk 0.72 ≪ 1.33 (Define gate target). Two levers, sized by the
indices: (1) **center the mean** (9 um above the 12.000 target): buys Cp = 1.12
with no variation work; (2) remaining gap 1.12 → 1.33 requires σ_within
≤ 0.016/3.99 = 4.01 um — a 46% variation reduction, which is the Analyze/DOE
work (modules 28–30). The MSA verdict (13.97% %GRR) does not block measuring
this improvement.

## Spine coherence note

The ORIGINAL spine sigma 4.17 um contradicted the pinned Cpk 0.72 (gave 1.28);
ADJUDICATED stale 2026-11-04. Lane 04's raw baseline re-derives Ppk 1.24 overall.
This dataset keeps mu = 12.009 and reproduces Cpk = 0.72 exactly at sigma =
7.407 um. The MANIFEST row records the adjudication; the spine court in `capability_key.py` enforces
|Cpk − 0.72| ≤ 0.005 on every re-run.

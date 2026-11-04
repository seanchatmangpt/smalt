# Module 41 Exercises — Helicopter Sequential RSM

Replay source: `python3 data/compute.py` (exit 0) — simulates the lab (seed 41001) and
re-derives every printed number; candidates fly real helicopters and compare structure, not
numbers.

**Time: 30 min** (Ex 1: 10 min, Ex 2: 10 min, Ex 3: 10 min).

## Exercise 1 — Screening effect for wing length (10 min)

The stage-1 16-run resolution-IV screen reports effect(wing_len) = +0.906 s (ACTIVE), with
intercept 3.001 s. Explain in one sentence why a positive effect on descent time is a
DESIGN opportunity here (we want long descent times), and compute how much of the total
confirmation improvement (+1.95 s) this single factor explains if effects were additive.

### Key (derivation shown)

Longer descent time = more airtime = better; a positive screening effect means raising
wing_len raises descent time, so wing_len is pushed to its HIGH level in stage 2 — the
ascent path sets A = +1.26 … +1.68 (all positive steps on A).
Additive share: 0.906 / 1.95 = **46.5%** — but the true share is not additive: the CCD
quadratic shows −0.453·A², so wing length saturates (steps 3→4 lost 0.22 s), which is
exactly the curvature the axial path's linear extrapolation cannot predict.

## Exercise 2 — Improvement accounting and run budget (10 min)

(a) Confirm the improvement accounting: screening grand mean 3.00 s → confirmation median
4.95 s = +1.95 s.
(b) Confirm the run budget: screen 16 + ascent 4 + CCD 19 + confirmation 1 = 40 runs.

### Key (derivation shown)

(a) 4.95 − 3.00 = **+1.95 s** (matches the key).
(b) 16 + 4 + 19 + 1 = **40** (matches the key). Python check:
`4.95-3.00` → 1.95; `16+4+19+1` → 40 (exit 0).
Interpretation: 40% of the budget (16/40) went to screening 7 factors, 47.5% (19/40) to the
19-run CCD in only the 3 active factors — sequential refinement spends runs where information
is, not uniformly.

## Exercise 3 — From coded to natural optimum (10 min)

The CCD stationary point is (A, B, C) = (+1.100, +0.579, −0.655) coded, with natural values
A = 133.0 mm (range 70–130), B = 48.7 mm (25–55), C = 46.9 mm (40–80).

(a) The natural A of 133.0 mm lies OUTSIDE the screening range (70–130 mm). State what this
means operationally and what the lab's honest options are.
(b) The confirmation drops at the optimum gave [4.94, 4.98, 4.95] → median 4.95 s vs the
model's predicted 4.922 s. Compute the model error at the optimum.

### Key (derivation shown)

(a) The stationary point extrapolates 3 mm beyond the tested wing-length range, so the
"optimum" is an extrapolated claim, not observed territory. Honest options: extend the range
(fly longer wings in a follow-up confirmation) or restrict the recommendation to the tested
region and report the in-range best (the ascent plateau, ~4.93 s at step 3). What is NOT
honest: reporting 4.922 s as an observed optimum.
(b) Error = |4.95 − 4.922| = **0.028 s**, consistent with the fit's residual SD 0.029 s on
9 df — the prediction is at noise level, so the model is adequate at the optimum.

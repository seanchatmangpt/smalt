# Module 41 Solution Key — Helicopter sequential RSM, seed 41001 (all numbers re-derived)

Command incantation (run from the curriculum root):

```
python3 modules/41-helicopter-rsm-lab/data/compute.py; echo RC=$?   # RC=0
```

The incantation regenerates `data/helicopter-rsm.csv` from seed 41001 (byte-identical —
`datasets/manifest_verify.py` confirms the registered sha256 after the rerun), then
re-derives every printed number from disk. Full captured output of that run:

```
== Module 41 solution key: helicopter sequential RSM ==

-- stage 1: screening effects (16-run res IV, y = median descent s) --
  intercept 3.001
  wing_len   coef +0.906 s (effect = +1.811)  <== ACTIVE
  wing_wid   coef +0.496 s (effect = +0.991)  <== ACTIVE
  tail_len   coef -0.301 s (effect = -0.601)  <== ACTIVE
  tail_wid   coef +0.074 s (effect = +0.149)
  body_hgt   coef -0.049 s (effect = -0.099)
  clips      coef +0.027 s (effect = +0.054)
  fold_hgt   coef -0.029 s (effect = -0.059)
active set: ['wing_len', 'wing_wid', 'tail_len']

-- stage 2: steepest ascent (half-unit steps on A,B,C; D-G held 0) --
  step1  A=+0.42 B=+0.23 C=-0.44   median = 4.69 s
  step2  A=+0.84 B=+0.46 C=-0.58   median = 4.93 s
  step3  A=+1.26 B=+0.69 C=-0.72   median = 4.93 s
  step4  A=+1.68 B=+0.92 C=-0.86   median = 4.71 s
  -> improvement stops after step3 (4.93 s peak); CCD centered there

-- stage 3: rotatable CCD (alpha=2) in A,B,C: 8 factorial + 6 axial + 5 center runs --
quadratic fit (coded):
  T = 4.184 +0.913A +0.506B -0.273C +0.134AB -0.009AC +0.046BC -0.453A^2 -0.538B^2 -0.195C^2
  residual SD = 0.029 s on 9 df

-- optimum search (canonical: grad = 0) --
  stationary point (coded): A +1.100, B +0.579, C -0.655
  predicted descent time at optimum: 4.922 s
  A wing length mm     natural = 133.0 (range 70-130)
  B wing width mm      natural = 48.7 (range 25-55)
  C tail length mm     natural = 46.9 (range 40-80)

confirmation at optimum: drops [4.94, 4.98, 4.95] -> median 4.95 s (true surface 4.942 s)
screening grand mean (16 corner runs): 3.00 s -> confirmation median 4.95 s  = +1.95 s improvement
total runs consumed: screen 16 + ascent 4 + CCD 19 + confirmation = 40
RC=0
```

## E1 — Wing-length screening effect

Stage-1 OLS coefficients from the 16-run 2^(7−3) res-IV screen (y = median descent s):

| factor | coef | effect (2×coef) | ACTIVE (>0.15) |
|---|---|---|---|
| wing_len | +0.906 | +1.811 | yes |
| wing_wid | +0.496 | +0.991 | yes |
| tail_len | −0.301 | −0.601 | yes |
| tail_wid | +0.074 | +0.149 | no |
| body_hgt | −0.049 | −0.099 | no |
| clips | +0.027 | +0.054 | no |
| fold_hgt | −0.029 | −0.059 | no |

Intercept (grand mean) = **3.001 s**, matching the court pin 3.001 (contrast-derived 3.0006,
tolerance 0.01). Answer: a positive effect on descent time is a design opportunity — longer
descent = more airtime = better — so wing_len is pushed HIGH in stage 2 (the ascent path sets
A = +0.42 → +1.68, all positive steps on A). Additive share of the total +1.95 s improvement:
0.906 / 1.95 = **46.5%** — but the share is not additive: the CCD quadratic carries
−0.453·A², so wing length saturates (ascent steps 3→4 lost 0.22 s), exactly the curvature
the steepest-ascent linear extrapolation cannot predict.

## E2 — Improvement accounting and run budget

| quantity | value | court pin |
|---|---|---|
| screening grand mean | 3.00 s (16 corner runs) | 3.001 ± 0.01 |
| confirmation median at optimum | 4.95 s (drops 4.94/4.98/4.95) | "4.95 s" cited in outline |
| improvement | **+1.95 s** | "+1.95 s" cited in outline |
| run budget | screen 16 + ascent 4 + CCD 19 + confirmation 1 = **40** | "16 + ascent 4 + CCD 19" cited in outline |

Interpretation: 40% of the budget (16/40) screened 7 factors; 47.5% (19/40) refined only the
3 active ones in the CCD — sequential refinement spends runs where the information is.

## E3 — From coded to natural optimum

CCD quadratic fit (10 coefficients, court-pinned to ±0.005):

| term | coef | term | coef |
|---|---|---|---|
| b0 | 4.184 | bAB | +0.134 |
| bA | +0.913 | bAC | −0.009 |
| bB | +0.506 | bBC | +0.046 |
| bC | −0.273 | bAA | −0.453 |
| — | — | bBB | −0.538 |
| — | — | bCC | −0.195 |

Stationary point (solving ∇T = 0, court-pinned): (A, B, C) = (**+1.100, +0.579, −0.655**)
coded; predicted T at optimum **4.922 s**.

| factor | coded | natural | tested range | in range? |
|---|---|---|---|---|
| A wing length | +1.100 | **133.0 mm** | 70–130 | NO (+3.0 mm outside) |
| B wing width | +0.579 | 48.7 mm | 25–55 | yes |
| C tail length | −0.655 | 46.9 mm | 40–80 | yes |

(a) The natural A of 133.0 mm extrapolates 3 mm beyond the tested wing-length range, so the
"optimum" is an extrapolated claim, not observed territory. Honest options: extend the range
(fly longer wings in a follow-up confirmation) or restrict the recommendation to the tested
region and report the in-range best (the ascent plateau, ~4.93 s at step 3). What is NOT
honest: reporting 4.922 s as an observed optimum.

(b) Confirmation drops [4.94, 4.98, 4.95] → median 4.95 s vs predicted 4.922 s: error =
|4.95 − 4.922| = **0.028 s**, consistent with the fit's residual SD 0.029 s on 9 df — the
prediction is at noise level, so the model is adequate at the optimum. (The true surface at
the optimum is 4.942 s; the −0.020 s gap to the 4.95 s observed median is measurement noise
σ = 0.06 s per drop, median-of-3 shrinks it.)

---

Court receipt (run after authoring, from the curriculum root):

- `python3 modules/41-helicopter-rsm-lab/courts/court.py` → **exit 0**, 42/42 PASS
  ("MODULE 41 COURT: PASS (0 failures)") — every number above re-derives independently
  (contrast-route screening effects, independent CCD refit, stationary-point solve, outline
  citation pins).
- `python3 modules/41-helicopter-rsm-lab/courts/court.py --mutate` → **exit 1**
  ("MUTATION DETECTED: pinned grand mean 3.001 vs corrupted 3.1010") — the court is
  non-vacuous: corrupting a pinned constant flips it. (The `--mutate` mode was missing from
  this court — every other pinned-constant court in the course has it; added in this lane.)
- `python3 datasets/manifest_verify.py` → **exit 0** — `modules/41-helicopter-rsm-lab/data/helicopter-rsm.csv`
  matches its registered sha256 after the key's incantation reran the generator.

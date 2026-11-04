# Module 37 Solution Key — Center-Point Curvature Test, seed 37001 (all numbers re-derived)

Command incantation (run from the curriculum root; seed 37001 is stated inside
`data/compute.py` — the script regenerates `data/bore-curvature.csv`
byte-identically before re-deriving every printed number from the CSV on disk):

```
python3 modules/37-doe-curvature/data/compute.py; echo RC=$?   # RC=0
```

Full captured output of that run (every number below re-derives from this
output, zero copied):

```
== Module 37 solution key: center-point curvature test ==
factorial points: 8 corners x 2 reps = 16 obs
center points: n=6

-- center-point curvature test --
ybar(fact) = 11.590 um   ybar(center) = 5.390 um
diff = +6.200 um
s_fact = 3.297, s_center = 2.239, s_pooled = 3.067
SE(diff) = 1.468  ->  t = 4.223, df = 20
t_crit(0.025, 20) = 2.131  ->  CURVATURE PRESENT

-- factorial effects (from 8 corner means) --
E(A speed)    = -4.450 um
E(B feed)     = +2.255 um
E(C coolant)  = +0.665 um
E(AB)         = +1.600 um
mean within-corner SD (pure error) ~= 1.886 um (2 reps/corner)

-- fitted planar model (coded) --
yhat = 11.590 -2.225A +1.128B +0.332C +0.800AB
gradient = (-2.225, 1.128, 0.332);  |g| = 2.516
unit step (descent, toward 12.000 um) = (+0.8842, -0.4481, -0.1321)
axial path: each step of delta (coded) moves (+0.884A, -0.448B, -0.132C) per unit delta
```

Court receipt: `python3 modules/37-doe-curvature/courts/court.py` →
`MODULE 37 COURT: PASS (0 failures)`, RC=0 (20/20 checks, incl. the
contrast-route cross-check of all four effects and the nC=2 non-vacuity probe).

## E1 — Curvature verdict by hand (seed 37001)

| quantity | value | source |
|---|---|---|
| n_fact / n_center | 16 / 6 | court pins (exact) |
| ybar(fact) | 11.590 µm | court pin 11.59 ± 0.01 |
| ybar(center) | 5.390 µm | court pin 5.39 ± 0.01 |
| diff | +6.200 µm | court pin 6.20 ± 0.01 |
| s_fact / s_center | 3.297 / 2.239 µm | captured output |
| s_pooled | 3.067 µm | court pin 3.067 ± 0.01 |
| SE(diff) | 1.468 µm | captured output |
| t | 4.223 | court pin 4.223 ± 0.01 |
| t_crit(0.025, 20) | 2.131 | pinned in compute.py + court |

Hand arithmetic (matches exercises.md):
s_pooled = sqrt((15·3.297² + 5·2.239²)/20) = sqrt(188.12/20) = sqrt(9.406)
= **3.067 µm**. SE = 3.067·sqrt(1/16 + 1/6) = 3.067·0.4787 = **1.468 µm**.
t = 6.200/1.468 = **4.223** > 2.131 → **CURVATURE PRESENT** (df = 20).

## E2 — Axial path unit step

Planar fit yhat = 11.590 − 2.225A + 1.128B + 0.332C + 0.800AB;
gradient g = (−2.225, +1.128, +0.332), target 12.000 µm deviation (smaller is
better) so descent direction = +g.

|g| = sqrt(4.9506 + 1.2724 + 0.1102) = sqrt(6.3332) ≈ **2.516** (the script's
value; recomputing from the rounded coefficients gives 2.517 — display
rounding only).
Unit step = g/|g| = **(+0.8842, −0.4481, −0.1321)** — the key's descent
direction, each unit of delta moving +0.884A, −0.448B, −0.132C.

## E3 — Center points carry no planar leverage

Every factorial effect is a zero-sum contrast: at a center point all coded
factors are 0, so each factor column contributes 0·(y_center − ybar_fact) = 0
and center observations enter no contrast — E(A) = −4.450, E(B) = +2.255,
E(C) = +0.665, E(AB) = +1.600 are unchanged by the 6 center runs. The
curvature test is not a contrast — it is the two-sample t on {16 corners} vs
{6 centers}, so those same 6 runs are its entire sample. Planar estimation and
curvature detection are orthogonal uses of the same 22 runs. Court witness:
the nC=2 non-vacuity check confirms t moves (|Δt| > 0.5) when center points
are truncated.

## Court vs key cross-check

| court pin | court expected | key/captured | verdict |
|---|---|---|---|
| ybar corner | 11.59 | 11.590 | PASS |
| ybar center | 5.39 | 5.390 | PASS |
| diff | 6.20 | +6.200 | PASS |
| pooled SD | 3.067 | 3.067 | PASS |
| t statistic | 4.223 | 4.223 | PASS |
| E(A) contrast route | −4.450 | −4.450 | PASS |
| E(B) contrast route | +2.255 | +2.255 | PASS |
| E(C) contrast route | +0.665 | +0.665 | PASS |
| E(AB) contrast route | +1.600 | +1.600 | PASS |

Mutation gate (anti-vacuity): `python3
modules/37-doe-curvature/courts/court.py --mutate` exits 1
(MUTATION DETECTED — corrupted pinned t still must fail the check; a corrupt
value that still passes would exit 2 as VACUOUS COURT).

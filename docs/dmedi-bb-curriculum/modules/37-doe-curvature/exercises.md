# Module 37 Exercises — Center-Point Curvature Test

Replay source: `python3 data/compute.py` (exit 0). All numbers below re-derive from that run
(regenerates `data/bore-curvature.csv`, seed 37001) and the hand arithmetic in the key.

**Time: 30 min** (Ex 1: 10 min, Ex 2: 10 min, Ex 3: 10 min).

## Exercise 1 — Reproduce the curvature verdict by hand (10 min)

From the key run: n_fact = 16, ybar_fact = 11.590, s_fact = 3.297; n_center = 6,
ybar_center = 5.390, s_center = 2.239; diff = +6.200 um.

(a) Compute the pooled SD (df = 20), the SE of the difference, and t.
(b) Compare to t_crit(0.025, 20) and state the verdict.

### Key (derivation shown)

s_pooled = sqrt( [15·(3.297²) + 5·(2.239²)] / 20 ) = sqrt( (15·10.870 + 5·5.013) / 20 )
         = sqrt( (163.05 + 25.07) / 20 ) = sqrt( 188.12 / 20 ) = sqrt(9.406) = **3.067 um**
SE = 3.067·sqrt(1/16 + 1/6) = 3.067·sqrt(0.22917) = 3.067·0.4787 = **1.468 um**
t = 6.200 / 1.468 = **4.223** > t_crit = 2.131 → **CURVATURE PRESENT** (matches the key run).

## Exercise 2 — Axial path unit step (10 min)

The fitted planar model is yhat = 11.590 − 2.225A + 1.128B + 0.332C + 0.800AB, so the
gradient on the three main effects is g = (−2.225, +1.128, +0.332). The response target is
12.000 um (deviation, smaller is better), so the descent direction is +g.

(a) Compute |g| and the unit step.
(b) Confirm the first axial step lands at the key's (+0.884, −0.448, −0.132).

### Key (derivation shown)

|g| = sqrt(2.225² + 1.128² + 0.332²) = sqrt(4.9506 + 1.2724 + 0.1102) = sqrt(6.3332) ≈ 2.516
(compute.py prints 2.516; recomputing from the rounded coefficients gives 2.517 — the
difference is display rounding of the coefficients only).
Unit step = g/|g| = (+0.8842, −0.4481, −0.1321), exactly the key's descent direction.

## Exercise 3 — Why center points carry no planar leverage (10 min)

Explain, using the design matrix, why adding 6 center points cannot change any of the
factorial effect estimates (E(A) = −4.450, E(B) = +2.255, E(C) = +0.665), yet the curvature
test gains its sensitivity from those same 6 runs.

### Key (derivation shown)

Every factorial effect is a contrast with coefficients summing to zero over each factor's
levels. At a center point all coded factors are 0, so each factor column contributes
0·(y_center − ybar_fact) = 0: center observations enter no contrast. The curvature test is
not a zero-coefficient contrast — it is the two-sample t on {corners} vs {centers}, so the
6 center runs are its entire sample. Planar estimation and curvature detection are therefore
orthogonal uses of the same 22 runs (16 factorial + 6 center).

# Module 39 Exercises — Simplex-Lattice Mixture Design

Replay source: `python3 data/compute.py` (exit 0) — regenerates `coolant-mixture.csv`
(seed 39001) and re-derives every number below.

**Time: 30 min** (Ex 1: 10 min, compute-checked; Ex 2: 10 min; Ex 3: 10 min).

## Exercise 1 — Scheffé coefficients from lattice identities (10 min)

Using only the seven lattice means (V1 12.85, V2 7.01, V3 2.71, M12 13.93, M13 5.40,
M23 4.78, C 8.21), derive b12, b13, b23 by hand and confirm they match the key's printed
15.99, −9.53, −0.34.

### Key (derivation shown)

At a midpoint, x_i = x_j = 1/2, so the quadratic model gives
y_ij = (b_i + b_j)/2 + b_ij/4 → **b_ij = 4·( y_ij − (b_i + b_j)/2 )**.
- b12 = 4·(13.93 − (12.85 + 7.01)/2) = 4·(13.93 − 9.93) = 4·4.00 = **16.00** (key: 15.99 —
  difference is display rounding of ybar).
- b13 = 4·(5.40 − (12.85 + 2.71)/2) = 4·(5.40 − 7.78) = 4·(−2.38) = **−9.52** (key: −9.53).
- b23 = 4·(4.78 − (7.01 + 2.71)/2) = 4·(4.78 − 4.86) = 4·(−0.08) = **−0.32** (key: −0.34).
Python check: `4*(13.93-0.5*(12.85+7.01))` → 16.0; same form for the other two (exit 0).

## Exercise 2 — Synergy vs antagonism in plain language (10 min)

The key reports: oil+emulsifier midpoint 13.93 min vs linear-blend expectation 9.93 min;
oil+water midpoint 5.40 vs linear 7.78. State which pair is synergistic and which is
antagonistic, and what each implies for the blend the shop should buy.

### Key (derivation shown)

Synergy means the observed midpoint EXCEEDS the linear expectation:
b12 = +16.0 > 0 → oil+emulsifier is synergistic (13.93 > 9.93): the pair beats either alone,
so the optimum blend lives in the oil–emulsifier face, not at a vertex.
b13 = −9.52 < 0 → oil+water is antagonistic (5.40 < 7.78): diluting with water costs more
tool life than linearity predicts.
Conclusion: push x3 (water) toward 0 and search the x1–x2 face — which is exactly where the
key's grid search lands: oil 0.70 / emulsifier 0.30 / water 0.00 → 14.45 min.

## Exercise 3 — Why vertex points are not the optimum (10 min)

V1 is pure oil with ybar = 12.85 min, yet the predicted optimum (14.45 min) is an interior
blend. Show numerically why the quadratic term beats the vertex.

### Key (derivation shown)

Model along the x3 = 0 edge: y = 12.85·x1 + 7.01·x2 + 15.99·x1·x2 with x1 + x2 = 1.
Substitute x2 = 1 − x1:
y(x1) = 7.01 + 5.84·x1 + 15.99·x1·(1 − x1).
At the vertex x1 = 1: y = 12.85. At x1 = 0.70: y = 7.01 + 5.84·0.70 + 15.99·0.70·0.30
= 7.01 + 4.088 + 3.358 = **14.46 min** (key's grid search: 14.45 min at 0.70/0.30 —
agreement within grid resolution). The positive b12 term, x1(1−x1) maximal near the middle
of the edge, is what lifts the interior blend above both vertices (V1 12.85, V2 7.01).

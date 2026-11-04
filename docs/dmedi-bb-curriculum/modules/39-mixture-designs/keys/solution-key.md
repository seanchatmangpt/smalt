# Module 39 Solution Key — Simplex-lattice mixture design, seed 39001 (all numbers re-derived)

Command incantation (run from the curriculum root):

```
python3 modules/39-mixture-designs/data/compute.py; echo RC=$?   # RC=0
```

The script regenerates `data/coolant-mixture.csv` deterministically — the seed
(39001) is hardcoded in `data/compute.py`, no seed argument is taken. Verified
this session: sha256 of the CSV is byte-identical before and after the run
(`a670ca1c…fecab`, the exact digest registered in `datasets/MANIFEST.md`), so
the printed numbers are the manifest-registered dataset's numbers.

Full captured output of that run (every number below re-derives from this
output, zero copied):

```
== Module 39 solution key: simplex-lattice mixture design ==
coolant concentrate: x1 oil + x2 emulsifier + x3 water = 1.000
response: tool life (min), 2 reps/point, seed 39001

  V1   (1.000,0.000,0.000)  ybar =  12.85  obs [12.62, 13.08]
  V2   (0.000,1.000,0.000)  ybar =   7.01  obs [6.73, 7.28]
  V3   (0.000,0.000,1.000)  ybar =   2.71  obs [2.29, 3.14]
  M12  (0.500,0.500,0.000)  ybar =  13.93  obs [13.11, 14.74]
  M13  (0.500,0.000,0.500)  ybar =   5.40  obs [4.94, 5.86]
  M23  (0.000,0.500,0.500)  ybar =   4.78  obs [4.86, 4.69]
  C    (0.333,0.333,0.333)  ybar =   8.21  obs [7.32, 9.11]

pure-error SD = 0.755 min (df = 7)

-- Scheffe quadratic coefficients (lattice identities) --
  b1 (oil)          =  12.85
  b2 (emulsifier)   =   7.01
  b3 (water)        =   2.71
  b12 (nonlinear)   =  15.99
  b13 (nonlinear)   =  -9.53
  b23 (nonlinear)   =  -0.34
  yhat = b1*x1 + b2*x2 + b3*x3 + b12*x1x2 + b13*x1x3 + b23*x2x3

-- OLS cross-check (all 14 obs) --
  b1   =  12.85
  b2   =   7.00
  b3   =   2.71
  b12  =  16.01
  b13  =  -9.51
  b23  =  -0.32
  residual SD = 0.706 min on 8 df

-- surface search over the simplex (5% grid, 231 blends) --
  optimum blend: oil 0.70 / emulsifier 0.30 / water 0.00  ->  predicted tool life 14.45 min
  slice x1=0.30: emul/water 50-50 ->   7.89 min
  slice x1=0.40: emul/water 50-50 ->   8.80 min
  slice x1=0.50: emul/water 50-50 ->   9.64 min
  slice x1=0.60: emul/water 50-50 ->  10.42 min
  slice x1=0.70: emul/water 50-50 ->  11.12 min

synergy check oil+emulsifier: midpoint observed 13.93 vs linear-blend expectation 9.93 -> synergistic bend
oil+water: midpoint 5.40 vs linear 7.78 -> antagonistic bend
```

## Gate receipts (this session, curriculum root)

| gate | command | result |
|---|---|---|
| court | `python3 modules/39-mixture-designs/courts/court.py` | **exit 0** — 25/25 PASS, "MODULE 39 COURT: PASS (0 failures)" |
| non-vacuity | mutate one cell (13.11 → 12.00), rerun court | **exit 1**, 10 FAILs; `git checkout` restore byte-exact (sha256 match) |
| manifest | `python3 datasets/manifest_verify.py` | **exit 0** — 61 PASS, 0 SKIP, 0 FAIL |

## E1 — Scheffé coefficients from lattice identities

At a midpoint x_i = x_j = 1/2 the quadratic gives y_ij = (b_i + b_j)/2 +
b_ij/4, so **b_ij = 4·(y_ij − (b_i + b_j)/2)**.

| pair | midpoint ybar | linear expectation | hand b_ij (rounded ybars) | compute.py output | court pinned |
|---|---|---|---|---|---|
| 1-2 | 13.93 | (12.85+7.01)/2 = 9.93 | 4·4.00 = **+16.00** | 15.99 | 15.99 |
| 1-3 | 5.40 | (12.85+2.71)/2 = 7.78 | 4·(−2.38) = **−9.52** | −9.53 | −9.53 |
| 2-3 | 4.78 | (7.01+2.71)/2 = 4.86 | 4·(−0.08) = **−0.32** | −0.34 | −0.34 |

The hand values differ from the printed ones only because the hand arithmetic
uses 2-dp-rounded ybars; the script computes from full-precision means
(b23: full precision −0.34 vs rounded-cell −0.32). The b_i themselves are the
vertex means by the lattice identity: b1 = ȳ(V1) = 12.85, b2 = 7.01,
b3 = 2.71 — matching the court's pinned (12.85, 7.01, 2.71).

## E2 — Synergy vs antagonism

| pair | observed midpoint | linear blend | b_ij | verdict |
|---|---|---|---|---|
| oil + emulsifier | 13.93 | 9.93 | +15.99 | **synergistic** (midpoint exceeds blend) |
| oil + water | 5.40 | 7.78 | −9.53 | **antagonistic** (midpoint below blend) |

Implication for the shop: oil + emulsifier beats either component alone, so
the optimum lives on the oil–emulsifier face; water dilutes tool life faster
than linearity predicts, so push x3 → 0. The grid search confirms: optimum at
water share 0.00.

## E3 — Why the vertex is not the optimum

Along the x3 = 0 edge with x2 = 1 − x1:

y(x1) = 12.85·x1 + 7.01·(1−x1) + 15.99·x1(1−x1) = 7.01 + 5.84·x1 + 15.99·x1(1−x1)

| x1 | y(x1) |
|---|---|
| 1.00 (V1, pure oil) | 12.85 |
| 0.70 | 7.01 + 4.088 + 3.358 = **14.46** |
| 0.50 | 9.64 (matches the printed slice) |

The x1(1−x1) synergy term peaks at x1 = 0.5 and is still worth +3.36 min at
x1 = 0.70, lifting the interior blend above the best vertex (12.85). Grid
optimum: 0.70/0.30/0.00 → **14.45 min** (hand 14.46 — grid-resolution
difference; court pins optimum tool life 14.45, oil 0.70, emulsifier 0.30).

## Pure-error vs residual SD

pure-error SD 0.755 min on 7 df (replicate scatter) vs model residual SD
0.706 min on 8 df: the quadratic leaves nothing for lack-of-fit to explain
(residual ≈ pure error), so the Scheffé quadratic is adequate — no cubic term
needed at this resolution.

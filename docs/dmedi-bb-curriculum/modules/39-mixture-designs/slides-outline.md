# Module 39 — Mixture Designs: Simplex Geometry for the Coolant Concentrate

**Module**: 39-mixture-designs
**Learning objectives** — after this module the Black Belt candidate can:
1. Explain why mixture DOE breaks the independence assumption of factor DOE: components are constrained to sum to 1, so the design space is a simplex, not a cube.
2. Read and build a {3,2} simplex lattice: 3 vertices, 3 edge midpoints, 1 centroid.
3. Fit a Scheffé quadratic with the lattice identities (no matrix inversion needed) and cross-check with plain OLS.
4. Interpret binary (b_ij) blending terms as synergistic vs antagonistic bends along each edge.
5. Search the fitted surface over the simplex grid to locate the optimum blend.

**Timing estimate**: 3.5 h (slides 1.25 h, lab 1.25 h, exercises 0.5 h, court/self-check 0.5 h).
**Required tools**: python3 stdlib only. Solution key: `data/compute.py` — regenerates `coolant-mixture.csv` (seed 39001) and re-derives every number below.

**Running-case anchor**: CPPC coolant system — the concentrate fed to the CNC line is a blend: **x1 = neat cutting oil, x2 = emulsifier, x3 = water, x1 + x2 + x3 = 1.000**. Response: tool life (min) on the gimbal-housing roughing pass (longer is better; pairs with the module 37/40 bore-deviation strand through the same machine).

---

## Slide 1 — Why mixtures are different (10 min)
- Factor DOE (modules 30/37) varies factors independently. In a mixture, raising oil must lower something else — the factors are **structurally dependent**.
- Consequence 1: the design space is the triangle (simplex) x1+x2+x3 = 1, not a cube.
- Consequence 2: the polynomial needs Scheffé form — no intercept, since the intercept is not identifiable (x1+x2+x3 = 1 absorbs any constant).
- Consequence 3: "main effect of x1" is meaningless alone; what matters is the **shape of the response over the simplex** — blends can beat every pure component (synergy).

## Slide 2 — The {3,2} simplex lattice, drawn (15 min)
```
                      V1 (pure oil)
                     x1 = 1.0        y = 12.85
                        /\
                       /  \
            M13       /    \       M12
      (oil+water)    /      \    (oil+emulsifier)
        y = 5.40    /        \     y = 13.93
                   /    C     \
                  /  (1/3 each) \
                 /    y = 8.21   \
                /__________________\
        V3 (pure water)        V2 (pure emulsifier)
          x3 = 1.0                 x2 = 1.0
          y = 2.71                 y = 7.01
```
- {3,2} notation: 3 components, lattice degree 2 — blends of at most 2 components in proportions (1,0), (1/2,1/2). 6 lattice points + 1 centroid = 7 design points, 2 reps each = 14 runs.
- Each edge of the triangle is a two-component experiment; the interior is where three-way blending lives.

## Slide 3 — The data (10 min)
From `coolant-mixture.csv` (seed 39001, σ = 0.8 min):

| point | (x1, x2, x3) | ybar (min) |
|---|---|---|
| V1 | (1.000, 0.000, 0.000) | 12.85 |
| V2 | (0.000, 1.000, 0.000) | 7.01 |
| V3 | (0.000, 0.000, 1.000) | 2.71 |
| M12 | (0.500, 0.500, 0.000) | **13.93** |
| M13 | (0.500, 0.000, 0.500) | 5.40 |
| M23 | (0.000, 0.500, 0.500) | 4.78 |
| C  | (0.333, 0.333, 0.333) | 8.21 |

Pure-error SD = 0.755 min (7 df). First read, before any model: the M12 blend **beats pure oil** (13.93 > 12.85). No linear model can represent that — synergy exists.

## Slide 4 — Scheffé quadratic from lattice identities (25 min, worked)
For a {3,2} lattice the coefficients fall out as identities:
- `b_i` = response at vertex i (pure component i)
- `b_ij` = `4*y_mid(ij) − 2*(y_i + y_j)` — the bend along edge ij

```
  b1 (oil)        = 12.85      b12 (bend) = +15.99
  b2 (emulsifier) =  7.01      b13 (bend) =  -9.53
  b3 (water)      =  2.71      b23 (bend) =  -0.34
  yhat = 12.85x1 + 7.01x2 + 2.71x3 + 15.99x1x2 - 9.53x1x3 - 0.34x2x3
```

OLS on all 14 obs cross-checks: b1 12.85, b2 7.00, b3 2.71, b12 16.01, b13 −9.51, b23 −0.32; residual SD 0.706 min on 8 df. The identities and OLS agree to within the noise — either route is lawful; the candidate must run both and compare.

## Slide 5 — Reading the bends (15 min)
- **b12 = +16.0: synergistic.** Oil+emulsifier midpoint 13.93 vs linear expectation 9.93 — the emulsifier disperses the oil; the blend lubricates better than either alone. Mechanistically real: emulsion chemistry.
- **b13 = −9.5: antagonistic.** Oil+water midpoint 5.40 vs linear 7.78 — unmulsified water dilutes oil film strength.
- **b23 = −0.3: negligible** — emulsifier/water edge is essentially linear.
- Teaching point: the binary coefficients are the *story* of a mixture DOE; the vertex coefficients are just starting points.

## Slide 6 — Surface search over the simplex (20 min, worked)
The key evaluates yhat on a 5% grid (231 blends) constrained to x1+x2+x3 = 1:

```
optimum blend: oil 0.70 / emulsifier 0.30 / water 0.00
  ->  predicted tool life 14.45 min
slice along the x2=x3 ridge:  x1=0.30 -> 7.89 | 0.40 -> 8.80 | 0.50 -> 9.64
                              | 0.60 -> 10.42 | 0.70 -> 11.12 min
```

- The optimum sits on the oil–emulsifier edge (water out), consistent with b13 < 0.
- Constrained blends in practice: if the coolant vendor requires water ≥ 0.05, the candidate re-runs the grid with the boundary and reports the constrained optimum — the surface machinery does not change.
- Confirmation law: predicted 14.45 min is a claim, not a receipt. The lab requires a real confirmation batch of 3 replicate mixes at (0.70, 0.30, 0.00) with the prediction interval stated before the blend is handed to production.

## Slide 7 — Why-it-works (10 min)
- The lattice identities are OLS in disguise: because the design points are at exact (1,0) and (½,½) positions, the normal equations decouple — the same orthogonality logic as the 2^k factorial, adapted to the simplex geometry.
- Degrees of freedom: 14 obs − 6 params = 8 df, of which 7 are pure error and 1 tests lack of fit at the centroid. The centroid check (observed 8.21 vs predicted from the quadratic 8.20) is the built-in model adequacy court.
- Robustness link (module 40): the next question after "best blend" is "how much does tool life move if the dispense pump drifts ±2% on oil?" — the surface slope at the optimum answers it, which is exactly the control×noise framing of the next module.

## Lab — candidate executes (60 min)
1. `python3 data/compute.py` → exit 0; reproduce the coefficient table and the 14.45-min optimum.
2. Verify lattice balance: every design point's components sum to exactly 1.000 (write the check; it must pass on all 14 rows).
3. Hand-compute b12 from the identity using the printed ybars; compare to the OLS value.
4. Re-fit with only the 6 lattice points (drop the centroid) and show the centroid then becomes a genuine prediction test: report predicted vs observed (8.21) and the residual.
5. Add a water-concentration constraint (x3 ≥ 0.05) and re-search the grid; report the constrained optimum and its cost in tool life vs 14.45 min.
6. Court question: why is there no intercept in the Scheffé model? Demonstrate by adding one and showing the normal equations become singular on this design.

## Court / self-check (exit-checked)
- `python3 data/compute.py` exits 0; all numbers above re-derive from `coolant-mixture.csv`.
- Non-vacuity: perturb one M12 replicate by +3 min and confirm b12 moves by > 1; restore from seed.
- Coherence: response and machine tie to the CPPC line; the coolant concentration factor pinned in RUNNING-CASE.md is the same physical system at blend-level resolution.

## See also
Module 30/37 (factor designs — the contrast), 40 (robust design: slope-at-optimum as the noise-sensitivity question), 41 (sequential RSM: same quadratic machinery on independent factors).

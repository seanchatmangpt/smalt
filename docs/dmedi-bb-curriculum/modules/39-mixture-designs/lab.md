# Module 39 Lab — Simplex-Lattice Mixture Design (Coolant Concentrate)

**Objective**: fit a Scheffé quadratic over the {oil, emulsifier, water} simplex from a
{3}-simplex-lattice (vertices + midpoints + centroid), classify each binary pair as
synergistic or antagonistic, and locate the optimum blend by grid search.

**Dataset**: `data/coolant-mixture.csv` — 7 lattice points × 2 reps = 14 runs, seed 39001
(hardcoded in `data/compute.py`; the script regenerates the CSV byte-identically —
manifest-registered sha256 `a670ca1c…fecab`).

**Replay incantation** (from the curriculum root):

```bash
python3 modules/39-mixture-designs/data/compute.py; echo RC=$?    # RC=0
python3 modules/39-mixture-designs/courts/court.py; echo RC=$?    # RC=0, 25/25 checks
```

**Time: ~30 min** (Lab 1: 12 min, Lab 2: 10 min, Lab 3: 8 min).

## Lab 1 — Scheffé coefficients from lattice identities (12 min)

Lattice means from the compute.py run: V1 12.85, V2 7.01, V3 2.71, M12 13.93, M13 5.40,
M23 4.78, C 8.21 (pure-error SD 0.755 min on 7 df). At a midpoint x_i = x_j = 1/2,
y_ij = (b_i + b_j)/2 + b_ij/4, so **b_ij = 4·(y_ij − (b_i + b_j)/2)**.

- b12 = 4·(13.93 − 9.93) = **+16.00** by hand (script prints 15.99 — display rounding of ybar)
- b13 = 4·(5.40 − 7.78) = **−9.52** by hand (script: −9.53)
- b23 = 4·(4.78 − 4.86) = **−0.32** by hand (script: −0.34; full-precision means)

**Checkpoint (court-pinned)**: b = (12.85, 7.01, 2.71, 15.99, −9.53, −0.34). The court
cross-checks with an OLS refit on all 14 obs (b12 16.01, residual SD 0.706 min on 8 df ≈
pure error 0.755 — no lack of fit, no cubic term needed).

## Lab 2 — Synergy vs antagonism (10 min)

| pair | observed midpoint | linear blend | b_ij | verdict |
|---|---|---|---|---|
| oil + emulsifier | 13.93 | 9.93 | +15.99 | **synergistic** |
| oil + water | 5.40 | 7.78 | −9.53 | **antagonistic** |

Implication: the optimum lives on the oil–emulsifier face; push water toward 0.

**Checkpoint (court-pinned)**: grid search (5% grid, 231 blends) optimum =
oil 0.70 / emulsifier 0.30 / water 0.00 → predicted tool life **14.45 min**.

## Lab 3 — Why the vertex is not the optimum (8 min)

Along the x3 = 0 edge (x2 = 1 − x1): y(x1) = 7.01 + 5.84·x1 + 15.99·x1(1−x1).
At V1 (x1 = 1): 12.85. At x1 = 0.70: 7.01 + 4.088 + 3.358 = **14.46 min** (grid: 14.45 —
grid resolution). The x1(1−x1) synergy term, worth +3.36 min at x1 = 0.70, lifts the
interior blend above the best vertex. Write up the numerical argument.

## Tool note

Stdlib-only (`csv`, `math`, `statistics`); no Minitab/R required. Non-vacuity witnessed:
mutating one CSV cell (13.11 → 12.00) flips the court to exit 1 (10 FAILs) and the restore
is sha256-verified byte-exact. `python3 datasets/manifest_verify.py` must stay exit 0
(61 PASS, 0 FAIL).

## Receipt format

```
subject: modules/39-mixture-designs lab
identity: sha256 of answers + court exit code
replay:   python3 modules/39-mixture-designs/data/compute.py && python3 modules/39-mixture-designs/courts/court.py
```

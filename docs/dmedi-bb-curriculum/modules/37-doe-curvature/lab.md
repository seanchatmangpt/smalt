# Module 37 Lab — Center-Point Curvature Test on the CPPC Bore

**Objective**: detect curvature in the bore-deviation response by adding center points to a
2^3 factorial, test the center-vs-corner difference with a pooled two-sample t, and derive
the steepest-descent axial path from the planar fit.

**Dataset**: `data/bore-curvature.csv` — 8 corners × 2 reps + 6 center points = 22 runs,
seed 37001 (hardcoded in `data/compute.py`; the script regenerates the CSV byte-identically
before re-deriving every number).

**Replay incantation** (from the curriculum root):

```bash
python3 modules/37-doe-curvature/data/compute.py; echo RC=$?    # RC=0
python3 modules/37-doe-curvature/courts/court.py; echo RC=$?    # RC=0, 20/20 checks
```

**Time: ~30 min** (Lab 1: 12 min, Lab 2: 10 min, Lab 3: 8 min).

## Lab 1 — Reproduce the curvature verdict (12 min)

From the compute.py run, checkpoints:

- n_fact = 16, ybar(fact) = **11.590 µm**, s_fact = 3.297
- n_center = 6, ybar(center) = **5.390 µm**, s_center = 2.239
- diff = **+6.200 µm**

By hand: s_pooled = sqrt((15·3.297² + 5·2.239²)/20) = **3.067 µm**;
SE = 3.067·sqrt(1/16 + 1/6) = **1.468 µm**; t = 6.200/1.468 = **4.223**.

**Checkpoint (court-pinned)**: t = 4.223 > t_crit(0.025, 20) = 2.131 →
**CURVATURE PRESENT** (df = 20). The court re-derives t by an independent route and
additionally proves non-vacuity: truncating center points to nC = 2 must move t by > 0.5.

## Lab 2 — Axial path unit step (10 min)

Fitted planar model: yhat = 11.590 − 2.225A + 1.128B + 0.332C + 0.800AB, so
g = (−2.225, +1.128, +0.332). Target deviation is 12.000 µm (smaller is better), so the
descent direction is +g.

- |g| = sqrt(4.9506 + 1.2724 + 0.1102) = **2.516** (recomputing from the rounded
  coefficients gives 2.517 — display rounding only)
- Unit step = g/|g| = **(+0.8842, −0.4481, −0.1321)**

**Checkpoint (court-pinned effects, contrast route)**: E(A) = −4.450, E(B) = +2.255,
E(C) = +0.665, E(AB) = +1.600 µm. Each unit of delta moves +0.884A, −0.448B, −0.132C.

## Lab 3 — Why center points carry no planar leverage (8 min)

Show from the design matrix that the 6 center runs cannot change any factorial effect
(zero-sum contrasts; coded factors are 0 at center, so center obs enter no contrast), yet
they are the entire sample of the curvature t. One-paragraph answer in `exercises.md` Ex 3.

## Tool note

Stdlib-only (`csv`, `math`, `statistics`); no Minitab/R required. `--mutate` on the court
must exit 1 (MUTATION DETECTED); a corrupt constant that still passes exits 2 as
VACUOUS COURT.

## Receipt format

```
subject: modules/37-doe-curvature lab
identity: sha256 of answers + court exit code
replay:   python3 modules/37-doe-curvature/data/compute.py && python3 modules/37-doe-curvature/courts/court.py
```

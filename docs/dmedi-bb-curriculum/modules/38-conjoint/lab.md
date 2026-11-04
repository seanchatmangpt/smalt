# Module 38 Lab — Conjoint Part-Worths and Importance Shares

**Objective**: recover customer part-worth utilities from a 9-card L9 ranking task by OLS
rank regression (effect coding), compute attribute importance as range shares, and predict
the best/worst of all 81 profiles.

**Dataset**: `data/conjoint-cards.csv` + `data/conjoint-ranks.csv` — authored L9 card design,
9 ranks with gauss(0, 0.55) noise on true utility, seed 38001 (hardcoded in
`data/compute.py`; the script regenerates both CSVs byte-identically before re-deriving
every number).

**Replay incantation** (from the curriculum root):

```bash
python3 modules/38-conjoint/data/compute.py; echo RC=$?    # RC=0
python3 modules/38-conjoint/courts/court.py; echo RC=$?    # RC=0, 26/26 checks
```

**Time: ~30 min** (Lab 1: 12 min, Lab 2: 10 min, Lab 3: 8 min).

## Lab 1 — Importance shares from the part-worth table (12 min)

From the compute.py run, the part-worth table (rank scale; more negative = more preferred):

- price: $52 +3.000, $38 −0.667, $30 −2.333
- lead: 15 days +1.667, 10 days −0.333, 7 days −1.333
- tol: ±0.025 −0.333, ±0.015 0.000, ±0.008 +0.333
- finish: Ra 1.6 −0.333, Ra 0.8 0.000, Ra 0.4 +0.333

Ranges: price 5.333, lead 3.000, tol 0.667, finish 0.667; total 9.667.

**Checkpoint (court-pinned, ±0.05)**: importance = price **55.2%**, lead **31.0%**,
tol **6.9%**, finish **6.9%** — sum 100.0%. The court re-derives every part-worth by an
independent route (level means − 5, exact by L9 orthogonality) and matches to ±0.01.

## Lab 2 — Predict the best and worst profiles (10 min)

Score profiles by reading the part-worth table directly against intercept
b0 (mean rank) = 5.000.

- BEST (predicted rank 1): u = 5.000 − 2.333 − 1.333 − 0.333 − 0.333 = **−4.333**
  → price $30, lead 7 days, tol ±0.025 mm, finish Ra 1.6
- WORST (predicted rank 9): u = **+5.333** → $52 / 15 days / ±0.008 / Ra 0.4

**Checkpoint**: the 81-profile utility surface is exactly antisymmetric around the b0 = 5.000
mean rank — WORST is the mirror of BEST. The court additionally refits the saturated design
and pins residual SD ≈ 0.

## Lab 3 — Why tolerance looks unimportant (8 min)

The panel puts 86.2% of utility weight on price + lead time and treats the tolerance grade
as nearly indifferent (range 0.667, 6.9%). Write the one-paragraph reconciliation with
Module 37's engineering effects (E(B feed) = +2.255 µm): conjoint importance is
customer-side, engineering effects are machine-side — different response surfaces, and
robust design (Module 40) is what lets the shop sell the cheap tolerance grade profitably.

## Tool note

Stdlib-only OLS (effect coding, normal equations); no Minitab/R required. `--mutate` on the
court must exit 1 (MUTATION DETECTED); a corrupt pinned importance share that still passes
exits 2 as VACUOUS COURT.

## Receipt format

```
subject: modules/38-conjoint lab
identity: sha256 of answers + court exit code
replay:   python3 modules/38-conjoint/data/compute.py && python3 modules/38-conjoint/courts/court.py
```

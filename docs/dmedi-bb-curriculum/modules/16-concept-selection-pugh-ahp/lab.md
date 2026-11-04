# Module 16 — Lab: Pugh + AHP on the CPPC Bore-Finish Concepts

Run from the module root: `cd modules/16-concept-selection-pugh-ahp`.
Tools: python3 stdlib only (`csv`, `math`). Every answer re-derives from
`data/concept_trials.csv`; the derivation engine
`python3 scripts/derive_selection.py` prints all intermediate values and
exits 0 only when every court check passes.

## Route facts (authored, NOT derived — use these as given)

| route | cycle (min) | added capital | setups | tool sourcing |
|---|---|---|---|---|
| A citizen regrind | 22 | $0 (existing) | 1 | in-house regrind loop |
| B peck deep-drill then bore | 14 | $18k deep-cycle tooling | 2 | standard commodity tooling |
| C helical interpolation | 11 | $0 (existing end mill) | 1 | standard, but program-sensitive |
| D combined rough+finish boring bar | 17 | $34k custom bar | 1 | single-source custom tool |

## Part 1 — Pugh matrix (25 min)

### Step 1.1 Datum justification (write it down)
The datum is A (citizen regrind). Justify in two sentences BEFORE scoring:
why the incumbent is the only defensible datum for a gate-review decision
on a Cpk-0.72 baseline. (Solution-key sentence pair provided.)

### Step 1.2 Scoring bases
State the C1/C2 bands from the lab brief:
- C1: +/- requires a Cpk gap >= 0.20 vs datum pilot Cpk.
- C2: +/- requires an Ra gap >= 0.15 um vs datum mean Ra.
- C3/C4/C5: mark directly from the route-facts table.

### Step 1.3 Compute pilot statistics

```
python3 scripts/derive_selection.py   # section 1 prints per-concept stats
```

You need: datum Cpk, each concept's Cpk and mean Ra. Verify section 1 shows
A at Cpk 0.72, s = 7.51 um (pilot estimate of the adjudicated 7.407 um
spine pair).

### Step 1.4 Assign marks and tally
Fill the matrix, tally + / - / 0 per concept, compute net = plus - minus.
Expected: B net +3; C and D net +1 each; A all-zero datum row.

### Step 1.5 Consolidation iteration (Pugh convergence)
D is minus on C4 (custom bar) and C5 (single-source). Author the
consolidation concept **D2** = combined rough+finish boring bar with
standard coated insert set, single setup, then re-score ONLY the cells that
changed (C4 0, C5 +) vs the SAME datum A. New net: +3.
Check the Pugh convergence law: D2 ties B (net +3 = +3). Per the law, do
NOT break the tie by trading marks — record the tie and escalate to Part 2.

## Part 2 — AHP on the same four concepts (25 min)

### Step 2.1 Criteria pairwise matrix
Use the lab-brief matrix (from QFD relative weights):

```
        C1  C2  C3  C4  C5
C1       1   2   3   2   5
C2      1/2  1   2  1/2  4
C3      1/3 1/2  1  1/2  3
C4      1/2  2   2   1   4
C5      1/5 1/4 1/3 1/4  1
```

### Step 2.2 Weights + consistency
The engine prints eigenvector weights, geometric-mean cross-check,
lambda_max, CI, CR. Expected: CR = 0.0246 < 0.10 → usable. If your
matrix yields CR >= 0.10, repair judgments before proceeding.

### Step 2.3 Concept matrices (data-grounded)
The engine snaps pilot ratios to the nearest Saaty value:
- C1 matrix: ratios of pilot Cpk (floored at 0.10)
- C2 matrix: inverse ratios of mean Ra
- C3 matrix: inverse ratios of route minutes (22/14/11/17)
- C4 matrix: ratios of authored cost factors (A 1.0, B 2.5, C 1.2, D 3.5)
- C5 matrix: ratios of authored flexibility ordinals (A 3, B 4, C 2, D 2)

Verify each prints CR < 0.10.

### Step 2.4 Global scores
Engine section 4 prints global scores and the AHP ranking. Expected:
A 0.2263, B 0.2575, C 0.2425, D 0.2736; ranking D > B > C > A.
Verify each concept's global score equals the weighted sum shown in the
solution key (three-decimal agreement required).

## Part 3 — Agreement / divergence debrief (10 min)

Answer in writing (solution key carries the full analysis):

1. Why does unweighted Pugh pick B while weighted AHP picks D?
2. D2 ties B at net +3. Why is vote-trading the banned tie-break, and what
   is the lawful escalation?
3. If the criteria weights were equal (0.2 each), which concept wins AHP?
   Recompute with equal weights before answering.
   (Equal-weight rerun snippet is in the solution key.)
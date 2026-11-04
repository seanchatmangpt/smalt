# Module 16 — Exercises: Concept Selection (Pugh + AHP)

Same four concepts, same CSV. Do these AFTER the lab. Every numeric answer
re-derives via `python3 scripts/derive_selection.py` (exit 0) or the code
snippets shown in `solution-key.md`. Write code where asked; no answers by
inspection.

## E1. Datum defense (written, ~5 min)
A teammate proposes using concept C (helical interpolation) as the Pugh
datum because it has the best cycle time. Give two reasons the incumbent A
is the lawful datum here and one consequence of using C instead (what the
matrix would and would not tell you).

## E2. Band sensitivity (code + written, ~10 min)
The stated C1 band is +/-0.20 Cpk. Recompute the Pugh matrix with the band
tightened to 0.10. Which cells flip? Does the iteration-1 net leader
change? Note: B's pilot Cpk 1.55 vs datum 0.72 (gap +0.83) and D's 1.84
(gap +1.12) both still clear a 0.10 band — state which gap is closest to
flipping, and why the 0.20 band exists at all given n = 30.

## E2 answer-data (no derivation needed): C's pilot Cpk is 1.04, datum 0.72,
gap +0.32.

## E3. Criteria weights from a NEW pairwise matrix (code, ~10 min)
A new BB candidate team judges: C1 vs C2 = 3, C1 vs C4 = 2, C1 vs C5 = 7,
C2 vs C3 = 2, C2 vs C4 = 1, C2 vs C5 = 5, C3 vs C4 = 1/2, C3 vs C5 = 4,
C4 vs C5 = 5 (upper triangle; fill reciprocals). Compute the eigenvector
weights, lambda_max, CI, CR. Is the matrix usable? If CR >= 0.10, name the
most intransitive triad and repair it (state the judgment you change and
why), then recompute.

## E4. Deliberately inconsistent repair (code, ~10 min)
The teaching matrix CRIT_MAT_BAD (CR = 0.5840, lambda_max = 7.6162)
contains the cyclic triad C1>C2 (9), C2>C3 (9), C1~C3 (1). Repair it by
changing ONE judgment. Predict lambda_max direction first, then verify
with the engine's `eigen_weight` and report the new CR.

## E5. Equal-weight AHP (code, ~10 min)
Set all five criteria weights to 0.2 and recompute global scores.
Expected: A 0.2456, B 0.2650, C 0.2414, D 0.2479; ranking B > D > A > C.
Answer: what does this tell you that the weighted run (D > B > C > A)
does not? One sentence: what is the ONLY thing that changed?

## E5 note: with equal weights B wins because its marks are broad (four
pluses) rather than deep; the weighted run rewards depth on C1/C2 where D
dominates. Breadth vs depth is the whole lesson of this module.

## E6. New concept E enters (code + written, ~15 min)
Concept E = helical interpolation + regrind hybrid: cycle 15 min, added
capital $8k standard program template, 1 setup, flexibility ordinal 3,
cost factor 2.0. Its pilot is synthetic: use mu = 12.0035 mm, sigma
0.0055 mm, Ra center 1.8 um, the registered seed 1607 (same generation law as
`scripts/gen_trials.py`). Generate E's 30 trials, add to the CSV copy
`data/concept_trials_plus_e.csv` (do NOT overwrite the registered CSV),
re-run both methods on the 5-concept set, and report both rankings.

## E7. Consistency of the C2 matrix under rounding (code, ~5 min)
The C2 matrix was built by snapping Ra ratios to Saaty values. Suppose the
team skips snapping and enters raw ratios (Ra_j/Ra_i to 3 dp). Recompute
the C2 priorities from raw ratios (geometric-mean method suffices) and
report priorities + lambda_max + CR. Does skipping the Saaty scale change
the C2 ranking? (It must not — the snap preserved order. Verify.)

## E8. Decision memo (written, ~15 min)
Write the gate-review memo (<= 200 words) recommending D2, citing: the
iteration-1 divergence (B vs D), the tie, the lawful escalation (data +
weights), AHP margin (0.2736 vs 0.2575, relative margin
(0.2736-0.2575)/0.2575 = 6.3% over B), the killed concept C with reason,
and what module 18 (Monte Carlo) must demonstrate before capital release.

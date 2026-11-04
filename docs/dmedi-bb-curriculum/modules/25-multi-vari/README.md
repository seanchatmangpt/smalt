# Module 25 — Multi-Vari Charts and Variance Components

## Case
CPPC gimbal housing bore deviation (spine CTQ-1, sigma regime 7.407 um per
RUNNING-CASE.md). Dataset `data/multivari-bore.csv` (n=45, seed 42501):
5 pcs x 3 spindles x 3 time blocks, bore deviation um. Baseline shift +9 um
(mu = 12.009 mm); planted positional offsets -10/-5/0/+5/+10 um; spindle and time
offsets zero; eps ~ N(0, 2.4) -> total s ~ 7.47 um, positional family ~90% of
variance.

## Contents
- `slides/slides-outline.md` — families of variation, multi-vari chart, one-way
  ANOVA per family, eta^2, classical variance components, concentration decision.
- `labs/multivari-lab.md` — guided lab incl. hand ASCII family chart.
- `exercises.md` — 8 exercises.
- `keys/solution-keys.md` — every F/eta^2/variance-component derived from the raw
  CSV by `scripts/derive_keys.py` (exit 0).
- `courts.md` — court transcript (python3 exit-checked).
- `scripts/gen_multivari_bore.py` (seed 42501), `scripts/derive_keys.py`.

## TSS law (Lane 10 known bug, fixed and witnessed)
SST = SUM((y - ybar)^2), centered — never SUM(y^2). Witness: centered
SST = 2518.5487 vs uncentered 5862.074 on this dataset.

## Spine
Total s = 7.566 um on this sample — in the adjudicated 7.407 um regime; the positional
family (where the part sits in the fixture) carries ~90% of the variance, which is
exactly the kind of dominant-family finding the Improve phase attacks.

## Learning objectives

By the end of this module you will be able to:

1. Classify the bore-deviation study into positional / cyclical /
   temporal families from the 5 x 3 x 3 design, and state why balance
   matters for the variance-components estimator (E1).
2. Compute the centered SST by hand (2518.5487, never SUM(y^2) =
   5862.074) and grand mean (8.6198 um) from
   `data/multivari-bore.csv`.
3. Compute and interpret eta^2 per family (positional 0.8908) and rank
   the families as a Multi-Vari chart would.
4. Derive variance components sigma2_family = (MSB - MSW)/m for each
   family and convert them to percent-of-total, identifying the
   fixture-position family (~90%) as the Improve-phase target.
5. Convert the dominant-family finding into a concentration decision
   (which lever to pull, which families to declare negligible) with the
   risk statement the Improve gate requires.

## Session timing

- Families-of-variation briefing and design walk (15 min)
- Lab parts 1-4: totals, positional family by hand, ASCII chart (40 min)
- eta^2 and variance-components derivation, instructor arithmetic
  visible from `keys/solution-keys.md` (20 min)
- Cyclical/temporal families + concentration decision debate (15 min)
- Exercise block E1-E8 debrief (20 min)

## Tools

Minitab: Stat > Quality Tools > Multi-Vari Chart for the plot;
Stat > ANOVA > General Linear Model > Fit General Linear Model for the
per-family F and eta^2 inputs. Python mirror:
`python3 scripts/gen_multivari_bore.py && python3 scripts/derive_keys.py`
regenerates `data/multivari-bore.csv` and every F/eta^2/component value
(exit 0); numpy/scipy f_oneway per family mirrors the ANOVA table.

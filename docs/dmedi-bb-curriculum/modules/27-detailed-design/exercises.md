# Module 27 Exercises

Keyed answers with derivations in `keys/solution-key.md`; court:
`python3 scripts/derive_keys.py` (exit 0). Data:
`data/design-control-checklist.csv` and `data/thermal-warmup-study.csv`
(regenerate with `python3 scripts/gen_verification_dataset.py`, seed 2711).

1. Derive sigma_max for the guard band: show sigma_max = 0.008/(3 x 1.33),
   convert to um, and compute the baseline guard-band Cpk at the adjudicated
   spine sigma 7.407 um. (10 min)
2. Convert the sigma reduction (7.407 -> 2.005 um) into a variance factor, and
   explain why variance is the quantity that composes across independent
   improvements. (5 min)
3. From `data/thermal-warmup-study.csv`: compute both arm means, the mean
   reduction, and list the with-model trials above 3 um. Then give BOTH
   verdicts — mean-based and per-piece — and state which one the CP-13
   criterion as written demands. (15 min)
4. Classify CP-1, CP-8, CP-10, CP-13, CP-15 by DFX class and name the one
   error-proofing pattern the three error-proofing rows share. (10 min)
5. Traceability: for CP-3, CP-13, and CP-17, name (a) the DFMEA action it
   verifies, (b) the downstream module that operationalizes it
   (12 / 42 / 43 / 11). (10 min)
6. A teammate proposes adding a 19th row "100% final visual inspection" as a
   control for every mode. Give two arguments from this module's chain why
   that row is weak, and what would make it lawful. (10 min)

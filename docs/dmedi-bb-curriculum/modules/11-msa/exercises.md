# Module 11 Exercises

Every numeric answer must re-derive from the raw CSVs (`data/gage-rr-bore.csv`,
`data/attribute-inspectors.csv`) via `python3 keys/gage_rr_key.py` and
`python3 keys/attribute_key.py` (each exit 0). Show derivations; the keys are
the exit-checked authorities — this file only points at the labs and keys.

**E1.** Crossed Gage R&R re-derivation (ANOVA method) per
`labs/gage-rr-anova.md`: from the 90-row (10 parts x 3 appraisers x 3 trials)
`data/gage-rr-bore.csv`, build the SS decomposition (SS_part, SS_appraiser,
SS_interaction, SS_error) and confirm EV + AV + interaction compose %GRR =
**13.97%** of study variation. At K = 5.15 (AIAG 99% spread), show that the
multiplier cancels in every %Study Var ratio — what would change if you
re-ran with K = 6.0?

**E2.** Verdict with consequences: %GRR = 13.97% lands in the 10–30%
"marginal" band and ndc = 9 ≥ 5 (key output). Write the verdict sentence the
running case requires: acceptable for process analysis (baseline Cpk, DOE
response measurement), NOT acceptable for part acceptance against the
±0.025 mm spec or tight SPC. Why is "marginal" a verdict with a scope, not a
pass?

**E3.** ndc = 9: derive ndc = 1.41 x (PV / GRR) from the key's variance
components and confirm 9 ≥ 5. A teammate proposes that ndc 9 means "the gage
can resolve 9 spec limits across the ±0.025 mm tolerance." Explain what ndc
actually counts (distinct process-spread categories, not tolerance slices),
and why the two readings diverge when %GRR is computed against study
variation rather than tolerance.

**E4.** Attribute agreement from `labs/attribute-agreement.md` and
`keys/attribute_key.py`: re-derive Cohen's kappa and classify each
misclassification as false accept vs false reject. Which error class is more
expensive in the running case (a bad bore shipped vs a good bore scrapped),
and how would each appear downstream in Module 12's capability study?

**E5.** Cross-module coherence: RUNNING-CASE pins baseline Cpk = 0.72 with
mu = 12.009 mm and sigma = 7.407 um (adjudicated 2026-11-04). Show that
(12.025 − 12.009)/(3 x 0.007407 mm) = 0.72 exactly, and that the stale
4.17 um pair computes Cpk 1.28. Why does the Module 12 court FAIL LOUDLY if
sigma = 4.17 um returns anywhere in the chain?

**E6.** Order law: state the MSA-before-everything rule as it applies to
Module 12 (stability second, capability third) and Module 29 (DOE response
measurement). If %GRR had been > 30%, which downstream module numbers would
be fiction, and which lab would you re-run first?

# Module 25 Slides Outline — Multi-Vari Charts and Variance Components

Case thread: CPPC bore deviation (um), spine sigma regime 7.407 um.
Data: `data/multivari-bore.csv`, n=45 (5 pcs x 3 spindles x 3 time blocks), seed 42501.

## S1. Three families of variation
- POSITIONAL (within-part / location in fixture): pc PC1..PC5.
- CYCLICAL (machine-to-machine): spindle S1..S3.
- TEMPORAL (shift-to-shift / time): blocks T1..T3.
- Multi-vari question: which family owns the variation? You cannot fix all three
  at once; you attack the dominant one.

## S2. The multi-vari chart
- Plot each family's level means with the observations dotted around them.
- Signature reading: parallel drifting bands = positional; sawtooth = cyclical;
  step/shift = temporal. ASCII family chart in the key output (PC1 -1.38 um ->
  PC5 18.42 um, a 19.79 um staircase vs within-cell s = 2.62 um).

## S3. Grand totals (centered TSS law)
- Grand mean 8.6198 um; SST = SUM((y - ybar)^2) = 2518.5487; total s = 7.5657 um
  — right in the running-case 7.407 um regime.
- TSS witness: uncentered SUM(y^2) = 5862.074 is NOT SST (same bug class as
  Modules 23-24).

## S4. One-way ANOVA per family
For each family: SSB = SUM(m_l (ybar_l - gm)^2), SSW = SUM((y - ybar_l)^2),
MSB = SSB/(a-1), MSW = SSW/(n-a), F = MSB/MSW, eta^2 = SSB/SST.
- Positional: SSB 2243.543 (df 4), SSW 275.005 (df 40), F = 81.58,
  eta^2 = 0.8908 -> 89.1% of SST.
- Cyclical (spindle): SSB 9.327 (df 2), F = 0.08 -> noise.
- Temporal (time block): SSB 13.972 (df 2), F = 0.12 -> noise.

## S5. Classical variance components
- sigma2_within = MSW; sigma2_family = (MSB - MSW)/m with m = obs per level.
- Positional: sigma2_family = (560.886 - 6.875)/9 = 61.557; sigma2_within = 6.875;
  family share = 61.557/(61.557+6.875) = 90.0%.
- Spindle/temporal components clamp at 0 (MSB < MSW): the estimator is floored,
  a honest "no measurable family effect".

## S6. The concentration decision
- Rule: attack the family with the dominant share. Here: positional, 90%.
- Falsifier discipline: a multi-vari that shows no dominant family (>60/40 split)
  sends you back to measurement-system analysis (Module 11) or more families.
- Cp/Cpk link: removing a 61.6 um^2 positional component from the spine variance
  (57.2 um^2 observed here) is precisely the kind of reduction that moves
  Cpk 0.72 -> the 1.33 target.

## S7. Sample-size and design honesty
- 45 obs is a screening sample; the floor at 0 for small components and the wide
  CI on shares are disclosed, not hidden. Nested designs (part-in-spindle) come
  with the Gage R&R crossed/nested ANOVA of Module 11.

## S8. Bridge
- The positional signature names the suspect (fixturing/locator wear); the next
  module's tools (DOE, Modules 30+) isolate the cause experimentally.

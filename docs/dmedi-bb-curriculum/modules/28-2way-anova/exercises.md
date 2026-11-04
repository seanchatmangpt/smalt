# Module 28 Exercises

Every numeric answer must re-derive from `data/anova-2way.csv` (column
`bore_deviation_mm`) via `python3 court.py` (exit 0; `--mutate` must exit 1).
Show derivations; the court (33 checks) is the exit-checked authority — this
file only points at the lab and the court's pinned constants.

**E1.** Rebuild the full ANOVA table from the raw 3 x 2 x 6 CSV: SSA =
0.000038 mm² (df 2), SSB = 0.000040 mm² (df 1), SS_AB = 0.000484 mm² (df 2),
SSE = 0.000124 mm² (df 30), SST = 0.000686 mm² (df 35), with exact closure
SSA+SSB+SSAB+SSE = SST (court `closure_1e-9`). Compute F_A = 4.63, F_B = 9.61,
F_AB = 58.63 and confirm against the court pins.

**E2.** Interaction first: F_AB = 58.63 >> F crit 3.32 (p = 4.3e-11, court
`interaction_first_FAB_gt_crit`). Explain why a coating decision read from the
main effect alone (F_B = 9.61, "coating helps") would be wrong for one machine
in three — use the cell means: coated +6.5/+6.2/+16.2 um vs uncoated
+14.1/+13.1/+7.9 um on M1/M2/M3; the lines cross between M2 and M3.

**E3.** SSE two ways: compute SSE directly within cells (sum of 36 squared
residuals about the 6 cell means, df 30) and by subtraction
SST − SSA − SSB − SS_AB; both give 0.000123893 mm², difference < 1e-9 mm².
Why does the equivalence hold only for balanced designs, and what does the
court's closure check guard against if a row were deleted from the CSV?

**E4.** Units discipline (per D41): the CSV carries `bore_deviation_mm`, so
SSE = 0.000124 mm² and sigma-hat = sqrt(MS_E) = 2.032 um — the court
re-derives the whole table in um and requires identical F ratios (unit-change
invariance). Show why F ratios are invariant under a linear rescale, and why
the variance units (mm⁴/um⁴ mismatch if mixed) make reporting "MS = 4.13e-6"
without units meaningless.

**E5.** Simple effects at df 30: SE = sqrt(2 x MS_E/n) = sqrt(2 x 4.130e-6/6)
mm = **1.173 um**, t crit(0.025, 30) = 2.042. Test the coating difference at
M3 (coated − uncoated = +8.3 um): t = 8.3/1.173 = 7.08 >> 2.042. Now test M1
(−7.6 um). Which machines get coating, which do not — and why does this answer
not follow from the main-effect sign?

**E6.** Staleness sweep: the court refuses the adjudicated-STALE 4.17 um spine
sigma (same adjudication as Modules 11/12). Note the collision hazard: 4.17 is
ALSO the F crit for B at df (1, 30) in the F-table. Explain why the court
checks context (a variance scale vs an F-table entry) rather than a bare
string match, and what a bare grep-based gate would have wrongly refused here.

**E6b.** (Court-authoring) Add one check to `court.py` that fails loudly if
the CSV grows an unbalanced cell (n ≠ 6 anywhere). Explain why balance is
checked structurally (court `balanced_n6_every_cell`) rather than trusting
"3 x 2 x 6 = 36 rows" as a row count alone.

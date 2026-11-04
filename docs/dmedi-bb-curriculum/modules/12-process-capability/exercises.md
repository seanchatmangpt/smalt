# Module 12 Exercises

Every numeric answer must re-derive from
`data/cpk072-bore-subgroups.csv` (and `data/flatness-lognormal.csv` for E6) via
`python3 court.py` (exit 0; `--mutate` must exit 1). Show derivations; the
court is the exit-checked authority — this file only points at the labs and
the court's pinned constants.

**E1.** Spine re-derivation: from the 25 x 4 subgroups compute grand mean
**12.0090 mm**, R̄, σ_within = R̄/d₂ = **7.407 um** (d₂ = 2.059 for n = 4),
and confirm Cpk = min(12.025 − 12.009, 12.009 − 11.975)/(3 x 0.007407) =
**0.72** (court `Cpk_0.72`). Also compute Cp = 1.12, Pp = 1.32, Ppk = 0.84
and explain the Cp > Cpk gap (centering) vs the Cp > Pp gap (within-vs-overall
sigma).

**E2.** Control limits from the same raw data: UCL_x = X̄̄ + A₂R̄ =
**12.0201 mm**, LCL_x = **11.9979 mm**, UCL_R = D₄R̄ = **0.0348 mm**
(courts `UCLx`, `LCLx`, `UCLr`). Verify no subgroup mean or range violates
the limits (courts `ooc_x`/`ooc_r` empty). Why must the stability check
precede the capability interpretation — what would Cpk = 0.72 have meant if
subgroup 17's mean sat outside the limits?

**E3.** Staleness sweep: the ORIGINAL spine sigma 4.17 um computes
0.016/(3 x 0.00417) = 1.28, not 0.72 — it was adjudicated stale
(RUNNING-CASE.md, 2026-11-04). Show the arithmetic and explain why the court
refuses it: which two facts (coherence + deliberate-pin) make re-introducing
4.17 um a coherence break rather than an alternative reading?

**E4.** PPM from Z: Z.usl = (12.025 − 12.009)/0.007407 ≈ 2.16, so estimated
PPM > USL (within, normal) ≈ 15,400 PPM. Reconcile against the centered-normal
defect rate 2 x Phi(−2.16) = 3.077% from Module 07 — why does the one-sided Z
estimate halve the two-sided rate, and when is the halving wrong (off-center
process)?

**E5.** Transformation verdict flip: the flatness data (`data/flatness-lognormal.csv`)
fails Shapiro raw, passes after Box-Cox, and the capability verdict FLIPS
under the transformation (court check 3). Write the before/after verdict
sentences and explain what reporting the raw-data Cpk would have told a
customer — and why reporting the transformed Cpk with the lambda used is the
lawful form.

**E6.** Order law recap: MSA verdict (Module 11, %GRR 13.97% marginal) →
stability (E2) → capability (E1). A vendor reports "Cpk 1.67, stable" on the
bore without a gage R&R. Using E1/E2 constants, state which of the three
preconditions is unverified and what the court's mutation test
(`--mutate` must exit 1) guarantees about the remaining two.

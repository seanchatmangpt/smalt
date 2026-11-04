# Lane 09 Court Receipt — 2026-11-04

Subject: modules 19-22 bundles (README + key + datasets + decision tree).

Verification ladder: `python3 court.py` (exit 0) — re-derives EVERY statistic
printed in the four modules' README/key files from the raw on-disk CSVs:
bore-30 1-sample t (t=11.197, p=4.78e-12, CI), sigma-known z (9.45 — note
court checks 9.46 within tolerance; exact 9.4527), ci-trap overlap+rejection
(overlap fraction 0.36, t=2.062, p=0.0437, diff-CI excludes 0, plus structural
asserts: CIs must overlap, test must reject), coating pooled/Welch t,
Levene, Bartlett, Mann-Whitney (U=726), paired t (-6.924, p=3.68e-7) with
marginal-overlap assert, ANOVA (F=12.850, SS to 8 dp), 1-prop z (z=6.240,
Wald + Clopper-Pearson CIs), 2-prop z (z=-0.829, p=0.407), chi2 independence
(23.389, df=6, min expected 29.1), chi2 GOF (1.920, df=5, p=0.860), power
derivation (z_a=1.9600, z_b=0.8416, n_raw=5.46, power(6)=0.836, power(5)=0.765).

Court mutations caught during the run: (1) initial court used s/6**.5 instead
of s/sqrt(30) for trap CIs and produced overlap 0.93 — court bug, fixed in
court, data unchanged; (2) nothing else failed; all keys passed first pass.

Decision tree: decision-tree.md — 13 tests, 13 paths, completeness table IS
the check (every test taught in M19-M22 reachable from Q1; every leaf is a
taught test with a CPPC anchor dataset).

Datasets: 9 rows appended to MANIFEST.md (seeds 42190-42197, 42290), owner
lane 09. Standing: ALIVE (court exit 0 witnessed above; scipy 1.17.1,
numpy 2.4.4, python3 on darwin).

## Adjudication re-run — 2026-11-04 (sigma-correction sweep lane)

RUNNING-CASE.md adjudicated the bore baseline to (mu 12.009 mm, sigma 7.407 um,
Cpk 0.72) on 2026-11-04. The power-derivation and sigma-known z sections above
are pre-adjudication and superseded. Re-run after correcting court.py + key.md +
README.md + decision-tree.md to sigma = 7.407 um (same stated constants, seeds
unchanged): `python3 court.py` — exit 0. Updated values: sigma-known z = 5.32
(exact 5.3245), n_raw = 17.22, power(18) = 0.817, power(17) = 0.795. Standing:
ALIVE.

## GAP-3 coverage-closure addendum — 2026-11-04

Lane 19 audit consumed. Tree expanded from 13 to 18 rows: Anderson-Darling
normality (M09/M12, row 10), regression F-test overall + reduced-model
(M23 S7/M24 §6, row 11), two-way ANOVA (M28, row 12), center-point curvature
test (M37, row 12b, reuses the Q4 2-sample t), and the estimation branch
Q1-E (M20 CI twins — M20 already pointed at Q1-E; the branch now exists).
Pre-test/estimation notes added; Q5 model-building branch added to the tree
body. Scope line widened from "modules 19-22" to "taught anywhere".
Prereq-DAG fixes landed: M28 "Module 27 (one-way ANOVA)" -> Module 21 §6 with
bridge paragraph (also in M28's closing pointer); M21 "M28's Tukey" false
pointer removed (M28 teaches no Tukey HSD; wording now says per-contrast CIs,
not family-corrected); M41 RSM and M37 gained explicit prerequisite bridges
(M30/M31 factorial + OLS M23/24 + M37 gate). Terminology: M29 Response term
now defined against RUNNING-CASE CTQ on first use. Numbers unchanged; no key
re-derivation required. Courts re-run: M19 court.py PASSED (all statistics
re-derived); M37 court.py PASSED (0 failures). Standing: ALIVE.

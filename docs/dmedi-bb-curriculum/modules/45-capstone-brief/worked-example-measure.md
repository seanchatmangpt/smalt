# Worked Example — Capstone Phase 2 (Measure, gate week 9), instructor derivation

**Module**: 45-capstone-brief
**Status**: this file closes the registered divergence "45 (b) no worked example with
instructor derivation" (teachability-scorecard-v2.md reconciliation table, row 45). Every
number below is re-derived from raw CSV by executed inline python3; the captured output is
the receipt. Run from the curriculum root:

```
python3 modules/45-capstone-brief/worked-example-measure.md  # NOT a script — the incantations below are per-section
```

This file demonstrates the *derivation discipline* the Measure gate demands, end-to-end:
baseline study plan → MSA %GRR → baseline capability → gate question → verdict → the
honesty law applied when the verdict is NO.

---

## 0. Baseline study plan (sketch)

A Measure phase that collects numbers before defining what each number answers produces a
data dump, not a baseline. The plan (weeks 6–9):

| # | Activity | Dataset | Answers | Feeds |
|---|---|---|---|---|
| 1 | Gage R&R (crossed, 10 parts × 3 appraisers × 3 trials) | `data/gage-rr-bore.csv` | *Can I trust the numbers?* | gate condition 1 |
| 2 | Baseline capability (25 subgroups × n=4) | `data/cpk072-bore-subgroups.csv` | *Are they the numbers?* | gate condition 2 |
| 3 | Stability proof (X-bar/R on the same subgroups) | `data/cpk072-bore-subgroups.csv` | capability admissibility | gate condition 2 |
| 4 | QFD house of quality (VOC → engineering characteristics) | Module 04/05 method | which characteristics move value | Explore |
| 5 | COPQ from baseline DPMO | baseline DPMO (from #2) | cost of the gap | charter MGPP |

The study plan is sketched before week 6; weeks 6–8 collect, week 9 the gate reviews the
derivation chain, not a summary of conclusions.

## 1. MSA — crossed gage R&R, ANOVA method

**Method**: ANOVA gage R&R per Module 11, computed from `data/gage-rr-bore.csv`. The design
is the Module 11 lab design: 10 parts, 3 appraisers (A/B/C), 3 trials, 90 rows. The
multiplier K = 5.15 (AIAG 99% spread) cancels in every %Study Var ratio, so the band
verdict is K-independent.

Incantation (executed, exit 0 — captured output below):

```
python3 modules/11-msa/keys/gage_rr_key.py; echo RC=$?
```

Captured output (this file's receipt for step 1):

```
GAGE-RR KEY (re-derived from data/gage-rr-bore.csv, seed 411)
  grand_mean_mm = 11.9993
  MS_part = 0.0023436
  MS_appr = 2.94e-05
  MS_int = 3.3e-06
  MS_e = 4.3e-06
  F_part = 717.64
  F_appr = 9.01
  EV_um = 10.684
  AV_um = 4.81
  GRR_um = 11.717
  PV_um = 83.047
  TV_um = 83.87
  pctEV = 12.74
  pctAV = 5.73
  pctGRR = 13.97
  pctPV = 99.02
  ndc = 9
  sigma_repeat_mm = 0.00207
  sigma_reprod_mm = 0.00093
  sigma_grr_mm = 0.00228
  sigma_part_mm = 0.01613
  sigma_total_mm = 0.01629
  verdict = %GRR in 10-30%: acceptable for process analysis,
             not acceptable for SPC on a 50 um tolerance; ndc >= 5.
RC=0
```

**Derivation, shown**: with the CSV's 90 rows (10×3×3), the ANOVA decomposition
SS_total = SS_part + SS_appraiser + SS_part×appraiser + SS_error partitions total variance
into part-to-part, appraiser (reproducibility), their interaction, and repeatability. Then
GRR = √(var_e + var_int + var_av) × 5.15 = 11.717 µm; part variation PV = 83.047 µm;
total TV = 83.870 µm. %GRR = 100 × 11.717 / 83.870 = **13.97%**; ndc = 1.41 × σ_part/σ_grr
= **9**.

**Band logic applied to the computed value** (the gate reject condition is quoting %GRR
without bands): 13.97% falls in the 10–30% band → the measurement system is **conditionally
acceptable**: adequate for process analysis and for the baseline study, NOT adequate for
SPC on the 50 µm tolerance without improvement. ndc = 9 ≥ 5, so the gage can distinguish
enough distinct groups for the baseline. Documented action per the workbook (§2.1): the
baseline is admissible, but the control plan (week 21+) must either upgrade the gage or use
gage-adequate sampling before charting on it.

## 2. Baseline capability — Cpk re-derived from the raw subgroups

**Dataset**: `data/cpk072-bore-subgroups.csv` — 25 subgroups × n=4. Constants: LSL 11.975,
USL 12.025 (spec 12.000 ± 0.025 mm).

Incantation shape (the full expression is the receipt below — this exact heredoc was
executed and exited 0):

```python
import csv, math
rows = list(csv.DictReader(open("data/cpk072-bore-subgroups.csv")))
vals = [float(v) for r in rows for v in (r["obs1"], r["obs2"], r["obs3"], r["obs4"])]
xbar = [sum(float(v) for v in (r["obs1"], r["obs2"], r["obs3"], r["obs4"]))/4 for r in rows]
R    = [max(...) - min(...) over the 4 obs per subgroup]
mu = sum(vals)/len(vals); Rbar = sum(R)/len(R)
sigma_w = Rbar/2.059          # d2 for n=4
Cp  = (USL-LSL)/(6*sigma_w)   # USL 12.025, LSL 11.975
Cpk = min(USL-mu, mu-LSL)/(3*sigma_w)
```

Full executed derivation (verbatim captured output, RC=0):

```
subgroups=25 n/subgroup=4  grand_mean=12.0090 mm  Rbar=0.01525 mm
sigma_within = Rbar/d2 = 0.01525/2.059 = 0.007407 mm = 7.407 um
Cp = 0.050/(6*0.007407) = 1.12
Cpk = min(12.025-12.0090, 12.0090-11.975)/(3*0.007407) = 0.7199
Cpk exact-pins check: (12.025-12.009)/(3*0.007407) = 0.7200
Cpk rounded = 0.72  target 1.33 -> NO — gate fails
stability: UCL_xbar=12.0201 LCL_xbar=11.9979 (A2=0.729, n=4)
out-of-control subgroups (Xbar/R limits): none -> baseline stable, capability admissible
```

**Shown arithmetic, step by step**:

1. Grand mean μ = 12.0090 mm (matches the RUNNING-CASE pinned μ = 12.009 mm).
2. R̄ = 0.01525 mm over 25 subgroups of n=4.
3. σ_within = R̄/d₂ = 0.01525 / 2.059 = **0.007407 mm = 7.407 µm** — the raw re-derivation
   independently reproduces the adjudicated pair (RUNNING-CASE, 2026-11-04); no constant is
   inherited.
4. Cp = (USL − LSL)/(6σ) = 0.050/(6 × 0.007407) = **1.12**.
5. Cpk = min(USL − μ, μ − LSL)/(3σ) = (12.025 − 12.009)/(3 × 0.007407) = **0.7199 ≈ 0.72**
   (exact-pins check with the pinned constants: (12.025 − 12.009)/(3 × 0.007407) = 0.7200).
   The spread is the constraint, not centering alone — Cp 1.12 says the process spread fits
   the tolerance width only 1.12 times over, and μ = 12.009 sits +9 µm off nominal with the
   USL side eating the margin (that off-center is why Cpk 0.72 while Cp 1.12).
6. Stability: X̄-chart limits μ ± A₂R̄ = 12.0201 / 11.9979 (A₂ = 0.729 at n=4); no subgroup
   plots outside limits → baseline stable → the capability number is admissible.
7. Adjudication stated: the original spine pair (σ = 4.17 µm) computed Cpk ≈ 1.28 and was
   ruled stale on 2026-11-04; the raw-CSV re-derivation independently lands on σ = 7.407 µm,
   confirming the adjudicated pair. Stated here per brief §2.1 (silent inheritance of
   4.17 µm is a Measure-gate reject).

## 3. The gate question, answered

*"Can I trust the numbers, and are they the numbers?"*

- **Can I trust the numbers?** Conditionally. %GRR = 13.97% (10–30% band): acceptable for
  this baseline study, marginal for SPC on a 50 µm tolerance; ndc = 9 ≥ 5. Verdict:
  measurement system adequate for the baseline, with a documented gage-improvement action
  carried to the control plan.
- **Are they the numbers?** Yes, provably: Cpk = 0.72 re-derives from the raw subgroups
  (σ_within = 7.407 µm, μ = 12.009 mm) — the exact adjudicated RUNNING-CASE pair — from data
  that is demonstrably stable (no X̄/R violations). No number in this phase was remembered;
  every number has a replay command.

## 4. Verdict vs target: NO — and what the gate does about it

- Verdict vs Cpk target 1.33: **0.72 < 1.33 → the capability condition FAILS**. This is the
  lawful outcome, not a program failure: the Measure gate's job is to certify that the
  baseline is measured *honestly*, not that it is good. The gate question is answered
  (numbers trustworthy, numbers are the numbers); the capability result is exactly the gap
  the charter was written to close. **The gate passes on evidence discipline and the
  program continues to Develop** (via Explore) with baseline Cpk = 0.72 as the certified
  starting point and the charter's Cpk ≥ 1.33 target unchanged.
- What a RESUBMIT would have meant instead: if %GRR had exceeded 30% or the subgroups were
  not stable, the baseline would be inadmissible and the gate would return RESUBMIT — fix
  the gage or remove the special cause before interpreting capability. Neither holds here.

## 5. Honesty-law demonstration

The honesty law (brief §2): a phase that did not happen is reported as not-done, not
narrated as done. Applied to this worked example, three concrete demonstrations:

1. **A NO is reported as a NO.** The capability result (0.72 vs 1.33) is stated as a
   capability FAIL against target with the number that failed, not softened to "approaching
   target" or "improving". The program continues *because* the failure is lawful — the
   baseline is the input to Develop, not the deliverable of Measure.
2. **Conditional verdicts stay conditional.** The MSA verdict is recorded as conditional
   (10–30% band) with its documented action — not narrated as a pass. A later phase that
   charts on this gage without the improvement action would be quoting a measurement
   system its own baseline said was marginal for SPC.
3. **Every number carries its replay.** %GRR = 13.97% and Cpk = 0.72 each name the CSV,
   the method, and the executed command above; the §2.1 adjudication is stated, not
   silently inherited. An honest NOT MET (e.g. a real student's COPQ section whose DPMO
   input did not re-derive) scores better than an unreceipted claim — per the workbook's
   own contract.

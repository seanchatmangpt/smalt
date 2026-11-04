# Module 11 — Measurement System Analysis (MSA)

**DMEDI phase**: Measure · **Runtime**: 4 h · **Prerequisites**: Module 10 (control charts)

## Why MSA comes before everything else in Measure

Every number you will ever compute about a process — Cpk, control limits, DOE
effects, PPM — is computed from measurements. If the measurement system itself
consumes most of the tolerance, the numbers describe the gage, not the part.
Rule: **no capability study, control chart, or DOE is interpreted before the
measurement system passes.** In the running case, the SR-71 gimbal bore
(12.000 mm ± 0.025 mm) must be measured by a gage whose error is small enough
that a Cpk improvement measured next week is attributable to the process, not
the micrometer.

## Learning objectives

1. Run a **crossed Gage R&R (ANOVA method)** and decompose observed variation
   into repeatability (EV), reproducibility (AV), part-to-part (PV), and total (TV).
2. Read the **%Study Var** acceptance table and state a verdict with consequences.
3. Derive and interpret **ndc** (number of distinct categories).
4. Run an **attribute agreement analysis** with Cohen's kappa and classify
   misclassification errors (false accept vs false reject).

## Labs

| lab | dataset | key |
|---|---|---|
| [Gage R&R, crossed, ANOVA method](labs/gage-rr-anova.md) | `data/gage-rr-bore.csv` | `keys/gage_rr_key.py` |
| [Attribute agreement analysis](labs/attribute-agreement.md) | `data/attribute-inspectors.csv` | `keys/attribute_key.py` |

Dataset provenance: `datasets/MANIFEST.md` (seeds 411, 713). Keys re-derive
every figure from the raw CSV and exit-checked (exit 0 = verified).

## Acceptance thresholds table (memorize)

| %GRR (of study var) | verdict | consequence |
|---|---|---|
| < 10% | acceptable | gage system fine for any use |
| 10–30% | marginal — may be acceptable | acceptable for process analysis / DOE on this tolerance; NOT acceptable for SPC on a tight tolerance or part acceptance against spec |
| > 30% | unacceptable | fix the gage first: no data usable |
| ndc < 5 | insufficient resolution | cannot stratify the process; increase trials/parts or use a finer gage |

Note AIAG MSA 4th ed. uses a 6-sigma spread (5.15 was the 3rd-ed. 99% spread);
all %Study Var **ratios are identical** because the multiplier cancels.

## The interpretation verdict for the bore gage (the teaching case)

The crossed Gage R&R on `data/gage-rr-bore.csv` re-derives
**%GRR = 13.97%** and **ndc = 9**: inside the 10–30% band. Verdict stated:
*the gage is acceptable for process-analysis work in the Measure phase
(baseline Cpk, DOE response measurement), but it is NOT acceptable for
accepting parts against the ±0.025 mm spec or for tight SPC — a gage
improvement is an action item before the Analyze gate.*

## Cross-module coherence note (do not skip)

RUNNING-CASE pins baseline Cpk = 0.72 with mu = 12.009 mm and, since the
2026-11-04 adjudication, sigma = 7.407 um ((12.025 − 12.009)/(3 × 0.007407) =
0.72 exactly). The original spine's sigma = 4.17 um pair computed Cpk 1.28 and
was adjudicated stale; `MANIFEST.md` carries the record. Downstream modules
treat *Cpk = 0.72, sigma = 7.407 um* as the coherent pair.

## Timing (per activity)

- Crossed Gage R&R lab (`labs/gage-rr-anova.md`, Steps 0-6) (90 min)
- Attribute agreement lab (`labs/attribute-agreement.md`) (45 min)
- Key runs + court exits: `court.py` (independent %GRR/ndc re-derivation + `keys/gage_rr_key.py` agreement), `keys/gage_rr_key.py`, `keys/attribute_key.py` (10 min)
- Acceptance-table drill + verdict writing (25 min)
- Cross-module coherence discussion (spine sigma adjudication) (10 min)

Total: 4 h, matching the Runtime header.

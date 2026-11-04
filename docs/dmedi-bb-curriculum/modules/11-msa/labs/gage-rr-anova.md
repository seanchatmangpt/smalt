# Lab — Crossed Gage R&R, ANOVA method (bore diameter)

Dataset: `data/gage-rr-bore.csv` — 10 parts × 3 appraisers (A, B, C) × 3 trials
= 90 measurements of the SR-71 gimbal bore, mm. Seed 411 (numpy
`default_rng(411)`). Key: `python3 modules/11-msa/keys/gage_rr_key.py`.

## Step 0 — eyeball the design

It is *crossed* because every appraiser measures every part — as opposed to
*nested* (each part measured by only one appraiser, e.g. across shifts/plants).
Balanced design: every part-appraiser cell has exactly 3 trials.

## Step 1 — means

- Grand mean = **11.9993 mm**
- Part means range 11.97–12.02 (this spread is the *signal* the gage must see)

## Step 2 — two-way crossed ANOVA (part + appraiser + interaction)

With part (p = 10), appraiser (a = 3), trial (n = 3), N = 90:

| source | SS formula | df | MS | F |
|---|---|---|---|---|
| Part | `10·Σ(part mean − grand)²` — n·a per level | 9 | **0.0023436** | F = MS_part/MS_int = **717.64** |
| Appraiser | `30·Σ(appr mean − grand)²` | 2 | **0.0000294** | F = MS_appr/MS_int = **9.01** |
| Part×Appraiser | `3·Σ(cell − part − appr + grand)²` | 18 | **0.0000033** | (vs MS_e) |
| Repeatability (error) | remainder | 60 | **0.0000043** | |

The key script computes all of these directly from the residual identity
`SS_total − SS_part − SS_appr − SS_int` — no shortcut.

## Step 3 — variance components (AIAG rules, negative components clipped to 0)

| component | rule | value (mm²) | σ (mm) |
|---|---|---|---|
| Repeatability (equipment) | `MS_e` | 4.31e-06 | 0.00207 |
| Appraiser (AV) | `(MS_appr − MS_int)/(n_parts·n_trials)` | 8.69e-07 | combined with interaction below |
| Interaction | `(MS_int − MS_e)/n_trials` | — | |
| **Reproducibility (AV)** | √(var_av + var_int) | | **0.00093** |
| **GRR** | √(EV² + AV²) | | **0.00228** |
| **Part-to-part (PV)** | `(MS_part − MS_int)/(n_appr·n_trials)` | | **0.01613** |
| **Total (TV)** | √(GRR² + PV²) | | **0.01629** |

## Step 4 — %Study Var (5.15σ convention; ratio identical under 6σ)

| index | σ × 5.15 (um) | % of TV |
|---|---|---|
| EV (repeatability) | **10.684** | **12.74%** |
| AV (reproducibility) | **4.810** | **5.73%** |
| **%GRR** | **11.717** | **13.97%** |
| PV (part-to-part) | **83.047** | **99.02%** |
| TV | **83.870** | 100% |

Reading: part-to-part variation dominates (99%) — the gage *can* see real
differences between parts. The 13.97% %GRR is entirely repeatability-driven
(EV ≫ AV): appraiser technique differences are small; the residual error is
inherent gage noise.

## Step 5 — ndc

`ndc = floor(1.41 × σ_part / σ_grr) = floor(1.41 × 0.01613/0.00228) = 9`

9 distinct categories ≥ 5 → resolution sufficient to stratify the process.

## Step 6 — verdict (state it, with consequences)

- %GRR = 13.97% → **10–30% marginal band**: acceptable for process analysis
  and DOE response measurement; not acceptable for part acceptance or tight
  SPC on this ±0.025 mm tolerance. Action item: improve the gage (or
  averaging strategy) before Analyze.
- ndc = 9 → resolution OK.
- F_appr = 9.01 (vs MS_int) is statistically significant — small but real
  appraiser differences; a retraining check on appraiser B (+1.1 um bias).

## Tolerance-vs-study-var: the second acceptance lens

%GRR may also be computed against the **tolerance** (here 50 um):
11.717/50 = **23.4%** of tolerance — marginal again, same verdict, and the
reason the "not for part acceptance" clause is load-bearing.

## Court

```bash
python3 modules/11-msa/keys/gage_rr_key.py   # must exit 0, prints all keys
```

# Module 09 — Basic Statistics: Descriptives, Distribution Gallery, and the CLT

Case: CPPC bore diameter baseline (`data/bore-baseline-100.csv`, seed 42008).
Prerequisite: Module 08 (you can import a CSV and run Describe).

## Learning objectives

- Choose and defend a location/dispersion statistic (mean vs median, s vs IQR).
- Recognize the normal distribution and when NOT to use it.
- State and *numerically demonstrate* the Central Limit Theorem:
  sigma_xbar = sigma / sqrt(n).

## 1. Descriptive statistics that matter

From Module 08's Describe output (re-derived in `solution-key.md`):

| statistic | value | use it for |
|---|---|---|
| mean | 12.0098 mm | process center when data are symmetric/clean |
| median | 12.00995 mm | center when outliers skew the mean |
| StDev s | 0.0074 mm | dispersion for capability math (n-1 denominator) |
| Q1 / Q3 / IQR | 12.0059 / 12.0146 / 0.0087 mm | robust spread; outlier fence |
| min / max | 11.9849 / 12.0293 mm | range checks, spec proximity |

Median ≈ mean here (12.00995 vs 12.009815) → distribution is symmetric, mean is a
lawful center statistic. Outlier fence (Tukey): 12.0059 − 1.5×0.0087 = 11.9928 and
12.0146 + 1.5×0.0087 = 12.0277. Four bores (11.9849, 11.9907, 11.9909, 12.0293)
fall outside the fence — investigate, don't delete: three are legal low tails, and
12.0293 is ALSO past USL — the one scrap part that makes the Cpk-0.72 baseline
visible, not a data error.

## 2. The distribution gallery (Stat > Probability Distributions)

Minitab's gallery you will actually use in this course:

| distribution | Minitab path | CPPC use |
|---|---|---|
| Normal | Calc > Probability Distributions > Normal | bore diameter, dimensions |
| Binomial | ... > Binomial | # late orders out of n (Module 10 p-charts) |
| Poisson | ... > Poisson | defects per unit when opportunities are large (u-charts) |
| Exponential / Weibull | ... | time-between-failures, MTBF (Module 14) |
| t / Chi-square / F | ... | confidence intervals, variance tests (Module 05) |

Worked probe: what fraction of a **centered** bore process with the baseline spread
(s = 0.0074 mm) would fall below LSL? Calc > Probability Distributions > Normal > Cumulative
probability, x = 11.975, Mean = 12.000, SD = 0.0074. Minitab returns 3.65e-4.
Shifting the mean to the measured 12.0098 moves the LSL to 4.7 s away and the same
query returns 1.3e-6 — but the USL tail grows to 2.01e-2 (the binding side; the mean
moved toward it). Centering rebalances the tails, but at this spread the centered
process still loses ~7.5e-4 from spread alone: centering AND variation reduction are
both required. The python3 mirror (`norm.cdf`) is in the key.

Normality check on the baseline: Stat > Basic Statistics > Normality Test
(Anderson-Darling). The p-value for this sample is > 0.05 and the points hug the
line — a normal model is defensible, which is exactly what license the CLT and the
control charts in Module 10 need.

## 3. The Central Limit Theorem, made numerical

Theory: if X has mean mu and sd sigma, the sampling distribution of xbar over n
observations has mean mu and **sd = sigma/sqrt(n)**.

**Exercise (the lab).** From the baseline process (mu = 12.009 mm, sigma = 0.007407
mm = 7.407 um, adjudicated 2026-11-04 — see RUNNING-CASE.md), take n = 5 bores, average them, repeat 1000 times. Plot a histogram
of the 1000 averages and compute their sd. Predict first: sigma_xbar = 7.407/sqrt(5)
= **3.31 um**. Then simulate (script in `solution-key.md`, seed 42009):

- mean of the 1000 means: 12.0089 mm (theory 12.009 — recovered to <1 um)
- sd of the 1000 means: **3.406 um** (theory 3.313 um; 2.8% sampling error, and
  3.386 um (+2.2%) when resampling from the stored CSV itself, seed 42010 — the CSV
  is the same adjudicated-scale data, so both legs agree)
- shape: the histogram of means is narrower and near-normal, even though the
  parent is normal anyway — rerun the lab with a skewed parent (try an exponential)
  and watch the means still pile up normal. That *is* the CLT.

**Why a Black Belt cares:** subgroup averages move less than individuals
(3.31 um vs 7.41 um). That is why an X-bar chart's control limits (Module 10) are
tighter than an I-chart's, and why reacting to a single out-of-spec part when the
subgroup mean is in control is usually reacting to noise.

## 4. Sampling error honesty clause

With 1000 draws, the simulated sd of means will not print 3.313 exactly — it
prints ~3.4. Agreement within ~3% is the pass bar; exact equality of a Monte Carlo
estimate is a red flag, not a goal. Seeds are stated so your run matches the key
digit-for-digit, but the *law* (sigma/sqrt n) is what you carry to the exam.

## 5. Checklist (gate)

- [ ] Descriptives reproduced; mean/median comparison justified
- [ ] Tukey fences computed; the 4 flagged bores dispositioned (kept, explained)
- [ ] Normal gallery probe run for both mean settings
- [ ] CLT simulation executed with stated seed; sd of means ≈ sigma/sqrt(5) ±3%
- [ ] One-sentence answer: why are X-bar limits tighter than I-chart limits?

## Files

- `README.md` — this lesson
- `solution-key.md` — python3 re-derivation: descriptives, normal probes, CLT sim

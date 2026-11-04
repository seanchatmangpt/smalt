# Module 09 — Basic Statistics (Slides Outline)

**Module**: 09-basic-statistics · Case: CPPC bore baseline (`data/bore-baseline-100.csv`, seed 42008)
**Timing**: 2.5 h (slides 50 min, lab 45 min, exercises 30 min, court 5 min)
**Tools**: Minitab gallery + python3 mirror (stdlib only)

---

## Slide 1 — Location and dispersion: pick with a reason (10 min)

- Mean/stdev: efficient under symmetry; the capability math (Cpk, z-scores) is defined
  on them. Median/IQR: robust to outliers; report when tails are suspect.
- On the baseline the two agree (mean 12.00946 vs median 12.00955) → symmetric sample,
  mean is lawful. After Module 12's non-normal case you will not have that luxury
  everywhere.
- Tukey fences on the baseline: Q1 − 1.5·IQR = **11.9928**, Q3 + 1.5·IQR = **12.0277**
  (IQR 0.008725). Four bores fall outside (11.9849, 11.9907, 11.9909, 12.0293); the
  last is also past USL — the sample's one scrap part. Investigate, don't delete.

## Slide 2 — Distribution gallery, decision use (10 min)

| distribution | Minitab path | CPPC use |
|---|---|---|
| Normal | Calc > Probability Distributions > Normal | bore diameter, dimensions |
| Binomial | ... > Binomial | late orders out of n (module 10 p-chart) |
| Poisson | ... > Poisson | defects/unit, opportunities large (u-charts) |
| Exponential / Weibull | ... | time-between-failure, MTBF (module 36) |
| t / chi-square / F | ... | CIs, variance tests (modules 20–22) |

- Worked probe (court-checked): centered process, s = 0.0074 → P(below LSL) =
  **3.65e-4**. Measured mean 12.0098 → P(below LSL) ≈ 1.3e-6 but P(above USL) =
  **2.01e-2**. The binding (USL) tail carries the scrap risk; centering rebalances,
  spread reduction delivers.

## Slide 3 — Normality check (5 min)

- Stat > Basic Statistics > Normality Test (Anderson-Darling) on the baseline: p > 0.05,
  points hug the line. A normal model is defensible — the license the CLT simulation
  and Module 10's charts need.

## Slide 4 — CLT, made numerical (15 min)

- Theory: sd of the sample mean = sigma/sqrt(n). Prediction before simulation:
  7.407/sqrt(5) = **3.313 um**.
- Simulation (seed 42009, 1000 means of n=5 from the baseline process): mean of means
  **12.0089** (theory 12.009), sd of means **3.406 um** (+2.8% — Monte Carlo sampling
  error on 1000 draws, not an error; the honesty clause in the README §4 sets a ±3% bar).
- CSV-resample variant (seed 42010, n=5 with replacement from the stored 100):
  **3.386 um** (CSV leg; the stored CSV is the same adjudicated-scale data).
- Consequence for Module 10: subgroup averages move less than individuals. X-bar limits
  are tighter than I-chart limits *by construction*, same 3-sigma multiple, different sigma.

## Slide 5 — Sampling-error honesty (5 min)

- A Monte Carlo estimate will not print the theory value exactly; agreement within the
  stated bar is the pass. Exact equality is a red flag (seeded bug or peeked answer).
- Seeds are stated so your run matches the key digit-for-digit; the *law*
  (sigma/sqrt n) is what you carry to the exam.

## Lab and assessment

- Lab: `lab.md` (descriptives → Tukey → normal probes → CLT simulation, python3 mirror).
- Exercises 1–8: `exercises.md` (answers in solution-key.md).
- Court: `courts/court.py` (exit 0 = descriptives, fences, probes, CLT all re-derive).

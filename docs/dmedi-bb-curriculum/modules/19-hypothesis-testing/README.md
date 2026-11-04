# Module 19 — Hypothesis Testing

CascadeProjects Precision Components (CPPC) · SR-71 drone-gimbal housing line.
Spine: CTQ-1 bore diameter, spec 12.000 mm ± 0.025 mm; Measure baseline
mu = 12.009 mm, sigma = 7.407 um (adjudicated 2026-11-04; originally listed as 4.17 um — see RUNNING-CASE.md). Secondary dataset: `data/bore-30.csv`
(30 parts off Line 2 after a setup change), seed 42190.

## 1. Why test at all

A sample mean is a guess. A hypothesis test converts the guess into a
decision against a stated null, with a known error rate. Without the stated
null and alpha, "12.006 looks fine" is opinion.

## 2. H0/H1 formulation discipline

Laws (break these and every later conclusion is void):

1. **H0 is the status quo / "nothing changed"** — no shift, no difference,
   no association. It is the hypothesis the data are presumed innocent.
2. **H1 is what you act on.** The burden of proof sits on H1; you reject H0
   only when the data are improbable under it.
3. **State H0/H1 in parameters, not statistics.** H0: mu = 12.000 mm
   (parameter), never H0: x-bar = 12.000 (statistic — the sample mean is
   computed, never hypothesized).
4. **Decide one- vs two-sided BEFORE seeing data**, from the decision you
   would actually make. If a shift in either direction triggers different
   actions (rework vs scrap), the test is two-sided. "We expect it went up"
   stated after peeking is not a license for one-sided.
5. **alpha is set from consequence, not convenience** (see §4).

Worked formulation (bore-30): a setup change was made on Line 2; anything
other than on-target (12.000) requires re-mastering the spindle. So:

- H0: mu = 12.000 mm (process centered on nominal)
- H1: mu != 12.000 mm (two-sided — off-target either way forces action)
- alpha = 0.05, n = 30.

## 3. The four outcomes and what they cost at CPPC

|                | H0 true (on target) | H0 false (off target) |
|---|---|---|
| **Reject H0**  | Type I error, prob = alpha: re-master a good spindle. Cost: ~2 h downtime + $900 lost production per false alarm. | Correct: power = 1 - beta. Re-master, ship safe parts. |
| **Keep H0**    | Correct: prob = 1 - alpha. | Type II error, prob = beta: ship an off-target bore. Cost: escaped nonconformance — customer line-down, chargebacks, containment + 100% inspection across the fleet. |

Type I is cheap and visible; Type II is expensive and invisible (the escape
never announces itself in your data — it announces itself at the customer).
This asymmetry is why sigma-level shifts *and* sample size both matter.

## 4. alpha, beta, power, and the tradeoff

- alpha = P(reject H0 | H0 true). Chosen, not computed. Lowering alpha
  (0.05 → 0.01) moves the rejection fence out, which **raises beta** for the
  same n — you buy false-alarm protection with missed-shift risk.
- beta = P(keep H0 | H0 false). Depends on alpha, n, sigma, and the true
  shift delta: bigger n or bigger delta → smaller beta.
- **Power = 1 - beta** = P(detect a shift of size delta that is really there).

### Power curve — the bore case, derived

Question from the Define gate: *how many parts must we measure to detect a
5 um centering shift (0.005 mm — well inside the ±25 um tolerance, exactly
the kind of silent drift that produced the Measure-phase escapes) with 80%
power at alpha = 0.05, two-sided?*

Normal approximation (sigma = 7.407 um known from Measure):

    n = [ (z_{1-alpha/2} + z_{1-beta}) * sigma / delta ]^2
      = [ (1.9600 + 0.8416) * 7.407 / 5.0 ]^2
      = (2.8016 * 1.4814)^2 = 4.1502^2 = 17.22  →  n = 18

Power curve (probability the two-sided z-test at alpha=0.05 rejects, true
shift 5 um, sigma 7.407 um), computed for n = 2…25:

| n | 2 | 3 | 4 | 5 | 6 | 8 | 10 | 12 | 15 | 18 | 20 | 25 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| power | 0.159 | 0.215 | 0.271 | 0.326 | 0.380 | 0.480 | 0.569 | 0.647 | 0.744 | **0.817** | 0.855 | 0.921 |

Read the curve both ways:

- **n = 18 is the answer** (first n with power >= 0.80). n = 17 (0.795) misses
  the spec'd detection probability one time in five.
- The curve is steep here because 5 um is a modest shift relative to
  sigma = 7.407 um. For a 2 um shift the same curve flattens: n = 50 only
  reaches power 0.480 (see table below). Detecting small drift against a
  tight tolerance is a *sample-size problem*, not a "try harder" problem.

alpha/beta tradeoff at fixed n (two-sided, sigma = 7.407 um):

| shift delta | n=18: power / beta | n=30: power / beta | n=50: power / beta |
|---|---|---|---|
| 2 um | 0.209 / 0.791 | 0.316 / 0.684 | 0.480 / 0.520 |
| 3 um | 0.405 / 0.595 | 0.602 / 0.398 | 0.817 / 0.183 |
| 5 um | 0.817 / 0.183 | 0.959 / 0.041 | 0.998 / 0.002 |

(Mirrors the n=18 conclusion: 5 um @ 80% needs n>=18; the same n=18 plan is
nearly blind — beta = 0.79 — to a 2 um drift. Control plans must size n to
the *smallest shift that matters*, i.e. the shift with real consequence.)

Re-derivation court: `key.md` recomputes every number in this section from
`data/bore-30.csv` and the running-case constants. **Zero values may be
quoted from memory.**

## 5. Worked test — 1-sample t on `data/bore-30.csv`

n = 30, x-bar = 12.0072 mm, s = 0.0035 mm. H0: mu = 12.000, alpha = 0.05
two-sided.

- SE = 0.0035/sqrt(30) = 0.0006 mm
- t = (12.0072 - 12.000)/0.0006 = **11.197**, df = 29
- critical t (0.975, 29) = 2.045; p = 4.78e-12
- **Decision: reject H0.** The Line-2 process is running ~7 um off nominal;
  re-master before release. (Full arithmetic in `key.md`.)

Note what happened: a mean of 12.0072 is 0.0007 mm from nominal at first
glance — "within tolerance, ship it." The test sees what the tolerance
cannot: 7 um is 0.95 sigma of process variation and the sample says with
near-certainty the center moved. Statistical significance and in-spec are
different questions.

## 6. Module close — the decision tree

Every test in this curriculum is reachable from one tree; no test without a
path. After finishing this module you can place the 1-sample t on it.
Go to **[decision-tree.md](decision-tree.md)** — find "1 continuous
response, compare mean to a target" and confirm it lands on the 1-sample t
you just ran.

## 5a. The sigma-known variant (1-sample z)

When sigma comes from the Measure-phase capability study (sigma = 7.407 um,
treated as known, n large), the same H0/H1 machinery runs on

    z = (x-bar - mu0) / (sigma / sqrt(n)),  compare to z_{1-alpha/2} = 1.9600.

For bore-30: z = (12.0072 - 12.000)/(0.007407/sqrt(30)) = 0.0072/0.001352
= **5.32**, p ~ 1e-7 — same decision as the t (as expected; here s = 0.0035
is smaller than the capability sigma, so t is the honest choice and z is the
cross-check). Decision-tree path: Q1-A -> Q2 -> ONE -> Q3(sigma known).

## Learning objectives

By the end of this module you will be able to:

1. Formulate H0/H1 in parameters (not statistics) for a CPPC bore scenario,
   choosing sidedness and alpha from the action consequence **before**
   seeing data — graded against the laws in §2.
2. Compute a 1-sample t statistic, its df, critical value, and p-value by
   hand from `data/bore-30.csv` and state the reject/fail-to-reject
   decision with its CPPC consequence (numbers must match `key.md`).
3. Estimate the sample size required for a stated power (80%) against a
   stated shift (5 um) at alpha = 0.05, and explain the n-vs-power
   tradeoff using the power curve in §4.
4. Distinguish Type I from Type II error in process terms (re-master cost
   vs escaped nonconformance) and state which the CPPC line can afford.
5. Place any one-population mean test on the flagship decision tree
   (decision-tree.md) without notes.

## Session timing

- Concept briefing: why test, H0/H1 discipline, error costs (25 min)
- Power-curve derivation and alpha/beta tradeoff walkthrough (20 min)
- Worked 1-sample t on bore-30, instructor arithmetic visible (15 min)
- Learner exercise: re-run the test as a 1-sample z with sigma known and
  reconcile the two decisions (10 min)
- Decision-tree placement drill, all learners place 3 tests (10 min)

## Tools

Minitab: Stat > Basic Statistics > 1-Sample t (summarized or raw data) for
the worked test; Stat > Power and Sample Size > 1-Sample t to reproduce the
n = 18 result. Python mirror: the exact scipy snippet at the top of
`key.md` (stats.t.ppf / stats.t.cdf) reproduces every table value;
`python3 court.py` exit 0 re-checks the key against the data.

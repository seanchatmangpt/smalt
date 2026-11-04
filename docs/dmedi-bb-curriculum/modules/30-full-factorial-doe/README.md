# Module 30 — Full Factorial DOE: The 2^3 Design

## Learning objectives

After this module the candidate can:

1. Build the Yates-order 2^3 design matrix and verify its orthogonality
   property (each effect column balanced +/-).
2. Compute all 7 effect estimates as orthogonal contrasts
   (effect = 2*sum(x_L * y)/N) by hand-script, and rank them on a half-normal
   plot to separate active from inactive.
3. Derive the effect standard error from replication
   (SE = 2*sigma/sqrt(N) = sqrt(4*MSE/N)) and apply the noise threshold
   +/- t(0.025, df_E) * SE to classify each effect.
4. Fit and read the coded prediction equation, including conditional
   (simple) effects that expose the A x B interaction.
5. Check model adequacy (residual normality, replicate-block shift, constant
   variance) and verify the model with 95% prediction-interval holdout
   corners before using it.

## Module overview

**DMEDI phase:** Develop
**Running case:** CPPC SR-71 gimbal housing bore. Factors: A = spindle speed
(low/high), B = feed rate (low/high), C = coolant concentration (low/high).
Response: bore diameter deviation from 12.000 mm (um). All coded as -1/+1.
**Data:** `data/doe-2k-full.csv` — full 2^3 factorial, 8 corner runs x 2
replicates = 16 observations, replicate-blocked (all reps=1 first, then all
reps=2; the file records run_pattern and coded levels).
**Seeded ground truth (python3, seed 30):** A = +12 um, B = +8 um,
A x B = -6 um, C and other interactions = 0, noise N(0, 1.5^2 um).
**Prerequisites:** Module 28 (two-way ANOVA), Module 29 (terminology).

**Session timing** (4.0 h total): overview + design matrix, §1 (20 min);
effects derivation run by hand, §2 (35 min); SE/t classification, §3
(30 min); half-normal plot construction, §4 (25 min); prediction equation
and conditional effects, §5 (30 min); residuals/adequacy, §6 (25 min);
confirmation/holdout logic, §7 (20 min); exercises §8 checked against
`keys/solution-key.md` (50 min); debrief (15 min).

**Tool note:** Minitab — Stat > DOE > Factorial > Create Factorial Design
(2-level, 3 factors, 2 replicates per corner) then Analyze Factorial Design
(effects Pareto, cube plot, residual plots). python3 mirror — the README §2
and §3 scripts ARE the mirror (stdlib `csv`/`math` against the raw CSV);
`keys/solution-key.md` re-derives every table value.

## 1. The design matrix

Standard Yates order, one sign flip per column as you descend:

```text
 run  A(speed) B(feed) C(coolant)  pattern
  1      -       -       -         ---
  2      -       -       +         --+
  3      -       +       -         -+-
  4      -       +       +         -++
  5      +       -       -         +--
  6      +       -       +         +-+
  7      +       +       -         ++-
  8      +       +       +         +++
```

Each row run twice (rep=1, rep=2) = 16 runs total. Balance property: for every
factor and every interaction column, exactly half the runs are + and half are
- — this orthogonality is what makes each effect an independent estimate.

Concrete settings (example mapping used in this module): speed low/high =
6000/9000 RPM; feed low/high = 250/350 mm/min; coolant low/high = 5/9%.

## 2. Computing the effects (hand-shown python3)

With coded columns x_A, x_B, x_C in {-1, +1}, every effect is a single
orthogonal contrast:

```text
 effect(L) = 2 * sum( x_L * y ) / N
```

where x_L is the product of the coded columns named in L (A means x_A; AB
means x_A*x_B) and N = 16. The factor of 2 converts half-range to full-range:
the contrast averages (+) runs minus (-) runs, each standing for N/2
observations.

```python
import csv, math
rows = list(csv.DictReader(open("data/doe-2k-full.csv")))
runs = [(r["run_pattern"], int(r["speed_A"]), int(r["feed_B"]),
         int(r["coolant_C"]), float(r["bore_deviation_um"])) for r in rows]
N = len(runs); ybar = sum(r[4] for r in runs)/N

def effect(labs):
    return 2*sum(math.prod([r[i] for i in labs])*r[4] for r in runs)/N

for labs, name in [([1], "A"), ([2], "B"), ([3], "C"), ([1, 2], "AB"),
                   ([1, 3], "AC"), ([2, 3], "BC"), ([1, 2, 3], "ABC")]:
    print(name, round(effect(labs), 3))
```

### Derived effects (um)

| Effect | Estimate (um) | vs planted |
|---|---|---|
| A (speed) | **+11.81** | +12 |
| B (feed) | **+9.07** | +8 |
| C (coolant) | -0.28 | 0 |
| AB | **-6.69** | -6 |
| AC | +1.60 | 0 |
| BC | -0.40 | 0 |
| ABC | +1.03 | 0 |
| Grand mean | 10.79 | 10 |

## 3. Is an effect real? SE and t

Replication gives the error term. Within-corner SS:

```python
tot = {}
for r in runs: tot[r[0]] = tot.get(r[0], 0) + r[4]
SSE = sum((r[4] - tot[r[0]]/2)**2 for r in runs)   # 16 obs, 8 corners
```

Derived: SSE = 13.688, df_E = 16 - 8 = 8, MSE = 1.711, sigma-hat = 1.308 um
(planted 1.5 — honest). In a 2^k design with n replicates,
SE(effect) = 2*sigma/sqrt(N) = sqrt(4*MSE/N) = 0.654 um. t crit
(0.025, df 8) = 2.306, so the noise threshold for an effect is
+/- 2.306 * 0.654 = **+/- 1.51 um**.

| Effect | Estimate | t | p | Verdict |
|---|---|---|---|---|
| A | +11.81 | +18.06 | 9.1e-08 | active |
| B | +9.07 | +13.87 | 7.1e-07 | active |
| C | -0.28 | -0.43 | 0.68 | inactive |
| AB | -6.69 | -10.22 | 7.2e-06 | active |
| AC | +1.60 | +2.44 | 0.041 | borderline |
| BC | -0.40 | -0.62 | 0.55 | inactive |
| ABC | +1.03 | +1.58 | 0.15 | inactive |

AC is a teaching case: t = 2.44 clears 2.306 at exactly p = 0.041. With 7
effects tested, one borderline hit at p~0.04 is what chance produces; the
half-normal plot (next section) shows AC sitting barely off the error line.
Treatment: flag it, do not promote it to the model without a confirmation run
that specifically resolves it.

## 4. Half-normal plot (text) — the effect-ranking eyeball method

Inactive effects are draws from N(0, sigma_eff); their absolute values plot ON
a straight half-normal line through the origin. Active effects break OFF the
line, upper right. Rank all 7 effects by |estimate|, pair rank i with the
(i-0.5)/7 quantile of the half-normal:

```text
 rank  effect  |effect|  z
   1     C       0.28   0.09
   2     BC      0.40   0.27
   3     ABC     1.03   0.46
   4     AC      1.60   0.67
   5     AB      6.69   0.92      <- breaks away
   6     B       9.07   1.24
   7     A      11.81   1.80

 |effect| (um)
  12 |                                       * A
  11 |
  10 |
   9 |                                  * B
   8 |
   7 |
   6 |                            * AB
   5 |
   4 |
   3 |
   2 |                         . AC      (barely off-line: borderline)
   1 |          . ABC   .
 0.5|      . BC  .
   0 |___._______________________________________
      0    0.3   0.5   0.7   0.9   1.2   1.5   1.8   z (half-normal score)
```

A, B, AB are unambiguously off the line. AC hugs it; the plot is the court that
demotes the marginal t = 2.44 to "needs its own confirmation run".

## 5. The prediction equation (coded units)

Keeping A, B, AB (halved effects = coefficients):

```text
 y-hat = 10.79 + 5.90*x_A + 4.53*x_B - 3.34*x_A*x_B        (um)
```

Reading it back (conditional B coefficients = B coef + AB coef*x_A): at low
speed (x_A = -1) the feed coefficient is 4.53 + (-3.34)*(-1) = +7.88 um (half-
effect; simple effect = 15.76 um); at high speed (x_A = +1) it is
4.53 + (-3.34)*(+1) = +1.19 um. Feed opens the bore at low speed and barely
matters at high speed — that IS the -6.69 um interaction: the difference
between the two conditional coefficients is exactly the AB effect
(7.88 - 1.19 = 6.69 = |AB|).

## 6. Model adequacy (residuals computed)

Residual e = y - y-hat per observation (model of section 5):

```text
 run   obs     yhat    e
 ---   -4.20   -2.99   -1.21      ---   -1.34   -2.99   +1.65
 --+   -3.30   -2.99   -0.31      --+   -3.12   -2.99   -0.13
 -+-   13.15   12.77   +0.39      -+-   15.69   12.77   +2.93
 -++   11.41   12.77   -1.35      -++   10.81   12.77   -1.95
 +--   15.29   15.51   -0.22      +--   15.03   15.51   -0.48
 +-+   16.12   15.51   +0.62      +-+   15.58   15.51   +0.07
 ++-   15.28   17.89   -2.61      ++-   18.55   17.89   +0.66
 +++   18.29   17.89   +0.40      +++   19.43   17.89   +1.54
```

Checks (all computed):
- Normality: normal-score correlation r = 0.987 (n=16, clear), max |e| = 2.93
  ~ 2.2 sigma-hat, no outlier leverage.
- Independence: mean residual of rep-1 runs = -0.54, rep-2 = +0.54, block
  difference 1.07 um vs SE = sqrt(2*MSE/8) = 0.654 um, t = 1.64 (ns). A mild
  replicate-block shift consistent with tool warm-up; not significant, but it
  is the pattern to watch if a third replicate is ever added.
- Constant variance: |e| range 0.07-2.93 across corners with no funnel shape.

## 7. Confirmation-run logic (holdout verification)

A model earns use only after predicting runs that did NOT build it. The file's
16 observations built the equation; the corners still serve as holdouts because
the confirmation statement is the prediction INTERVAL, not the point estimate:

95% PI for the mean of a fresh pair of reps at a corner:
y-hat +/- t(0.025, 8) * sqrt(MSE/2) = y-hat +/- 2.306 * 0.925 = y-hat +/- 2.13 um.

| Corner | Predicted | 95% PI | Observed mean | In PI? |
|---|---|---|---|---|
| +++ | 17.89 | 15.75 - 20.02 | 18.86 | YES |
| --- | -2.99 | -5.12 - -0.86 | -2.77 | YES |

If AC is admitted to the model the point predictions shift by +0.80 um at
every x_C=+1 corner — still inside the PI, which is exactly why the borderline
effect does not change the engineering decision, only the next experiment
(resolve AC with a dedicated 2^2 at fixed speed... or fold it into Module 31's
fractional follow-up).

Engineering translation (uncoded, using speed 6000/9000, feed 250/350):
high speed raises deviation ~+11.8 um — toward the USL edge on a bore already
at mu = +9 um baseline; the best corner is speed LOW x feed LOW, predicted
deviation -2.99 um, which pulls the process from mu = +10.8 um toward target
and is the single biggest Cpk lever found in the Develop phase.

## 8. Lab exercises

1. Re-run section 2 and 3 scripts; assert SSE = 13.688 and every effect matches
   section 2's table to 0.01.
2. Build the half-normal plot yourself from the 7 effects (rank, quantile,
   plot). Does your AC classification match section 4?
3. Write the prediction equation with AC included and recompute both holdout
   corners. Are they still inside the PI?
4. What run would you add to resolve AC definitively? Specify factors held
   fixed, levels varied, replicates.
5. Convert the coded equation to uncoded units for speed and feed (watch the
   coefficient rescaling by half-ranges: coefficient per RPM = 5.90/1500).

## Files

- `data/doe-2k-full.csv` — seeded dataset (seed 30), registered in
  `datasets/MANIFEST.md`

## See also

Module 28 (ANOVA machinery), Module 29 (DOE discipline), Module 31
(fractional factorial — next after this design saturates), RUNNING-CASE.md
(pinned factor/response definitions).

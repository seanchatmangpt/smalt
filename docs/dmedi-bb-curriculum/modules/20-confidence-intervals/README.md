# Module 20 — Confidence Intervals

Spine: CTQ-1 bore diameter, spec 12.000 ± 0.025 mm. Primary dataset:
`data/bore-30.csv` (same 30-part Line-2 sample as Module 19, seed 42190) plus
the trap dataset `data/ci-trap-overlap.csv` (seed 42290, generated in this
module, 2 x 30 parts).

## 1. What a CI is (and is not)

A 95% CI for the mean is the set of mu0 values the data would NOT have
rejected at alpha = 0.05, two-sided. That is the whole link to Module 19:
**CI = the tests you would pass; test = the mu0 values you reject.** A CI is
NOT "95% probability mu is in here" — mu is a fixed number; the procedure is
95% correct across repeated samples.

## 2. Construction (t-based, sigma unknown)

    x-bar ± t(0.975, df=n-1) * s/sqrt(n)

Worked on bore-30 (n=30, x-bar = 12.0072, s = 0.0035, t(0.975,29) = 2.045):

| confidence | interval (mm) |
|---|---|
| 90% | (12.0061, 12.0083) |
| 95% | **(12.0059, 12.0085)** |
| 99% | (12.0054, 12.0090) |

Reading: the 99% interval is wider — confidence is bought with width. And
notice the entire 95% CI sits above 12.000: it excludes the nominal, which
is exactly the Module 19 rejection, seen from the estimation side. Same
data, same arithmetic, one consistent story.

## 3. CI width engineering

Width = 2 * t * s/sqrt(n). You control n; you don't control s (process) or
the confidence choice (consequence). To halve width, quadruple n. This is
the estimation-side twin of the Module 19 power curve.

## 4. Interpretation lab — THE TRAP, taught explicitly

**Trap: "the two CIs overlap, therefore no significant difference." FALSE.**
Overlapping individual 95% CIs do NOT imply a non-significant difference.
The individual CIs and the test answer different questions; the correct
object is the CI for the DIFFERENCE.

### The numeric example (seed 42290, `data/ci-trap-overlap.csv`)

Two CNC spindles, 30 parts each:

- Spindle 1: x-bar = 12.0032, s = 0.0013, 95% CI (12.0027, 12.0036)
- Spindle 2: x-bar = 12.0022, s = 0.0023, 95% CI (12.0013, 12.0030)
- **The CIs overlap** on (12.0027, 12.0030) — 36% of the shorter CI's width.
- 2-sample t (pooled): t = 2.062, df = 58, tcrit = 2.002,
  **p = 0.0437 < 0.05 → REJECT H0.** The 95% CI for the difference,
  (0.0000, 0.0019), excludes 0.
- A supervisor reading only the overlap would release a line that a proper
  test flags. The difference (1 um) is real enough for the data to detect:
  both CIs are tight, so a small gap is decisive.

### And the paired case (the "vice versa")

`paired-feed.csv` (Module 21, seed 42192): the two marginal CIs overlap
heavily — before (12.0057, 12.0091), after (12.0027, 12.0062) — yet the
**paired** t = -6.92, p = 3.7e-7 rejects hard, because pairing removes the
part-to-part variance and the CI of the *differences* (−0.0039, −0.0021)
excludes 0. Same lesson, opposite direction: overlap of marginal CIs hides
a large, real paired effect.

### The rule

Never decide from marginal CI overlap. Either build the CI of the
difference (pooled/Welch/paired as the design dictates) or run the test.
Equivalently: marginal-CI overlap answers nothing; only the difference's CI
or the p-value decides.

## 5. Module close — the decision tree

CI work is the estimation branch of the flagship tree
([M19 decision-tree.md](../19-hypothesis-testing/decision-tree.md), Q1-E).
Whenever a test would reject H0, the paired CI/difference CI states the
effect size; whenever it would not, the CI bounds how big the effect could
still be. Every path on the tree terminates in a test — and every test's
p-value has a CI twin. See the tree's estimation branch for where this
module sits; the tree closes the module.

## Learning objectives

By the end of this module you will be able to:

1. Construct a t-based CI for the mean by hand from n, x-bar, s and state
   how width changes with confidence level, using the bore-30 table in §2.
2. Explain a CI as "the mu0 values the data would not reject at alpha"
   and connect the 95% CI excluding 12.000 to the Module 19 rejection.
3. Diagnose the marginal-CI-overlap trap: given the spindle-1/spindle-2
   data (`data/ci-trap-overlap.csv`), show that overlapping 95% CIs
   coexist with p = 0.0437 (pooled 2-sample t) and produce the CI of the
   difference that decides correctly.
4. Compute the n needed to hit a stated CI width (the estimation twin of
   the M19 power law) and explain why width scales as 1/sqrt(n).
5. Given a paired scenario, explain why the paired-differences CI excludes
   0 while the marginal CIs overlap (the §4 vice-versa case).

## Session timing

- CI definition and test-duality briefing (15 min)
- Worked CI construction on bore-30 at 90/95/99%, instructor arithmetic
  visible from `key.md` (15 min)
- The overlap trap: learners predict, then run, the pooled t on
  ci-trap-overlap.csv; debrief the supervisor's release decision (20 min)
- CI-width engineering drill (n to halve width) (10 min)
- Decision-tree estimation branch close (5 min)

## Tools

Minitab: Stat > Basic Statistics > 1-Sample t to store the bore-30
intervals; Stat > Basic Statistics > 2-Sample t (and Paired t) for the
trap and paired cases, checking "Assume equal variances" to match the
pooled result. Python mirror: the scipy snippet in `key.md`
(stats.t.interval, stats.ttest_ind) reproduces every interval and the
t = 2.062 / p = 0.0437 verdict.

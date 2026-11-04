# Module 22 — Proportions and Chi-Square

Spine-consistent attribute datasets:

- `data/scrap-shifts.csv` — 10 shifts x 250 inspected (seed 42194)
- `data/cnc-ab.csv` — CNC-3 vs CNC-4 defective counts (seed 42195)
- `data/defect-machine.csv` — defect class x machine, N = 480 (seed 42196)
- `data/bore-100-gof.csv` — 100 bore measurements (seed 42197)

Each section ends with its tree placement; §6 closes the module on the
flagship tree.

## 2. 1-proportion z — scrap rate vs the 5% target

Define-phase target: scrap <= 5% of parts. Aggregate over 10 shifts:
n = 2500 inspected, x = 193 scrapped, p-hat = 0.0772.

- H0: p = 0.05 vs H1: p > 0.05 (one-sided — the action is "scrap is too
  high", an upper-tail decision stated before looking)
- check np0 = 125 >= 5 and n(1-p0) = 2375 >= 5 (normal approx lawful)
- z = (0.0772 - 0.05)/sqrt(0.05*0.95/2500) = **6.240**, zcrit(0.95) = 1.645
  (one-sided), p = 4.37e-10 → **reject H0**: scrap runs near 7.7%, roughly
  1.5x target. Note zcrit = 1.645 here (one-sided) vs 1.960 in M19/M20 —
  the alpha you choose must match the sides you declared.

(The key also carries the two-sided p = 4.37e-10 vs one-sided 2.2e-10
distinction and both 95% CI forms: Wald (0.0667, 0.0877), exact
Clopper-Pearson (0.0670, 0.0884).)

## 3. 2-proportion z — CNC-3 vs CNC-4

H0: p3 = p4; alpha = 0.05. CNC-3: 25/320 = 0.0781; CNC-4: 30/310 = 0.0968.

- pooled p-bar = 55/630 = 0.0873
- z = -0.829, |z| < 1.960, p = **0.407** → **FAIL to reject**: with ~320 per
  machine, a 1.9-point gap is within noise. This is a deliberate non-rejection
  worked example — the lesson is what failure to reject DOES NOT mean (it
  does not mean the machines are equal; the 95% CI of the difference,
  (-0.0628, 0.0255), includes differences up to 6.3 points — the data simply
  cannot distinguish the rates yet). The remedy is n, per the M19 power law.

## 4. Chi-square independence — defect class x machine

`defect-machine.csv`, N = 480:

| defect \ machine | CNC-1 | CNC-2 | CNC-3 | row total |
|---|---|---|---|---|
| scratch | 53 | 35 | 49 | 137 |
| oversize | 43 | 28 | 21 | 92 |
| porosity | 36 | 44 | 22 | 102 |
| burrs | 38 | 51 | 60 | 149 |
| col total | 170 | 158 | 152 | 480 |

- expected = row*col/N, e.g. E(scratch, CNC-1) = 137*170/480 = 48.5
- chi2 = **23.389**, df = (4-1)(3-1) = 6, crit(0.95, 6) = 12.592,
  p = **0.00068** → **reject H0** of independence: defect MIX depends on
  machine. Largest contributions: burrs/CNC-1 (4.13 — CNC-1 over-produces
  burrs relative to its column), porosity/CNC-2 (3.24) and burrs/CNC-3
  (3.48), oversize/CNC-1 (3.33). Process read: machine-specific maintenance
  actions, not a plant-wide fix — CNC-1 → deburr path, CNC-2 → porosity
  (coolant/parameters), CNC-3 → burrs too.
- All expected counts >= 5 (min 29.1): the chi-square approximation is
  lawful; no cell pooling needed.

## 5. Chi-square goodness-of-fit — binned normality check

`bore-100-gof.csv` (n = 100, x-bar = 12.0092, s = 0.0042). H0: bore is
normal(mu-hat, sigma-hat). k = 8 equal-probability bins cut at the normal
quantiles of (x-bar, s); expected = 12.5 per bin.

| bin | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| cut point (mm) | 12.0044 | 12.0064 | 12.0079 | 12.0092 | 12.0106 | 12.0121 | 12.0141 | -- |
| observed | 12 | 11 | 13 | 15 | 13 | 13 | 9 | 14 |

- chi2 = **1.920**, df = k - 1 - 2 = 5 (two parameters estimated),
  crit(0.95, 5) = 11.070, p = **0.860** → **FAIL to reject**: no evidence
  against normality. (Note the df penalty for estimating mu and sigma from
  the data — a classic lost-points error is claiming df = 7.)

## 6. Module close — the decision tree

Walk each test back up the flagship tree
([decision-tree.md](../19-hypothesis-testing/decision-tree.md)):
1-prop z (Q1-B), 2-prop z (Q1-B two rates), chi-square independence
(Q1-D), chi-square GOF (Q1-C). Exit check: given ONLY the tree, place all
four tests from the scenario descriptions alone.

## Learning objectives

By the end of this module you will be able to:

1. Run a 1-proportion z by hand (np0 >= 5 check included) against the 5%
   scrap target on `data/scrap-shifts.csv` and state why zcrit = 1.645
   here but 1.960 in M19/M20 (sidedness must match the declaration).
2. Interpret a deliberate failure to reject (CNC-3 vs CNC-4, p = 0.407)
   correctly: state what the difference CI (-0.0628, 0.0255) does and
   does not license, and name the remedy (n, per the M19 power law).
3. Compute expected counts for a chi-square independence test on
   `data/defect-machine.csv` and carry the statistic through to the
   decision (derivation shown in `key.md`).
4. Run a chi-square goodness-of-fit test on `data/bore-100-gof.csv` and
   check df against the number of estimated parameters.
5. Place all four attribute tests on the flagship decision tree from
   scenario text alone (module exit check, §6).

## Session timing

- Attribute-data orientation and the np0 >= 5 law (10 min)
- Worked 1-prop z on scrap data, instructor arithmetic visible (15 min)
- The non-rejection case: learners interpret the CNC-3/4 CI before the
  debrief (15 min)
- Chi-square independence, expected counts by hand then by tool (20 min)
- GOF worked example + tree placement drill, all four tests (10 min)

## Tools

Minitab: Stat > Basic Statistics > 1 Proportion (choose Normal
approximation to match the hand z) and 2 Proportions; Stat > Tables >
Chi-Square Test for Association for the defect-machine table;
Stat > Basic Statistics > Goodness-of-Fit Test for the bore-100 GOF.
Python mirror: scipy.stats norm.sf for the z tails, chisquare with
computed expected counts, chisquare on binned data for GOF — exact
snippets and all values in `key.md` (exit-checked against seeds
42194-42197).

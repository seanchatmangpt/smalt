# Module 30 — Solution Key (README §8 lab exercises)

Every number re-derived from `data/doe-2k-full.csv` with the README §2–§3
python3 scripts; receipt: python3 heredoc, exit 0, 2026-11-04. Re-run, do not
trust.

## 1. Exercises 1 + derived values (verification of README §2–§3)

Effects (um), contrast formula effect = 2*sum(x_L * y)/N, N = 16:

A +11.809, B +9.069, C −0.279, AB −6.686, AC +1.596, BC −0.404, ABC +1.031.
Matches the README table to 0.01. SSE = 13.688, MSE = 1.711, sigma-hat =
1.308 um, SE(effect) = 2*sigma/sqrt(16) = 0.654 um, noise threshold
+/- 2.306 * 0.654 = +/- 1.51 um.

t values: A +18.06, B +13.87, C −0.43, AB −10.22, AC +2.44, BC −0.62,
ABC +1.58. Active set {A, B, AB}; C, BC, ABC inactive; AC borderline
(2.44 vs 2.306) exactly as the README §3 verdict states.

Derivation shown (SSE): group the 16 observations by corner (8 corners x 2
reps), subtract each corner's 2-observation mean from each observation,
sum the 16 squared residuals, divide by df_E = 16 − 8 = 8.

## 2. Exercise 2 — half-normal classification

Rank by |effect|: C 0.28 < BC 0.40 < ABC 1.03 < AC 1.60 < AB 6.69 < B 9.07 <
A 11.81. A, B, AB break off the half-normal line; AC sits barely off it —
same classification as README §4 (borderline, not promoted without a
dedicated confirmation run).

## 3. Exercise 3 — prediction equation with AC included

Adding AC: y-hat = 10.79 + 5.90 xA + 4.53 xB + 0.80 xC − 3.34 xA xB
(half-effect AC/2 = 1.596/2 = 0.798 ~ 0.80, python3-derived). The xC=+1
corners shift by +0.80 um; both holdout corners recompute:

| Corner | Predicted (with AC) | 95% PI | Observed mean | In PI? |
|---|---|---|---|---|
| +++ | 18.68 | 16.55 − 20.81 | 18.86 | YES |
| --- | −2.98 | −5.11 − −0.85 | −2.77 | YES (x_C=−1, unchanged) |

Both still inside the PI — the AC borderline does not change the engineering
decision, only the next experiment.

## 4. Exercise 4 — a run (design) that resolves AC

Hold speed (A) and feed (B) fixed at the currently recommended corner
(low speed, low feed), vary ONLY coolant: a 2^2 with center point in C at
several levels of x_A — or, cleanest, a dedicated full 2^2 in (C, x_A) at
fixed x_B = −1, 3+ replicates per corner (~9–12 runs). Because AC is the
only term allowed to move, the C-contrast at each speed level estimates the
simple effect directly, and the difference of those two contrasts IS the AC
interaction with no aliasing. Acceptance: |AC_re-estimated| > 2*t*SE with the
new replication; if it fails, AC was chance (as the half-normal plot
predicted) and it is retired.

## 5. Exercise 5 — uncoded units

Half-ranges: speed 1500 RPM, feed 50 mm/min. Slope per raw unit =
coefficient / half-range:

- speed: 5.90/1500 = +0.003933 um per RPM (python3-derived).
- feed: 4.53/50 = +0.0906 um per (mm/min).
- Center points: 8000 RPM, 300 mm/min; grand mean 10.79 um at center.

y-hat(um) = 10.79 + 0.003933*(RPM − 8000) + 0.0906*(feed − 300)
            − 3.34 * ((RPM−8000)/1500) * ((feed−300)/50).

Sanity check (corner 9000/350): coded +1/+1 → 10.79 + 5.90 + 4.53 − 3.34 =
17.88; uncoded: 10.79 + 0.003933*1000 + 0.0906*50 − 3.34 = 17.88. Identical.

## See also

README §2/§3 scripts (source of every number), Module 31 (the fractional
follow-up when factors exceed the run budget).

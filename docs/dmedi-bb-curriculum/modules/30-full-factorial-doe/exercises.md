# Module 30 Exercises — 2^3 Full Factorial (Worked End to End)

Source: `data/doe-2k-full.csv` (16 rows) and README §8 (five lab exercises).
Every number below re-derives from the CSV via the README §2–§3 python3 scripts
and is pinned by `court.py` (exit 0 = all re-derive; `--mutate` exit 1 class).
Receipts: 2026-11-04. Re-run, do not trust.

**Time: 40 min** (Ex 1: 12 min, Ex 2: 8 min, Ex 3: 10 min, Ex 4: 10 min).

## Exercise 1 — Re-derive the effects and the noise threshold (12 min)

From the 16-row CSV, compute the 7 effects (contrast formula
effect = 2·Σ(x_L·y)/N) and classify each against the noise threshold.
Court-pinned: A +11.81, B +9.07, C −0.28, AB −6.69, AC +1.60, BC −0.40,
ABC +1.03; grand mean 10.79.

(a) Derive SSE (group by corner, 8 corners × 2 reps), MSE (df 8), sigma-hat,
    SE(effect), and the ±2.306·SE threshold.
(b) Classify all 7 effects; state what happens to AC specifically.

### Key (derivation shown)

SSE = 13.688 on 16 − 8 = 8 df → MSE = 1.711 → sigma-hat = 1.308 um;
SE(effect) = √(4·MSE/16) = 0.654 um; threshold = 2.306 × 0.654 = **±1.51 um**.

| effect | value | t | verdict |
|---|---|---|---|
| A | +11.81 | +18.06 | active |
| B | +9.07 | +13.87 | active |
| AB | −6.69 | −10.22 | active |
| AC | +1.60 | +2.44 | **borderline** (off the half-normal line but under 2.6) |
| ABC | +1.03 | +1.58 | inactive |
| BC | −0.40 | −0.62 | inactive |
| C | −0.28 | −0.43 | inactive |

AC stays borderline — not promoted without a dedicated confirmation run (Ex 4).

## Exercise 2 — Half-normal ranking (8 min)

Rank all 7 effects by |effect| and identify which break off the line.

### Key (derivation shown)

C 0.28 < BC 0.40 < ABC 1.03 < AC 1.60 < AB 6.69 < B 9.07 < A 11.81.
A, B, AB break off clearly; AC sits barely off it — the same borderline verdict
as Ex 1 (court pins AC_borderline: 2.44 > 2.306 and < 2.6). Nothing between
1.03 (noise-class) and 1.60 (borderline) — the break is at AC, and the
classification is a judgment pinned by the court, not an eyeball call.

## Exercise 3 — Prediction equation, holdouts, and the interaction identity (10 min)

With the active set {A, B, AB}:

y-hat = 10.79 + 5.90·xA + 4.53·xB − 3.34·xA·xB  (half-effects)

(a) Predict both holdout corners and check them against their observed means
    with the 95% PI half-width.
(b) Show mechanically that the conditional effect of B at xA = −1 vs xA = +1
    differs by exactly the AB effect.

### Key (derivation shown)

(a) pred(+++) = 10.79 + 5.90 + 4.53 − 3.34 = **17.89** (court-pinned);
    pred(−−−) = 10.79 − 5.90 − 4.53 − 3.34 = **−2.99** (court-pinned).
    PI half-width = 2.306·√(MSE/2) = **2.13 um**; both observed corner means
    (18.86 and −2.77) fall inside their PIs.
(b) The court pins the identity algebraically: cb_lo = E[B]/2 + E[AB]/2·(−1),
cb_hi = E[B]/2 + E[AB]/2·(+1), so cb_lo − cb_hi = −E[AB] = +6.69. Conditional
B effect at low speed is 9.07/2 + 6.69/2 = 7.88 um; at high speed
9.07/2 − 6.69/2 = 1.19 um; difference = 6.69 um = |AB|. OFAT's "more feed
always opens the bore" is a statement about 1.19, and it is false at low speed
where the effect is 7.88 — the interaction is the whole lesson.

(c) (bonus) Uncoded: slope per raw unit = coefficient / half-range:
    speed 5.90/1500 = +0.003933 um/RPM; feed 4.53/50 = +0.0906
    um/(mm/min); center 8000 RPM / 300 mm/min, grand mean 10.79. Check corner
    9000/350: coded 17.88, uncoded 17.88 — identical.

## Exercise 4 — A design that resolves the AC borderline (10 min)

Design the smallest run-set that resolves AC (+1.60, t = 2.44) cleanly, and
state the acceptance rule.

### Key (derivation shown)

Hold speed and feed fixed at a chosen corner of (A, B), vary only coolant — a
dedicated 2^2 in (C, x_A) at fixed x_B = −1, 3+ replicates per corner
(~9–12 runs). The C-contrast at each speed level estimates the simple effect
directly; the difference of the two contrasts IS the AC interaction with no
aliasing. Acceptance: |AC_re-estimated| > 2.306·SE with the new replication;
if it fails, AC was chance (as the half-normal plot predicted) and it is
retired. This is key §4's answer, unchanged by the exercises above.

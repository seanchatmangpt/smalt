# Solution Key — Module 32 Catapult Lab (seed 43201)

All numbers re-derived from `data/catapult-results.csv` on disk in this session.
Court commands shown; each exits 0 on pass.

## 0. Court — simulator determinism (receipt)

```
$ python3 data/simulator.py
SIM-SELFTEST PASS
wrote .../catapult-results.csv 20 rows        exit: 0
$ sha256 catapult-results.csv
a63fd2395b14291224d38d683624b99c528aeebe77e944f7dc7ba2f25c4a6517
$ python3 data/simulator.py && sha256 catapult-results.csv
a63fd2395b14291224d38d683624b99c528aeebe77e944f7dc7ba2f25c4a6517   (identical)
```

Self-test contents (inside `simulator.py`): two independently seeded noise
sequences are equal (determinism); release speed at (0.5 m, 50°, 60 g) equals
K·θ_rad·L exactly (m = m0 ⇒ sqrt term = 1); launch angle at H = 0.20 m is 45°;
ideal range equals v²·sin(2α)/g with α = 45°; range is monotone increasing in L
over the tested range (corner-optimum premise). Any violation raises ⇒ nonzero
exit. PASS, exit 0.

## 1. Data shape

20 rows × 11 cols: `std_order, run_order, A, B, C, D, A_armlen_m,
B_stopang_deg, C_ballmass_g, D_pivot_m, dist_m`. Rows 1–16 factorial (±1 coded),
17–20 center points (0 coded). Court: read back, assert 16 + 4 split.

## 2. Factorial effects from the 16 corner runs (contrast means, m)

| effect | value (m) | note |
|---|---|---|
| A (arm length) | **+0.5090** | largest positive |
| B (stop angle) | **+0.5021** | |
| C (ball weight) | **−0.4342** | largest negative |
| AB | +0.1920 | |
| BC | −0.1634 | |
| AC | −0.1632 | |
| ABC | −0.0623 | |
| D (pivot height) | **+0.0044** | ≈ 0 — but see §3 |
| all D-interactions | ±0.004 or less | D is quiet on linear terms |
| AD, BD, CD, ABCD … | ≤ 0.0027 (ABCD = −0.0027) | CSV-derived bound |

Full 2^4: no aliasing — each coefficient is one effect. Naive ranking says: A↑,
B↑, C↓, D nothing. Best run: std_order 3 (A+,B+,C−,D+) at 3.3372 m; factorial
mean 1.3072 m.

## 3. Court — curvature test from center points (exit-checked)

```
center mean      = 1.2415 m   (4 replicates)
factorial mean   = 1.3072 m
center sd        = 0.0119 m   (df = 3; planted 12 mm — consistent)
difference       = −0.0657 m  (center BELOW the factorial plane)
se               = sp·sqrt(1/4 + 1/16) = 0.0067 m
t                = −9.86      |t| = 9.86 > t(0.025, 3) = 3.182  => SIGNIFICANT
```

Verdict: the plane is rejected. Direction matters pedagogically: the curvature is
**negative** (center below the corner-anchored plane). Mechanism, from the
physics: range ∝ v² ∝ (θ·L/√m)² is convex in A, B, C — the center of a convex
arc sits *below* the chord joining its endpoints — and this dominates the
*positive* concavity of sin(2α) in D (which peaks at α = 45°, exactly the center
level of H). Pivot height's true effect is a large quadratic wearing a zero main
effect: the D column at ±1 sits symmetrically on either side of the α = 45°
peak, so the linear contrast cancels while the center point pays full price.

Consequence (decision rule applied mechanically): significant curvature ⇒ the
first-order model is unfit for extrapolation ⇒ do not chase the corner with the
plane; schedule a second-order (RSM, Module 15) exploration centered near the
A+, B+, C− region, with D's quadratic explicitly in the model.

## 4. Pure error and the noise floor

Center replicates give sp = 0.0119 m on df = 3. Reference points: D's main
effect (0.0044) is *inside* roughly 0.4·sp — a linear-effect court would acquit
D, which is exactly why the curvature test is the load-bearing check, not the
Pareto of main effects.

## 5. Minitab mirror

Create Factorial Design (4 factors, 2 levels, center points = 4) → Analyze
Factorial Design: the ANOVA carries a Curvature line (F-test on center vs
corners) and the effects table reproduces §2 within rounding.

## Standing

ALIVE. Courts: SIM-SELFTEST PASS exit 0; sha256 identical across two regenerations
(a63fd239…6517); 20-row read-back with 16/4 split; effects and curvature t
re-derived from the raw CSV exit-checked. Data + generator registered in
MANIFEST.md (seed 43201).

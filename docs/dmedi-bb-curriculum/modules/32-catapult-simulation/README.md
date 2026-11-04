# Module 32 — Catapult Lab: 2^4 + Center Points on a Runnable Simulation

Case: CPPC tabletop catapult calibration lab (standalone secondary example,
labeled per RUNNING-CASE.md). Files: `data/simulator.py` (the physics model +
dataset generator, seed 43201), `data/catapult-results.csv` (20 rows).
Prerequisite: Module 31 (fractional factorials, effect estimation).

## Learning objectives

- Execute a full 16-run 2^4 factorial **plus 4 center points**, and say precisely
  what the center points buy that factorial points cannot.
- Re-run a seeded simulator and trust the result (determinism is a court, not a
  hope).
- Detect curvature from center points with a t-test, and state the correct
  response when the first-order model fails: stop extrapolating, escalate to RSM
  (Module 15).

**Session timing** (2.5 h total): apparatus + simulator self-test (run twice,
sha256 compare), §1 + §3 step 1 (25 min); run sheet and why 4 center points,
§2 (20 min); factorial effects analysis, §3 step 2 + §4 (35 min); curvature
t-test and decision rule, §3 step 3 (25 min); teachable twist debrief, §5
(25 min); Minitab path demo, §6 (10 min); key court re-runs (20 min).

## 1. The lab apparatus (simulated, but the physics is real physics)

Factors and response:

| coded | factor | −1 | 0 | +1 |
|---|---|---|---|---|
| A | arm length L (m) | 0.40 | 0.50 | 0.60 |
| B | stop angle θ (deg) | 40 | 50 | 60 |
| C | ball weight m (g) | 40 | 60 | 80 |
| D | pivot height H (m) | 0.10 | 0.20 | 0.30 |

Response: landing distance (m). Model (documented in the simulator header):

```
release speed  v = K · θ_rad · L · sqrt(m0/m)     (K = 8.0 /s, m0 = 60 g)
launch angle   α = 45° + 15° · (H − 0.20)/0.10
vacuum range   R = v² · sin(2α) / g
observed       R + N(0, 12 mm),  random.seed(43201)
```

Three deliberate physics features drive the lesson: the range goes as **v²**, so
A, B, C enter *nonlinearly* (convexly) even though a factorial only tests two
levels; launch angle peaks at **α = 45°, which sits exactly at the center of the
D range**, so pivot height hides behind a near-zero main effect while carrying a
large quadratic; and the tested A/B/C ranges are all on the *rising* side of
their curvature, so the best corner genuinely is the best point *in the tested
region*.

## 2. Run sheet: 16 + 4

- 16 factorial runs: full 2^4 in Yates order (std_order 1–16), run order shuffled
  under the seed (the `run_order` column).
- 4 center points at (0,0,0,0): std_order 17–20. For classroom simplicity the
  sheet appends them at the end; in a physical lab you would interleave them
  through the sequence to watch drift — note this in the debrief.

Why 4 center points, not 0 or 1: they estimate pure error (df = 3) AND the
center mean, so the curvature contrast has an honest denominator. A factorial
alone can never detect curvature: every fitted term is linear in the levels, and
the plane can pass through any convex surface's corners.

## 3. Lab flow

1. Run the self-test: `python3 data/simulator.py` → `SIM-SELFTEST PASS`, exit 0.
   Run it twice; `catapult-results.csv` is byte-identical (sha256 checked in the
   key). If a "measured" dataset can't reproduce itself, no analysis on it is
   replayable — this is the data-provenance law of RUNNING-CASE.md applied to a
   simulator.
2. Analyze the 16 factorial points: effects = contrast means (key §2 table).
3. Curvature check: center mean vs factorial mean, t with the center-point sd
   (key §3). Decision rule: |t| > t(0.025, df = 3) = 3.182 ⇒ the plane is out.
4. Debrief: corner winner vs curvature warning — and forward-link.

## 4. Analysis flow (mapped to Lane 12/13 methods)

- Module 31 method: effect estimation as contrast means, Pareto ranking of the
  15 factorial effects (no aliasing here — full 2^4, every effect its own chain).
- Module 10 method: the 4 center replicates are a tiny I-chart/pure-error pool;
  the curvature t-test is a two-sample comparison against that pool.
- Module 09 method: before trusting |t|, eyeball the center replicate spread —
  sd ≈ 0.012 m matches the planted 12 mm; if the spread were 10× the effect, the
  curvature verdict would flip.

## 5. The teachable twist (derived, not asserted)

The fitted picture says two things at once:

1. **The best run sits at a corner**: A+, B+, C− dominates (run 3, ≈ 3.34 m vs
   factorial mean ≈ 1.31 m). Effects: A ≈ +0.51 m, B ≈ +0.50 m, C ≈ −0.43 m,
   D ≈ 0.00 m. A naive first-order conclusion: "crank arm length and stop angle,
   drop ball weight, pivot height is irrelevant."
2. **The center points refuse the plane**: center mean ≈ 1.242 m vs the
   factorial-plane value 1.307 m — a −0.066 m gap, t ≈ −9.9 on df = 3 (key §3).
   The surface is curved, the "irrelevant" D is a buried quadratic (α = 45° at
   center), and extrapolating the corner winner beyond the tested region is
   unlawful — the same convexities that put the corners up here will eventually
   pull the surface back down.

Decision discipline: significant curvature ⇒ do **not** extrapolate the corner;
move to a response-surface design (center composite axial runs) around the
corner region — Module 15's RSM. The corner is where to *look*, the curvature
test is the license that says a second-order model is required to *look* there.

## 6. Minitab path

Stat > DOE > Factorial > Create (2-level, 4 factors, number of center points = 4);
Analyze Factorial Design (cube plots, Pareto); the curvature line appears in the
ANOVA when center points exist. python3 mirror in the key.

## Courts (all exit-checked)

1. Simulator self-test: determinism under seed + physics invariants (`SIM-SELFTEST
   PASS`, exit 0); regenerate-and-compare sha256 identical.
2. Effects re-derived from the CSV on disk (not from the simulator's internals).
3. Curvature t computed from raw columns; decision rule applied mechanically.

## See also

Module 31 (aliasing — absent here, the contrast), Module 15 (RSM follow-up),
RUNNING-CASE.md provenance law.

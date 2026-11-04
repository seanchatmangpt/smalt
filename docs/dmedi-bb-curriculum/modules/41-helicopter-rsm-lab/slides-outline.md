# Module 41 — Signature Lab: Paper-Helicopter Sequential RSM

**Module**: 41-helicopter-rsm-lab
**Learning objectives** — after this module the Black Belt candidate can:
1. Run the complete sequential-RSM arc on a physical system: screen 7 factors with a resolution-IV fractional factorial, follow the steepest-ascent path, close in on the optimum with a rotatable central composite design.
2. Write and execute a full experimental spec — factor table with natural ranges, run sheet with drop protocol, median-of-3 response rule.
3. Fit a full quadratic by OLS (stdlib python3) and locate the optimum analytically (solve ∇T = 0), then convert the coded optimum back to natural build dimensions.
4. Judge model adequacy from residual SD and center-point replication, and confirm the prediction with real drops.
5. Articulate *why* each stage exists: screening buys parsimony, ascent buys location, CCD buys curvature — 40 runs total, not 2^7 = 128.

**Timing estimate**: 6.0 h (spec briefing 0.5 h, lab builds + runs 2.5 h, analysis 1.5 h, court/self-check 1.5 h). This is the course's signature lab: everything from modules 29–40 appears here in one physical system.
**Required tools**: paper, scissors, ruler, stopwatch (phone), paperclips, python3 stdlib. Solution key: `data/compute.py` — simulates the lab (seed 41001, gaussian drop noise σ = 0.06 s, median of 3 drops), regenerates `helicopter-rsm.csv`, and re-derives every printed number. Candidates fly real helicopters and compare their own arcs against the key's structure, not its numbers.

**Prerequisites (bridge).** This lab assumes Module 30's full-factorial
mechanics (Yates order, effect estimation), Module 31's fractional-factorial
aliased structure (resolution-IV generators, 2^(7-3)), and Module 23/24's OLS
fitting (F/t identity, coded-to-natural conversion). Module 37's center-point
curvature test is the gate that decides when to leave the plane. If the
resolution-IV generator logic or the OLS quadratic fit is not yet fluent,
rebuild those stages on the catapult (M32) before flying this lab.

---

## Slide 1 — The system (15 min)
A paper helicopter is a first-rate DOE teaching system: 30-second builds, drop-to-drop noise small enough to see effects, and a genuinely curved response surface — bigger is *not* monotonically better.

**Response**: descent time (s) from a 3 m drop, **median of 3 drops per run** (median because a bad release or wall eddy corrupts one drop, not the median).

**Factor table (7 factors, coded −1/+1 screening ranges)**:

| factor | natural −1 | natural +1 | type |
|---|---|---|---|
| A wing length | 70 mm | 130 mm | continuous build dim |
| B wing width | 25 mm | 55 mm | continuous build dim |
| C tail length | 40 mm | 80 mm | continuous build dim |
| D tail width | 15 mm | 35 mm | continuous build dim |
| E body height | 20 mm | 40 mm | continuous build dim |
| F paperclips | 0 | 2 | discrete |
| G fold height | 10 mm | 30 mm | continuous build dim |

Release protocol (must be pinned before run 1): same 3 m mark, same release height, drop from hands-level with wings flat, no drafts (interior room), timing from release to floor contact, 3 drops per config, record all 3 and the median on the run sheet.

## Slide 2 — Stage 1: screening (25 min)
- 16-run 2^(7−3) resolution-IV design: generators E = ACD, F = ABC, G = BCD. Main effects are aliased only with three-factors (assumed negligible); two-factor interactions are aliased with other two-factors — fine for screening, fatal for optimization, which is why this is stage 1 and not the whole story.
- Run sheet (candidate fills as they fly): 16 rows × (7 coded settings, drop1, drop2, drop3, median). Randomize run order; keep builds labeled A–P.
- The key's simulated stage-1 results (OLS coefficients; full effect = 2 × coef):

```
  intercept 3.001
  wing_len   coef +0.906 s (effect = +1.811)  <== ACTIVE
  wing_wid   coef +0.496 s (effect = +0.991)  <== ACTIVE
  tail_len   coef -0.301 s (effect = -0.601)  <== ACTIVE
  tail_wid   coef +0.074 s (effect = +0.149)
  body_hgt   coef -0.049 s (effect = -0.099)
  clips      coef +0.027 s (effect = +0.054)
  fold_hgt   coef -0.029 s (effect = -0.058)
active set: [wing_len, wing_wid, tail_len]
```

- Read: long wings, wide wings, short tails hang longer. Four of seven factors are inert — that is the screening payoff: the CCD will be built in 3 dimensions (10 parameters), not 7 (36 parameters, needing ~70+ runs).

## Slide 3 — Stage 2: steepest ascent (20 min)
- The screening model is a plane through coded space. Its gradient in (A, B, C) is normalized and stepped in half-unit increments, D–G held at 0 (screening mid-levels):
```
  step1  A=+0.42 B=+0.23 C=-0.44   median = 4.69 s
  step2  A=+0.84 B=+0.46 C=-0.58   median = 4.93 s
  step3  A=+1.26 B=+0.69 C=-0.72   median = 4.93 s
  step4  A=+1.68 B=+0.92 C=-0.86   median = 4.71 s
  -> improvement stops after step3 (4.93 s peak); CCD centered there
```
- Two teaching points hidden in those four rows:
  1. **Flat then down beats up-then-crash**: steps 2→3 are statistically indistinguishable (4.93 vs 4.93) — the first sign the plane is bending; step 4 drops. The candidate must call the stop *before* seeing the CCD data, from this table alone.
  2. The stopping rule is "first non-improvement", not "best of N": walking past the peak wastes runs and risks extrapolating a dead plane.
- Note in natural units: step 3 is already outside the screened +1 corner (A ≈ 1.26 → 108 mm wing... beyond by design — ascent *leaves the screened region*, which is the whole point).

## Slide 4 — Stage 3: the CCD (25 min)
- Rotatable central composite design in (A, B, C), alpha = 2, centered at the ascent peak (1.25, 0.70, −0.70): 8 factorial + 6 axial + 5 center points = 19 runs.
- Why these three ingredients: factorial points estimate linear + interaction terms; axial points (±2 from center) estimate the pure quadratics — a factorial alone cannot; center points estimate pure error and expose lack of fit.
- Rotatability: alpha = 2 makes prediction variance constant at equal distance from center, so the surface read is orientation-free.
- Full quadratic fit from the key (19 CCD runs, 10 parameters, 9 residual df):

```
  T = 4.184 +0.913A +0.506B -0.273C +0.134AB -0.009AC +0.046BC
      -0.453A^2 -0.538B^2 -0.195C^2
  residual SD = 0.029 s on 9 df
```

- Cross-check against truth (candidate does this only at the end): the true simulated surface has coefficients 0.90, 0.50, −0.30, 0.15, −0.45, −0.55, −0.20 — the fit recovers every one within noise. The residual SD 0.029 s is *below* the single-drop σ = 0.06 s: median-of-3 shrinks noise, exactly why the response rule exists.

## Slide 5 — Optimum search and confirmation (20 min, worked)
- Solve ∇T = 0 analytically: the Hessian is 3×3; gaussian elimination gives the stationary point:

```
  stationary point (coded): A +1.100, B +0.579, C -0.655
  predicted descent time at optimum: 4.922 s
  A wing length mm     natural = 133.0  (range 70-130)  <-- outside!
  B wing width mm      natural = 48.7   (range 25-55)
  C tail length mm     natural = 46.9   (range 40-80)
```

- The wing-length optimum lands slightly outside the original screening range (133 vs 130 mm). Correct handling: state it, build a helicopter at the constraint edge (130 mm) and one just beyond (135 mm), and let the drops decide — the coded math proposes, the physical system disposes.
- Confirmation: 3 drops at the optimum:

```
confirmation at optimum: drops [4.94, 4.98, 4.95] -> median 4.95 s
screening grand mean (16 corner runs): 3.00 s -> 4.95 s  = +1.95 s improvement
total runs consumed: screen 16 + ascent 4 + CCD 19 + confirmation = 40
```

- Receipt discipline: the improvement claim (+1.95 s, ~65% longer hang time) is backed by drops actually flown, not by the fitted surface alone. A prediction the confirmation misses by > 2·residual SD means the model does not hold at that point — investigate, never average it away.

## Slide 6 — Run sheet template (the lab's artifact)
```
| run | stage | A | B | C | D | E | F | G | drop1 | drop2 | drop3 | median |
|-----|-------|---|---|---|---|---|---|---|-------|-------|-------|--------|
| 1   | screen| -1| -1| -1| -1| +1| +1| -1|  2.10 |  2.08 |  2.02 |  2.08  |
| ... 40 rows total; candidates fill by hand, key reproduces from seed |
```
- The CSV `helicopter-rsm.csv` is the key's run sheet: columns stage/run/phase, 7 coded factors, 3 drops, median. Candidates flying real paper must produce the same artifact with their own numbers.
- Build law: one configuration = one labeled template; rebuilds from the same template count as the same run's drops, not replicates (replicates require independent builds — template wear is a noise factor candidates discover the hard way).

## Slide 7 — Why-it-works (15 min)
- **Sequentiality is the efficiency**: 2^7 full factorial = 128 runs and still only a plane. 16 + 4 + 19 + 3 = 40 runs land on the optimum with a validated quadratic. Each stage spends runs only where the previous stage proved they matter.
- **Resolution IV screening** assumes 3-fi effects are dead. In this system they are; a candidate whose real helicopter shows a huge G effect at step 1 has discovered the assumption failing — the lesson is the assumption is *checkable* (fold height drops out with a near-zero effect here; it would not in a drafty stairwell).
- **Median response** = robust statistic: single-drop outliers (release error, air current) enter as one corrupted drop, never as the response. The court checks that all 3 drops are recorded — a run sheet with only medians cannot be audited.
- **Curvature is physical, not statistical**: wing loading (area vs mass) makes descent time dome over (A, B). The quadratic fit doesn't create the dome; it measures it. Candidates should predict the dome's existence from physics before seeing stage 3.

## Lab protocol (the actual flying, ~2.5 h)
1. Build the 16 screening helicopters, fly 3 drops each in randomized order, fill the run sheet.
2. Compute effects by hand from corner means (key's stage-1 block is the answer check).
3. Walk 3–4 ascent steps as physical builds; call the stopping point in writing before proceeding.
4. Build the 19 CCD configurations around the team's own stopping point; fly them.
5. Fit the quadratic (the key's `ols()` is reusable; candidates adapt it to their coded center), find the stationary point, convert to natural dimensions.
6. Build and fly the confirmation helicopter; state the improvement receipt with all drops.

## Court / self-check (exit-checked)
- `python3 data/compute.py` exits 0; every number in slides 2–5 re-derives from `helicopter-rsm.csv`.
- Design integrity checks the candidate writes and runs: (a) the 16 screening runs form a balanced fraction — each column ±1 balanced, every 2-fi column distinct; (b) the CCD has 5 center runs whose SD is the pure-error estimate; (c) all 40 rows have 3 drops and a median equal to the middle drop.
- Non-vacuity: perturb one CCD drop by +1 s and confirm both the residual SD and the stationary point move; restore from seed.
- Coherence: no running-case constants are reused here (labeled standalone physical lab), but the methodology receipt format is course-standard: stage, runs consumed, model, stationary point, confirmation, standing.

## See also
Module 29/30 (design fundamentals), 37 (curvature detection — stage 3 is the CCD the center-point test argues for), 39 (same quadratic machinery under simplex constraints), 40 (noise factors: a stretch goal is repeating the confirmation across two paper lots).

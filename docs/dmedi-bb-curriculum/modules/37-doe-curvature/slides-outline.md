# Module 37 — DOE: Curvature Detection and the Axial Path

**Module**: 37-doe-curvature
**Prerequisites (bridge).** Assumes Module 30's full factorial (effect
estimation, coded units) and Module 21 §4's variance-homogeneity discipline;
the curvature test itself is the decision tree's 2-sample t path (row 12b)
applied to corner-vs-center means.
**Learning objectives** — after this module the Black Belt candidate can:
1. Add center points to a 2^k factorial and run a formal center-point curvature test (two-sample t on corner mean vs center mean).
2. Decide, from the test verdict, whether the planar factorial model is adequate or a response-surface design (CCD/Box–Behnken) is required.
3. Fit the planar model from factorial effects, form the gradient, and walk the axial (steepest-descent/ascent) path in coded and natural units.
4. Link forward from the Lane 13 / module 28–30 catapult-and-bore DOE strands: same running case, same response definition.
5. Explain why curvature detection costs only a handful of runs and why the center-point mean has zero leverage on planar effects (and vice versa).

**Timing estimate**: 3.5 h (slides 1.25 h, lab 1.25 h, exercises 0.5 h, court/self-check 0.5 h).
**Required tools**: python3 stdlib only. The full solution key is `data/compute.py`; it regenerates `data/bore-curvature.csv` (seed 37001, deterministic) and re-derives every number below.

---

## Slide 1 — Where we are in the DOE strand (10 min)
- Module 29: DOE principles. Module 30: 2^k full factorial on the CPPC bore (A = spindle speed, B = feed, C = coolant %).
- A 2^k factorial fits only a **plane**: `y = b0 + bA·A + bB·B + bC·C` (plus interactions). It cannot see bends.
- The bore deviation surface **bends**: near target the surface flattens. If we extrapolate the plane we either chase a nonexistent optimum or stop too early.
- Today: detect the bend cheaply, then start walking toward the optimum.

## Slide 2 — Center points: the cheapest curvature detector (15 min)
- A center point is (0, 0, 0) in coded units — mid-level of every factor.
- Properties that make it free:
  - The center point contributes **nothing** to any main effect or 2-fi estimate (coded columns sum to zero there), so adding them does not bias the factorial effects.
  - Conversely the factorial corners give the center point no information: any difference between the corner mean and the center mean is **pure quadratic signal + noise**.
- Test: two-sample t, corner obs vs center obs.
  - H0: mean of the planar model's predictions at the corners equals the center mean.
  - In practice: H0: mu_corner = mu_center. Large |t| ⇒ the plane is not adequate ⇒ curvature.

## Slide 3 — The CPPC curvature experiment (20 min)
- Design: 2^3 factorial, 2 reps per corner (16 obs) + 6 center points, randomized run order.
- Factors (running case): A = spindle speed, B = feed rate, C = coolant concentration. Response: bore deviation from 12.000 mm, µm (smaller is better, 0 is perfect).
- Dataset: `data/bore-curvature.csv` (seed 37001). Columns: std run, coded A/B/C, center flag, rep, y_um.

## Slide 4 — Running the curvature test (25 min, worked, all numbers from the key)
`python3 data/compute.py` prints:

```
factorial points: 8 corners x 2 reps = 16 obs
center points: n=6
ybar(fact) = 11.590 um   ybar(center) = 5.390 um
diff = +6.200 um
s_fact = 3.297, s_center = 2.239, s_pooled = 3.067
SE(diff) = 1.468  ->  t = 4.223, df = 20
t_crit(0.025, 20) = 2.131  ->  CURVATURE PRESENT
```

- Verdict: 4.223 > 2.131 ⇒ reject the plane. The process mean at the center (5.39 µm) sits well **below** the corners' planar prediction (11.59 µm) — the surface domes downward toward the middle: the optimum region is interior, not at a corner.
- Reading the sign: center mean < corner mean with response "deviation from target" means moving inward (from corners toward center) **reduces** deviation — exactly the case where the next design must be a response-surface design.
- Guardrail: if the test had NOT fired, the correct move is more center points (cheap) or accept the plane and optimize on the factorial model — never silently extrapolate a rejected plane.

## Slide 5 — The planar model and its gradient (20 min, worked)
From the 8 corner means:

```
E(A speed)    = -4.450 um      E(B feed)     = +2.255 um
E(C coolant)  = +0.665 um      E(AB)         = +1.600 um
yhat = 11.590 -2.225A +1.128B +0.332C +0.800AB
```

- Coefficients b = effect/2 in coded units; b0 = grand mean of corners.
- The gradient `g = (-2.225, +1.128, +0.332)`, `|g| = 2.516`, points in the direction of steepest **increase** of deviation.
- We want deviation **down**, so the axial path step direction is `-g/|g| = (+0.884, -0.448, -0.132)`.

## Slide 6 — Walking the axial path (20 min)
- Rule: step `delta` coded units along `-g/|g|`, run a small confirmation batch (3–5 obs) at each step, keep walking while the response improves, stop when it degrades — that region becomes the center of the next design (module 39's RSM geometry and module 41's helicopter lab use exactly this logic).
- Translating to natural units: if A spans 4000–8000 RPM per coded unit, a +0.884A step = +3536 RPM... in this case the factor ranges are pinned by the running case; the candidate converts with `natural = center + step * (range/2)`.
- Teaching point: the axial path is computed from the **plane**, so it is only trustworthy locally — which is precisely why the curvature test gates the transition to the CCD.

## Slide 7 — Why-it-works (15 min)
- Orthogonality: for corner points the coded center column is identically 0, and for center points every effect column is 0 — the two information sets don't bleed into each other. That is why one t-test cleanly isolates the quadratic block.
- Degrees of freedom bookkeeping: 6 center points buy 5 df of pure error AND the curvature df for free — the highest information-per-run purchase in all of DOE.
- The center-point t is conservative when corner variance exceeds center variance (it pools), which is the safe direction for a gate decision.

## Lab — candidate executes the test by hand (60 min)
1. Regenerate the dataset: `python3 data/compute.py` (exit 0 expected; CSV rewritten identically from seed 37001).
2. Compute ybar_corner and ybar_center with `statistics.mean` on the two `center` strata; reproduce diff = +6.200 µm.
3. Compute the pooled SD and t by hand; reproduce t = 4.223; compare to t_crit 2.131.
4. Reproduce the three main effects and AB interaction from corner means.
5. Convert the fitted plane into the axial step direction; verify the unit vector has norm 1.
6. Court question: if we had run only 2 center points, would the test still fire? Re-run the analysis with n=2 truncated data and report the new t. (Answer from the key's formula: SE inflates roughly with sqrt(1/nC); the candidate must show their own truncation run — no canned answer.)

## Court / self-check (exit-checked)
- `python3 data/compute.py` exits 0; every printed number in slides 4–6 matches a fresh run byte-for-byte.
- Non-vacuity: delete 3 center rows from the CSV and confirm the t moves (a court that cannot flip is a FAIL) — restore from seed afterwards.
- Coherence: response definition (µm from 12.000 mm) and factors match RUNNING-CASE.md pinned DOE factors.

## See also
Module 29 (DOE principles), 30 (2^k factorial), 39 (mixture/RSM geometry), 40 (robust design), 41 (helicopter RSM lab).

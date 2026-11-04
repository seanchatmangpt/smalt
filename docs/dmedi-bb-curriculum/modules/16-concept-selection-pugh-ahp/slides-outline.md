# Module 16 — Slides Outline: Concept Selection (Pugh + AHP)

H1 matches filename. Every number below is re-derived from
`data/concept_trials.csv` by `scripts/derive_selection.py` (court exit 0) —
none is remembered.

## Section 1 — Why structured selection (3 slides)

### S1. The Develop selection gate
- Module 13 left four candidate bore-finish routes on the table.
- Module 12's baseline: bore diameter Cpk = 0.72 (mu = 12.009 mm,
  sigma = 7.407 um — ADJUDICATED 2026-11-04; the 4.17 um figure is stale
  everywhere it survives).
- Target Cpk >= 1.33. The gap is a CONCEPT problem, not a tuning problem:
  no amount of DOE on a Cpk-0.72 route reaches 1.33.
- Selection method choice: Pugh (fast, comparative, datum-anchored) vs AHP
  (weighted, ratio-scale, consistency-checkable). We run BOTH on the same
  four concepts and compare.

### S2. The four concepts (from module 13)
- A — citizen regrind (incumbent, the current Cpk-0.72 route)
- B — peck deep-drill then bore (deep-cycle drilling, then finish bore)
- C — helical interpolation (programmed circular milling of the bore)
- D — combined rough + finish boring bar (single-pass roughing and finish
  on one bar)
- Pilot evidence: 30 pieces per concept, `data/concept_trials.csv`,
  seed 1607. A is generated at exactly the adjudicated spine pair
  (12.009 mm, 7.407 um).

### S3. The five criteria trace to QFD (module 05)
- C1 bore capability (CTQ-1) — judged on pilot Cpk
- C2 surface finish Ra (CTQ-1 companion EC) — judged on pilot mean Ra
- C3 cycle time (CTQ-2 lead-time driver) — route minutes
- C4 tooling + capital cost (CTQ-3, $28.50 ceiling) — route facts
- C5 flexibility / setup — route facts
- Rule: a criterion with no traceable QFD source is not in the matrix.

## Section 2 — Pugh method (4 slides)

### S4. Datum justification
- The datum is the incumbent: A (citizen regrind). Why: (1) it is the
  process actually producing Cpk 0.72 today; (2) every + and - is then a
  statement about CHANGE from the status quo, which is what a gate review
  can act on; (3) the baseline pair (12.009, 7.407 um) is pinned, so datum
  scores re-derive from the CSV.
- Pugh law: the datum row is all 0 BY CONSTRUCTION. If your datum row has
  marks in it, you are scoring absolutely, not comparatively.

### S5. Scoring basis (stated per cell, before any mark is assigned)
- C1: + if pilot Cpk exceeds datum Cpk by >= 0.20; - if lower by >= 0.20;
  else 0. Band prevents noise-driven marks (30-piece pilot).
- C2: + if mean Ra lower by >= 0.15 um; - if higher by >= 0.15 um; else 0.
- C3/C4/C5: route facts (cycle minutes, added capital, setup count /
  tool sourcing), stated in the lab brief — not student-invented.
- Score the basis FIRST, the marks SECOND. Marks assigned before bases are
  opinions with a grid drawn on them.

### S6. The iteration-1 matrix (datum = A)
| criterion | A | B | C | D |
|---|---|---|---|---|
| C1 capability | 0 | + | + | + |
| C2 finish | 0 | + | - | + |
| C3 cycle | 0 | + | + | + |
| C4 cost | 0 | - | + | - |
| C5 flex | 0 | + | - | - |
- Tallies: A +0/-0; B +4/-1 (net +3); C +3/-2 (net +1); D +3/-2 (net +1).
- Net ranking: B > C = D > A.

### S7. Pugh convergence: consolidation iteration
- D loses only on cost (custom $34k bar) and flexibility (single-source).
- Consolidation: graft B's commodity coated-insert strategy onto D's bar —
  concept **D2**, "combined rough+finish boring bar with standard coated
  insert set, single setup". Cells vs the SAME datum A:
  C1 +, C2 +, C3 +, C4 0, C5 + → +3/-0, net +3.
- D2 TIES B at net +3. Pugh law: do not break the tie by trading votes —
  escalate to the underlying data (D beats B on pilot Cpk 1.84 vs 1.55 and
  Ra 0.94 vs 1.33) and to the weighted method (AHP, next).

## Section 3 — AHP method (6 slides)

### S8. Saaty 1–9 scale
- 1 equal, 3 moderate, 5 strong, 7 very strong, 9 extreme; evens for
  interpolation; reciprocals for the mirror cell.
- AHP judgments are RATIOS, not ranks: "C1 is 2x C2" is a claim about
  relative importance with real consequences.

### S9. Criteria pairwise matrix (authored in lab brief from QFD weights)
```
           C1    C2    C3    C4    C5
C1          1    2     3     2     5
C2         1/2    1    2    1/2    4
C3         1/3  1/2    1    1/2    3
C4         1/2   2     2     1     4
C5         1/5  1/4  1/3   1/4    1
```
- Principal eigenvector (power method, 200 iterations, tol 1e-12):
  C1 0.3750, C2 0.1912, C3 0.1250, C4 0.2534, C5 0.0554 (sum 1.0000).
- Geometric-mean cross-check: 0.3765 / 0.1907 / 0.1258 / 0.2516 / 0.0555.
- lambda_max = 5.1100; CI = (5.1100 - 5)/4 = 0.0275;
  CR = 0.0275/1.12 = 0.0246 < 0.10 → consistent.

### S10. lambda_max as the consistency meter
- Perfect consistency: lambda_max = n exactly. Every unit of inconsistency
  inflates lambda_max above n.
- Teaching matrix (deliberately broken — cyclic claims: C1 over C2 by 9,
  C2 over C3 by 9, yet C1 tied with C3):
  lambda_max = 7.6162 vs n = 5, CI = 0.6540, CR = 0.5840.
- Law: CR >= 0.10 → the weights are arithmetic on noise; repair judgments
  before scoring anything.

### S11. Concept matrices per criterion, grounded in data
- Per criterion, a 4x4 matrix of Saaty-snapped ratios of the actual pilot
  quantities (Cpk ratio for C1, inverse-Ra ratio for C2, cycle-minute ratio
  for C3) or authored route-fact ratios (C4 cost factors, C5 flexibility
  ordinals). Full matrices in `solution-key.md`.
- All five matrices pass CR < 0.10 (max CR 0.0225; C5 is perfectly
  consistent at CR 0.0000).

### S12. Global scores and ranking
- Global score of concept i = sum over criteria of (criterion weight) x
  (within-criterion priority).
- A: 0.2263  B: 0.2575  C: 0.2425  D: 0.2736.
- AHP ranking: **D > B > C > A**.

## Section 4 — Agreement, divergence, and the decision (4 slides)

### S13. Where the methods diverge, and why
- Pugh iteration 1: B > C = D > A (winner B).
- AHP: D > B > C > A (winner D).
- Mechanism of divergence: Pugh counts each criterion ONCE, so B's lone
  cost minus is outweighed by four pluses; AHP weights capability at 0.375
  and cost at 0.253, and D leads on both capability (0.3564 vs 0.3257) and
  finish (0.3952 vs 0.2390), so the weighted score flips the
  winner.
- This divergence is the POINT: an unweighted method cannot see that the
  criteria are not equal. Pugh without weights answers "is this better on
  more fronts?"; AHP answers "is this better on the fronts that matter?"

### S14. Lawful tie/divergence resolution
- The consolidation creates a tie (D2 net +3 = B net +3). The Pugh-banned
  move is vote-trading to force a winner.
- The lawful move: escalate to the raw data (D Cpk 1.84 > B 1.55; D Ra
  0.94 < 1.33) and the weighted method. Both point to the D lineage.

### S15. Decision
- Carry **D2** forward into detailed design (module 27); B is runner-up and
  fallback; C is killed (finish 2.09 um is the worst in the set and its
  capability margin is the thinnest); A is the datum and stays as the
  fallback process if capital is refused.
- Module 18 (Monte Carlo) will stress-test D2's capability margin before
  the Develop gate closes.

### S16. Method selection guidance (takeaway)
- Use Pugh for speed and change-framing early; use AHP when criterion
  weights are contested; when they disagree, the disagreement itself is
  information about weighting, not a bug.
- Never average the two methods' outputs; reconcile by making weights
  explicit and re-running both.

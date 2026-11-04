# Module 05 — Solution Key

All numbers re-derive via `python3 data/court.py` (exit 0). CSVs are the source of
truth; this key shows the derivations.

## E1 — EC2 technical importance
From the CSVs: CR1 w=18 × cell 3 = 54; CR4 w=16 × cell 9 = 144; CR6 w=11 × cell 1
= 11. Total = **209** (matches court `cppc column totals`). Largest contributor is
**CR4 (bore-surface-finish-low-Ra, 144 of 209 ≈ 69%)** — EC2 is primarily the
finish-driven customer's characteristic, not the bore-in-spec voice (CR1, 54). Who
the EC serves matters when tradeoffs hit the roof.

## E2 — Conservation identity
Weighted rows: 18×15=270, 20×11=220, 9×4=36, 16×12=192, 13×9=117, 11×11=121,
7×10=70, 4×2=8, 2×2=4 → Σ = **1038**.
Columns: 241+209+180+157+173+78 = **1038**. Identity holds because both sides sum
the same w×cell products, partitioned differently; a mismatch means a transcription
error in matrix or weights (the court's `cppc total importance` check).

## E3 — EC7 rejection
1. Not measurable/controllable as a product characteristic: machine COUNT is a
   resource decision, not an engineering characteristic with a spec target — it
   fails the "measurable, one owner" rule (it's a means, not a characteristic).
2. Double-counting: CR1→machine-count "9" smuggles capability language into the
   relationship matrix; strength-of-relationship cells must describe how the EC
   moves the CR, not how the EC purchases it. The court would compute EC7 = 18×9 +
   13×9 = 279, instantly ranking it first — the matrix would then be arguing
   budget, not engineering. Rejected at cell-entry, not at prioritization.

## E4 — Roof census and the inspection fallacy
(a) 15 rows in `qfd-cppc-roof.csv` = C(6,2) = 15 ✓ (court `cppc roof pair count`).
(b) EC5 conflicts: EC1–EC5 (−−), EC2–EC5 (−), EC3–EC5 (−), EC5–EC6 (−) — 4 of 15
pairs, the most conflicted EC.
(c) Inspection does not touch σ: Cpk = min(USL−μ, μ−LSL)/(3σ). 100% inspection
changes the SHIPPED distribution by culling, not the PROCESS σ that the formula
consumes; the measured process Cpk stays at the pinned baseline and the ±0.008
guard-band target at σ=2.0 um is unreachable without σ-reduction (process work:
DOE modules 29–31, capability module 12). Also inspection costs money — it worsens
the EC1–EC5 tradeoff it was meant to dodge.

## E5 — Cpk arithmetic chain
Chain: Cpk = (tolerance)/(3σ) = 0.008 mm/(3 × 0.0020 mm) = 0.008/0.0060 = **1.33**.
Tightened guard-band: σ_required = tolerance/(3 × Cpk) = 0.005/(3 × 1.33) =
0.005/3.99 = **1.253 um (≈ 1.25 um)**. Each tightening of the print multiplies the
process work required — which is exactly the EC1–EC5 roof conflict made numeric.

## E6 — Method sensitivity on the claims weights
Paired ranks, n=6, pool = 21, points = (7 − rank): C6 rank1 → 6, C1 rank2 → 5,
C2 rank3 → 4, C4 rank4 → 3, C5 rank5 → 2, C3 rank6 → 1. Exact ×100 values:
C6 28.571, C1 23.810, C2 19.048, C4 14.286, C5 9.524, C3 4.762. Floors:
28, 23, 19, 14, 9, 4 (Σ = 97); deficit 3 goes to the three largest remainders —
C1 (.810), C3 (.762), C6 (.571). Final: **C1 24, C2 19, C3 5, C4 14, C5 9,
C6 29** (sum 100 ✓; re-derive exactly with `gen_qfd.py::largest_remainder`).
Biggest gainer: **C6 data-security (23 → 29)**; biggest loser C3
status-transparency (7 → 5). Lesson: the ranking METHOD moves weights by up to
6 points on the same voice data — method choice is a documented design decision,
never invisible.

## E7 — T6 priority claim
Supporting: T6 column total 267 is indeed the largest; driven by the two
highest-weight CRs (C6 w=23 ×9 + C2 w=20 ×3).
Caution from the roof: T6 has score 0 with every other EC — funding it first buys
ONE requirement chain (security/audit) and moves nothing else; the roof-negative
pairs (T1–T3 −−, T2–T3 −−) show T3 rework loops is the coupled constraint moving
multiple CRs. Admit T6 by importance, but sequence T3 work alongside it or the
coupled cycle-time/yield gains never land.

## E8 — Traceability
(a) Kano classes come from `modules/04-voice-of-customer/data/kano-responses.csv`
(SEED 20261104, attribute ids K-01..K-10) via `compute.py` majority classification
(M/O/A/I per lab table; `qfd-cppc-weights.csv`'s `kano_id` + `spine_ctq` columns
carry the id→spine derivation: K-01→CTQ-1, K-05→CTQ-2, K-06→CTQ-3).
(b) EC4 target ≤7 d forwards to spine CTQ-2 (baseline 18.4 d); EC5 ceiling $28.50
forwards to spine CTQ-3 (baseline $41.80).
(c) The Cpk 0.72 re-derivation flag is owned by the Lane 05 coherence court,
registered in the `datasets/MANIFEST.md` cross-module note; module 05's court
asserts the flag stays visible (EC1 baseline string contains "Cpk 0.72 pinned").
(d) The $28.50 ceiling lands in module 06 target-costing worksheets (Lane 03
costing), which decomposes it (should-cost teardown, `06-target-costing/worksheets/`).

## E9 — Blank CR row
Conservation still balances (the row contributes 0 to both sides), the column
totals are unchanged — arithmetic cannot detect an unaddressed requirement. The
row-sum check (`cppc row sums`) is the only gate: row sum 0 means no EC moves that
CR, i.e., the customer voice is silently dropped. That is why row sums are checked
per-CR against the authored table, not just in aggregate.

## E10 — Vocabulary court check
```python
vals = {int(r[e]) for r in m_rows for e in ecs if r[e]}
check("cppc matrix cell vocabulary", sorted(vals), [1, 3, 9])
```
It is already in `court.py` (this exercise reconstructs it). Vocabulary is checked
rather than "reasonable values" because 6 is individually reasonable while
collectively corrosive: a 9/3/1 scale is ordinal — a 6 invents a strength the
scale never defined, makes cross-cell comparison meaningless, and (unlike an
outlier) does not trip any sum check. Restricting the vocabulary to the closed set
{1,3,9} (blank = absent) makes every illegal strength a loud court failure.

---

Court: `python3 data/court.py && echo COURT-PASS` (exit 0 required; re-derives
weights, row sums, column totals, conservation identity, roof census, spine
targets, Cpk math, and the module-04 classification chain).

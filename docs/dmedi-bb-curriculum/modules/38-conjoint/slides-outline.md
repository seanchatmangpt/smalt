# Module 38 — Conjoint Analysis: Card Design, Part-Worths, Importance

**Module**: 38-conjoint
**Learning objectives** — after this module the Black Belt candidate can:
1. Build a full-profile conjoint study on an orthogonal array (L9, 4 attributes × 3 levels) and explain why orthogonality lets OLS separate attribute effects from 9 judgments instead of 81.
2. Estimate part-worth utilities by OLS with effect coding on a respondent's rank ordering.
3. Derive attribute importance as range share and rank the attributes for design/target-setting input to QFD (module 05 link).
4. Use the fitted model to score all 81 candidate profiles and read off the predicted best/worst.
5. Recognize the rank-scale direction trap: rank 1 is most preferred, so on a rank dependent variable *lower utility = better*.

**Timing estimate**: 3.5 h (slides 1.25 h, lab 1.25 h, exercises 0.5 h, court/self-check 0.5 h).
**Required tools**: python3 stdlib only. Solution key: `data/compute.py` — regenerates `conjoint-cards.csv` + `conjoint-ranks.csv` (seed 38001, deterministic) and re-derives every number below.

**Standalone secondary example** (labeled per RUNNING-CASE.md): the *offer* customers buy is a machining-service profile. Attributes chosen from the running case CTQs — price per unit (CTQ-3), lead time (CTQ-2), bore tolerance (CTQ-1), surface finish guarantee.

---

## Slide 1 — What conjoint answers (10 min)
- VoC (module 04) gives us voice snippets; QFD (module 05) organizes them. Neither tells us the **trade-off rates**: how much extra lead time will a customer accept for a tighter tolerance?
- Conjoint decomposes preference for whole products into part-worth utilities per attribute level. The respondent never states weights — their **rankings reveal** them.
- Trade-off context pinned here: CPPC selling the SR-71 gimbal housing service to a drone OEM.

## Slide 2 — Card design: full-profile, orthogonal array (15 min)
- 4 attributes × 3 levels = 81 possible profiles. Full-profile judgment on 81 cards is impossible; on an **L9 orthogonal array** 9 cards suffice.
- Orthogonality property used: every pair of attributes' levels appears in balanced combination, so effect columns in the design matrix are uncorrelated — each attribute's part-worths are estimable independently of the others.
- The 9 cards (from `conjoint-cards.csv`):

| card | price | lead | tol | finish |
|---|---|---|---|---|
| 1 | $52.00 | 15 days | ±0.025 mm | Ra 1.6 |
| 2 | $52.00 | 10 days | ±0.015 mm | Ra 0.4 |
| 3 | $52.00 | 7 days | ±0.008 mm | Ra 0.8 |
| 4 | $38.00 | 15 days | ±0.015 mm | Ra 0.8 |
| 5 | $38.00 | 10 days | ±0.008 mm | Ra 1.6 |
| 6 | $38.00 | 7 days | ±0.025 mm | Ra 0.4 |
| 7 | $30.00 | 15 days | ±0.008 mm | Ra 0.4 |
| 8 | $30.00 | 10 days | ±0.025 mm | Ra 0.8 |
| 9 | $30.00 | 7 days | ±0.015 mm | Ra 1.6 |

- Rule: every level of every attribute appears exactly 3 times; every level pair across any two attributes appears exactly once. Check card 2 vs card 6: price differs, lead differs, tol differs, finish differs — never confounded.

## Slide 3 — Data collection (10 min)
- Respondent sorts the 9 physical cards (each shows ALL 4 attributes — that is "full profile") and assigns rank 1 (most preferred) through rank 9.
- Our synthetic respondent (`conjoint-ranks.csv`, seed 38001, gaussian noise σ = 0.55 on true utilities) is a procurement engineer: strongly price-driven, lead-time sensitive, mildly tolerance-sensitive, finish nearly indifferent.
- Why rank (ordinal) data with OLS: with 9 cards and 9 parameters (intercept + 8 part-worth contrasts) OLS on ranks is the classic monotonically-good-enough shortcut; monotone regression (MONANOVA) is the upgrade when rank inversions matter.

## Slide 4 — Estimation: OLS with effect coding (25 min, worked)
- Effect coding per attribute: two dummy columns; level 2 coded as −(sum of the other two) so coefficients deviate from the grand mean and the three part-worths of an attribute sum to zero.
- The key solves the 9×9 normal equations with plain Gaussian elimination (stdlib only) and prints:

```
intercept b0 (mean rank) = 5.000
  b(price:lvl0) = +3.000   b(price:lvl1) = -0.667
  b(lead:lvl0)  = +1.667   b(lead:lvl1)  = -0.333
  b(tol:lvl0)   = -0.333   b(tol:lvl1)   = +0.000
  b(finish:lvl0)= -0.333   b(finish:lvl1)= +0.000
```

- Part-worth table (attribute levels sum to zero per attribute):

| attribute | level part-worths (rank scale) |
|---|---|
| price | $52.00: **+3.000**, $38.00: −0.667, $30.00: −2.333 |
| lead | 15 days: +1.667, 10 days: −0.333, 7 days: −1.333 |
| tol | ±0.025: −0.333, ±0.015: 0.000, ±0.008: +0.333 |
| finish | Ra 1.6: −0.333, Ra 0.8: 0.000, Ra 0.4: +0.333 |

- Direction law (the trap): dependent variable is rank, 1 = best. Negative coefficient ⇒ preferred level. So the *negative* price part-worths mean cheap is preferred — read the sign before you brief anyone.

## Slide 5 — Attribute importance (15 min, derived)
Importance = range of part-worths within the attribute ÷ total range:

```
price   range = 5.333  importance = 55.2%
lead    range = 3.000  importance = 31.0%
tol     range = 0.667  importance =  6.9%
finish  range = 0.667  importance =  6.9%
```

- Coherence with the case: price (CTQ-3) and lead time (CTQ-2) dominate this buyer; tolerance (CTQ-1) matters only 7% — a pointed finding for the QFD "how much" targets: chasing ±0.008 mm adds cost the customer won't pay for at these trade-off rates.
- Ranking is *derived from the ranks*, never asserted — that is the course-wide provenance law applied to survey data.

## Slide 6 — Scoring the full 81-profile space (10 min, worked)
The key scores every profile and reports:

```
BEST (predicted rank 1): u = -4.333  [price=$30.00, lead=7 days,
                                      tol=±0.025 mm, finish=Ra 1.6]
WORST (predicted rank 9): u = +5.333 [price=$52.00, lead=15 days,
                                      tol=±0.008 mm, finish=Ra 0.4]
```

- Additivity caveat: the best profile adds part-worths; real buyers show interaction (budget caps, must-meet specs). Conjoint gives the linear map; validation card(s) — a 10th card not in the L9 — is the standing check.
- Business read: the model says a $30 / 7-day offer wins this buyer even at loose tolerance — but module 37/40 show what loose tolerance does to process capability; conjoint optimizes demand, not manufacturability. The Black Belt presents both curves.

## Slide 7 — Why-it-works (10 min)
- Orthogonal design ⇒ design matrix columns uncorrelated ⇒ each part-worth contrast is identified by a one-degree-of-freedom contrast on 9 numbers; OLS degenerates toward simple averages.
- Effect coding (not dummy coding) makes each attribute's part-worths sum to zero, so importance ranges are comparable across attributes on one scale.
- 9 judgments > 8 free parameters: exactly identified, zero residual df — which is why real studies add holdout cards and more respondents; each respondent adds replicates and the pooled model gains df.

## Lab — candidate executes (60 min)
1. `python3 data/compute.py` → exit 0; verify the part-worth table and importance percentages match slides 4–5.
2. Hand-compute the price attribute's importance directly from the card ranks: average rank of the three $30 cards vs the three $52 cards, confirm the ordering direction.
3. Add a 10th holdout card of your own choosing, score it with the part-worth model, compare to your own gut ranking; report the rank error.
4. Re-run the key with the rank column reversed (9 = best) and show every coefficient flips sign while importances are unchanged — proving importance is sign-invariant but preference direction is not.
5. Court question: why can't you estimate price×lead interaction from an L9? (Answer to demonstrate: df budget — 9 runs, 8 parameters already saturate the main-effects model.)

## Court / self-check (exit-checked)
- `python3 data/compute.py` exits 0; all printed numbers above re-derive from the CSVs.
- Non-vacuity: swap two cards' rank values in `conjoint-ranks.csv` and confirm the part-worths move; restore from seed.
- The L9 balance property is checkable in one line: for each attribute pair, count level-pair occurrences — candidate writes that check and shows 1 occurrence per pair.

## See also
Module 04 (VoC), 05 (QFD — importance feeds the house of quality), 29–30 (orthogonal arrays in DOE context), 40 (Taguchi inner arrays reuse the same OA machinery).

# Module 05 — Quality Function Deployment (Slides Outline)

**Module**: 05-qfd
**Learning objectives** — after this module the Black Belt candidate can:
1. Build a full house of quality: customer requirements with importance weights, engineering characteristics, a 9/3/1 relationship matrix, the correlation roof, and a targets-vs-baseline row.
2. Compute technical importance (weighted column totals) from the matrix and defend the resulting EC priority order.
3. Tie EC targets to measurable spine math: bore internal tolerance ±0.008 mm justified by Cpk = 0.008/(3×0.0020) = 1.33; lead time 18.4 d → ≤ 7 d; unit cost $41.80 → ≤ $28.50.
4. Read the correlation roof as a tradeoff instrument: find the EC with the most conflicts (EC5 cost, 4 negatives) and state the design consequence (reduce process σ, not tighten specs).
5. Deploy the same mechanics to a transactional process (insurance claims SLA) with weights re-derived by a second method (direct rating, normalized).
6. Maintain traceability: CR ids forward from Module 04 Kano output; targets forward to Lane 03 costing (module 06) and the Measure-phase capability study (module 12).

**Timing estimate**: 5.0 h total (slides 1.5 h, lab 2.0 h, exercises 1.0 h, court/self-check 0.5 h).
**Required tools**: python3 (stdlib only: `csv`, `fractions`), terminal. Re-run `data/court.py` for every number.

**Data** (`data/`, deterministic authored design data — no RNG, seed N/A, registered in MANIFEST):
`qfd-cppc-weights.csv` (CR table + points100), `qfd-cppc-matrix.csv`, `qfd-cppc-roof.csv`, `qfd-cppc-targets.csv`, `qfd-claims-weights.csv`, `qfd-claims-matrix.csv`, `qfd-claims-roof.csv`. Generator: `gen_qfd.py` (byte-identical on rerun).

---

## Slide 1 — Why QFD (10 min)
- VOC produces requirements; QFD converts them into engineering characteristics with priorities — the translation layer between Measure and Explore.
- Without QFD, EC targets are set by whoever shouts loudest; with QFD, every EC priority is a weighted sum anyone can recompute.
- CPPC frame: 9 CRs from Module 04 → 6 ECs for the gimbal machining line.

## Slide 2 — The house of quality, room by room (20 min)
1. Left wing: CRs + importance points (Module 04 output; sum exactly 100).
2. Ceiling: ECs — measurable, controllable, one owner each.
3. Body: relationship matrix, vocabulary restricted to {9 strong, 3 moderate, 1 weak, blank none}. Any other value is a court failure.
4. Roof: EC↔EC correlations {++, +, 0, −, −−} over all C(6,2) = 15 pairs.
5. Footer: row sums (coverage check per CR), weighted column totals (technical importance), targets vs baselines.

## Slide 3 — Importance weights (15 min)
- Forwarded from Module 04 paired ranking: CR1 18, CR2 20, CR3 9, CR4 16, CR5 13, CR6 11, CR7 7, CR8 4, CR9 2 — largest-remainder allocation, sum 100.
- Secondary method taught in the lab: direct rating 1–10 normalized (claims QFD), showing that METHOD changes weights but not mechanics.

## Slide 4 — Technical importance and what it buys (15 min)
- Column total EC_i = Σ_CR w_CR × cell(CR, EC). CPPC results: EC1 241, EC2 209, EC3 180, EC4 157, EC5 173, EC6 78; total 1038 (conservation: Σrows ≡ Σcols).
- Priority order: bore tolerance > surface finish > leak-test > cost > lead time > etch. Note cost ranks 4th by importance but carries the most roof conflicts — importance alone never justifies a target.

## Slide 5 — The correlation roof as a tradeoff instrument (15 min)
- EC5 (unit cost) is negative in 4 of 15 pairs: −− with EC1 (tighter bore tolerance raises machining cost), − with EC2 (finer finish), − with EC3 (leak prevention), − with EC6 (etching).
- Design consequence taught: you cannot buy Cpk by tightening the print. The ±0.008 mm internal guard-band is reached by REDUCING process sigma to ≤ 2.0 um, not by inspection.

## Slide 6 — Targets tied to spine math (15 min)
- EC1: 12.000 ± 0.008 mm internal guard-band at σ ≤ 2.0 um, centered ⇒ Cpk = 0.008/(3×0.0020) = 1.33 (the Define-gate target). Z vs customer spec ±0.025 mm = 12.5σ.
- Honest flag (registered in MANIFEST), RESOLVED: the ORIGINAL spine sigma 4.17 um computed Cpk 1.279 from pinned mu 12.009, so the original pair did not re-derive. ADJUDICATED 2026-11-04 (see RUNNING-CASE.md): the consistent pair mu 12.009 mm / sigma 7.407 um → Cpk 0.72 is the spine law (see root MANIFEST.md, module-16 row). Module 05 uses the adjudicated constant for the baseline column. Never silently inherit both pairs.
- EC4: 18.4 d → ≤ 7 d (spine CTQ-2). EC5: $41.80 → ≤ $28.50 (spine CTQ-3, Lane 03 costing module 06).

## Slide 7 — Transactional QFD (10 min)
- Same mechanics, second weight method: 6 claims CRs rated 1–10, normalized to 22/20/7/15/13/23.
- Transactional ECs: decision cycle time, first-pass yield, rework loops, digital adoption, complaints, audit exceptions.

## Slide 8 — Gate check (10 min)
- Explore-entry gate: (a) every EC has a measurable target + baseline, (b) column totals re-derive from the matrix CSV, (c) roof census complete (15/15 pairs), (d) court exits 0.
- Forward contracts: EC5 target forwards to module 06 target costing; EC1/EC4 forwards to module 12 capability study; total importance 1038 is the baseline for module 16 concept selection scoring.

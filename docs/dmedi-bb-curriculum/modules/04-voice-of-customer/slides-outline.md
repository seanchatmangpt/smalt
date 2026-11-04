# Module 04 — Voice of the Customer (Slides Outline)

**Module**: 04-voice-of-customer
**Learning objectives** — after this module the Black Belt candidate can:
1. Run three VOC capture methods — semi-structured customer interviews (with a tested interview guide), Kano questionnaires, and direct observation — and state what each method is uniquely good at finding.
2. Design a Kano questionnaire: functional/dysfunctional question pairs, the 3×3 evaluation table, and the six response classes (M/O/A/I/R) plus the questionable (Q) cell.
3. Evaluate a completed Kano survey on the CPPC gimbal Kano attributes (K-01..K-10), classifying each of the 10 attributes by majority class with SI/DSI indices.
4. Convert ranked customer requirements (CR1–CR9) into normalized importance weights that sum to 1.0 and to 100 points, as the forward input to Module 05 QFD.
5. Route Kano results into the CTQ tree: drop indifferent attributes (K-09), retain contractual deliverables even when indifferent (K-10), and pin measurable specs to the running-case spine.

**Timing estimate**: 4.5 h total (slides 1.5 h, lab 1.5 h, exercises 1.0 h, court/self-check 0.5 h).
**Required tools**: python3 (stdlib only: `csv`, `collections`), terminal. All computation re-runs `data/compute.py` — no statistical packages required.

**Data** (seed-stated, re-derivable): `data/kano-responses.csv` (SEED 20261104, generator `data/gen_kano.py`, 120 rows = 10 Kano attributes × 12 gimbal-customer respondents).

---

## Slide 1 — What VOC is for (10 min)
- VOC is not a suggestion box: it is the evidence layer that decides WHICH numbers the project must move.
- A CTQ without a captured customer statement is an unverified claim — it cannot pass a Define gate.
- DMEDI placement: VOC is the first Measure-phase activity; its outputs (CRs + weights) are the input contract to Module 05 (QFD).

## Slide 2 — Capture method 1: the customer interview (15 min)
- Semi-structured: fixed probe list, free-form answers. Fixed questions alone miss context; fully open interviews don't replicate.
- Interview guide anatomy (used in the lab): (a) warm-up on the customer's process, (b) current-state probe, (c) failure-story probe ("tell me about the last time…"), (d) ideal-state probe, (e) quantifier ("how often / how many / how much"), (f) closing importance ranking.
- Rules: two people per interview (asker + note-taker); record verbatim quotes; never present a solution during the interview.
- Sample dialogue included in the lab (gimbal customer, aerospace integrator).

## Slide 3 — Capture method 2: Kano questionnaire (15 min)
- Two questions per attribute: FUNCTIONAL ("if present…") and DYSFUNCTIONAL ("if absent…"), each answered {I like it / must be / neutral / can live with / dislike}.
- 5×5 answer pairs collapse to a 3×3 evaluation table:
  - (F=A, D=A) → questionable (Q) — respondent can't distinguish presence from absence; discard that response pair.
  - (F=M, D=M) → reverse (R): the customer wants it ABSENT.
  - Standard mapping otherwise (see lab table).
- Why Kano and not "rate importance 1–10": stated importance is monotone (everything is important); Kano exposes the asymmetry between satisfaction gained and dissatisfaction avoided.

## Slide 4 — Capture method 3: observation (10 min)
- Watch the customer USE the part (receiving inspection, assembly cell, teardown).
- Observation finds workarounds customers have stopped reporting (e.g., inspectors re-deburring bores before assembly).
- Output feeds the same CTQ list; mark provenance (interview / Kano / observation) on each CTQ.

## Slide 5 — From statements to CTQs (15 min)
- Affinity the verbatims → group into requirement statements → deploy to a measurable CTQ (CTQ tree).
- Every CPPC CTQ carries a measurable spec pinned to the running-case spine:
  - spine CTQ-1 (derived from K-01) bore diameter in spec: 12.000 ± 0.025 mm (baseline Cpk 0.72 pinned; see honest-flag note in solution key)
  - spine CTQ-2 (derived from K-05) order-to-ship lead time: 18.4 d baseline → ≤ 7 d target
  - spine CTQ-3 (derived from K-06) unit cost: $41.80 → ceiling $28.50 (Lane 03 costing)
- Indifferent Kano attributes are normally DROPPED: K-09 (premium packaging) is dropped. Exception taught: K-10 (weekly quality trend report) classifies indifferent but is a contractual deliverable for anchor customer A-3 — retained as CR9 at low weight.

## Slide 6 — From CTQs to importance weights (15 min)
- Method taught: paired ranking of the surviving CRs (CR1–CR9); rank 1 gets n points, rank n gets 1 point; weight = points/45.
- Forward contract: Module 05 QFD consumes CR ids + integer points out of 100 (18/20/9/16/13/11/7/2/2, sum exactly 100).
- Zero-placeholder law: weights are re-derived by `data/compute.py` from the CSV + ranks table, never remembered.

## Slide 7 — Gate check (10 min)
- Measure-phase VOC gate: (a) ≥ 3 capture methods used, (b) Kano table complete for all CTQs, (c) weights re-derive from the raw CSV via the court script and exit 0.
- Falsifier: a VOC pack whose weight column does not re-derive from its own CSV is refused at the gate.

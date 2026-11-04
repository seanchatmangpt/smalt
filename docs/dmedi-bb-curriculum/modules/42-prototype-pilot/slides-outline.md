# Module 42 — Prototype and Pilot (Slides Outline)

**Module**: 42-prototype-pilot
**Learning objectives** — after this module the Black Belt candidate can:
1. Choose the right prototype/pilot vehicle by asking what QUESTION each answers, and compare candidates on cost, fidelity, and falsifiability.
2. Size a pilot lot from the confidence requirement on a Cpk estimate (not from calendar convenience).
3. Write pilot exit criteria where every criterion carries a named statistical test with a decision rule that can exit nonzero.
4. Run the CPPC 30-day pilot on the seeded dataset and re-derive every exit number from the raw CSV.
5. Recognize the vacuity failure case: a pilot that "feels done" with no measurable exit is not a pilot, it is a demo.

**Timing estimate**: 4.5 h total (slides 1.5 h, lab 1.5 h, exercises 1.0 h, court/self-check 0.5 h).
**Required tools**: python3 (stdlib only: `random`, `statistics`, `csv`, `math`), a terminal. No statistical packages required.

---

## Slide 1 — Where Implement begins (10 min)
- Develop produced a designed process with a predicted capability. Implement must PROVE the prediction on the real line.
- A prototype answers "does the design work at all"; a pilot answers "does the process hold capability in production".
- The Implement gate (week 21) passes on receipts: sustained Cpk ≥ 1.33 over 30 days for CTQ-1, per the running case.
- Anti-pattern carried from Module 01: a phase is done only when its artifacts exist and their numbers re-derive.

## Slide 2 — What question does each vehicle answer? (15 min)
| Vehicle | Question answered | Evidence produced |
|---|---|---|
| Desktop prototype | Does the geometry close? | CAD/stack-up report |
| Functional prototype | Does one part work? | Test report on n=1..10 parts |
| Pre-production prototype lot | Can the process make conforming parts once? | Capability snapshot on one lot |
| Pilot (production run) | Does the process HOLD capability over time? | Control charts + 30-day capability |
| Ramp | Does the process hold at rate? | Capability at full takt |

- Falsifiability rises left to right: a desktop prototype cannot fail the Cpk gate; only the pilot can.
- CPPC decision: the question at week 16 is "does the developed process hold Cpk ≥ 1.33" → a pilot, not another prototype.

## Slide 3 — Cost / fidelity / falsifiability comparison (15 min)
| Vehicle | Relative cost | Production fidelity | Can it falsify the Develop claim? |
|---|---|---|---|
| Desktop prototype | $ (hours) | none | no — no process variance |
| Functional prototype (n=10) | $$ | low | weakly — small n, wide CI |
| Prototype lot (n=120) | $$$ | high | yes — CI computable |
| 30-day pilot (n=1200) | $$$$ | production | yes — CI + stability evidence |
- Rule: spend money only where the question's answer can EXIT NONZERO.
- A $$$$ pilot run before the $$ prototype lot questions are answered wastes the higher-fidelity vehicle on untested design.

## Slide 4 — Pilot lot size from Cpk confidence (20 min)
- The point estimate is not the claim. The claim is the 95% lower confidence bound.
- Normal-approximation standard error of Cpk: SE = sqrt( 1/(9n) + Cpk^2 / (2(n−1)) ).
- CPPC design margin: DOE-selected settings predict Cpk ≈ 1.50; gate needs the LCB ≥ 1.33.
- Solve 1.50 − 1.645·SE(1.50, n) ≥ 1.33 → n ≥ 117 → pilot lot = 120 pieces (3 production days × 40 measured pieces/day at the planned 150/day rate, 8 subgroups/day × n=5).
- After the 30-day run, n = 1200 measured pieces, SE = 0.032, LCB = Ĉpk − 0.053 — the 30-day requirement is what makes the bound tight, not the lot alone.

## Slide 5 — Exit criteria carry named tests (15 min)
- Criterion without a test = narrative. Every CPPC pilot exit criterion names its test, alpha, and decision rule:
  - Capability: Cpk 95% LCB ≥ 1.33 over the 30-day run (n=1200), computed from the raw CSV.
  - Stability: X-bar/R charts over 240 subgroups with zero Western Electric rule-1 signals.
  - Surface finish: Ra stable — I-MR chart on daily Ra, no rule-1 signals, plus two-sample t first-10 vs last-10 days (alpha=0.05) to detect drift the chart's limits (fit to the same run) cannot.
- Each criterion can FAIL. A criterion that cannot fail is decoration.

## Slide 6 — The vacuous-pilot failure case (15 min)
- Failure mode: pilot runs, shop reports "parts look good", gate passes on narration.
- What is missing: no pinned n, no named test, no alpha, no decision rule — the gate cannot exit nonzero.
- Encoded lesson: exit criteria are written BEFORE the pilot runs, each with a named test whose inputs are pinned (alpha, n, target, decision rule).
- CPPC court: re-derive every number from the seeded CSVs; any mismatch exits 1.

## Slide 7 — What a pilot receipt looks like (10 min)
- Fields: identity (seeded datasets + exact command), authority (week-21 gate), consequence (numbers above), replay (python3 commands in the solution key), standing (PASS/FAIL per criterion as of date).
- The pilot receipt feeds Module 43 (control plan) and Module 44 (handoff package).

## Slide 8 — Recap and lab handoff (5 min)
- Total: 100 min of slide time. Lab: run the pilot exit checks on the seeded data and write the receipt.

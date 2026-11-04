# Module 43 — Process Control (Slides Outline)

**Module**: 43-process-control
**Learning objectives** — after this module the Black Belt candidate can:
1. Write a control plan where every control-method row links back to a DFMEA row: failure mode ↔ cause ↔ control method ↔ detection.
2. Compute X-bar/R control limits for the CPPC bore operation from the Module 42 pilot data and distinguish control limits from spec limits.
3. Specify the SPC handoff: which charts, which detection rules, who reacts, and how findings escalate.
4. Write an Out-of-Control Action Plan (OCAP) in a fixed format that names containment before investigation.
5. Explain the vacancy test for a control plan: if no row can ever trigger its reaction plan, the plan is decoration.

**Timing estimate**: 4.0 h total (slides 1.5 h, lab 1.0 h, exercises 1.0 h, court/self-check 0.5 h).
**Required tools**: python3 (stdlib only), a terminal.

---

## Slide 1 — Control is a plan, not a chart (10 min)
- A control chart is one row of a control plan. The plan names characteristic, spec, gauge, sample, chart, reaction, owner.
- The control plan is the contract between the project team and the process owner (Module 44 handoff).
- CPPC: the week-26 gate requires a signed control plan linked to the DFMEA.

## Slide 2 — Control plan template, row by row (15 min)
| field | meaning | CPPC bore example |
|---|---|---|
| process step | operation under control | OP30 — finish bore |
| characteristic | what is measured | bore diameter (CTQ-1) |
| specification | limits + target | 12.000 ± 0.025 mm |
| DFMEA ref | failure mode this control detects | oversize bore / tool wear (DFMEA row, lane 11 register) |
| evaluation | measurement method | air gauge, Module 11 MSA-accepted (%GRR ≤ 10% of tolerance) |
| sample size / freq | subgroup + rate | n = 5 every 2 h (8 subgroups/day over two shifts) |
| control method | chart type + rules | X-bar/R, rule 1 (+ rules 2–5 optional) |
| reaction plan | what happens on a signal | OCAP-BORE-01 (stop, contain, investigate) |
| owner | who reacts | shift leader (react), quality engineer (investigate) |

- Every row must name its DFMEA reference: a control with no failure mode is cost with no risk behind it; a failure mode with no control is unmanaged risk.

## Slide 3 — Control limits vs spec limits (10 min)
- Control limits come from the process (R-bar arithmetic); spec limits come from the customer. They are never drawn on the same axis as if comparable.
- Worked numbers from the Module 42 pilot (n = 5, A2 = 0.577, D3 = 0, D4 = 2.114):
  X-double-bar = 12.0049, R-bar = 0.0102 → UCL(X-bar) = 12.0108, LCL(X-bar) = 11.9990, UCL(R) = 0.0216.
- sigma-hat = R-bar/d2 = 0.010217/2.326 = 0.004392 mm → PCR = 0.050/0.02635 = 1.897.
- The natural process spread (6σ = 0.02635 mm) fits inside the tolerance (0.050 mm) — that is WHY the chart limits sit comfortably inside the spec.

## Slide 4 — SPC handoff spec (15 min)
| measurement | chart | subgroup | detection rules | reactor | escalation |
|---|---|---|---|---|---|
| bore diameter | X-bar/R | n=5 / 2 h | rule 1 mandatory; rules 2–5 advisory | shift leader | quality engineer → MRB if parts at risk |
| surface finish Ra | I-MR (daily individuals) | 1/day | rule 1 | process engineer | tooling review |
| scrap rate | p-chart (n = 150/day) | 1/day | rule 1 | shift leader | cost review if UCL breached 2 days in a row |
- Handoff cadence: charts reviewed every shift; weekly summary to the process owner; monthly capability recheck (first 90 days).

## Slide 5 — OCAP format (15 min)
- Fixed fields, always in this order: SIGNAL (which chart/rule/point) → CONTAIN (quarantine suspect parts — since last in-control point) → DIAGNOSE (named cause list: tool wear, thermal drift, gauge fault, setup) → DISPOSITION (contained parts; adjust vs reject) → VERIFY (re-establish control; evidence required) → RECORD (log entry, MRB if scrap).
- Ordering law: containment precedes diagnosis — you quarantine the output before you touch the process.
- Anti-pattern: "adjust the machine and keep running" — that treats a signal as noise and destroys the chart's history.

## Slide 6 — The vacuous control plan (10 min)
- Failure case: a control plan with reaction plans never triggered in a year — not because the process was calm, but because no subgroup was ever plotted.
- Vacuity test: pick any row, simulate a rule-1 violation, and confirm the named OCAP exists with named owners. A row that cannot fail is decoration.

## Slide 7 — Recap and lab handoff (5 min)
- Lab: compute the bore-operation limits from pilot data, fill the control plan row set, and write OCAP-BORE-01.

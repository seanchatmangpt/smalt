# Module 44 Solution Key — Roadmap, Training, Audit, Handoff

**Baseline convention**: Module 01 / defect CLD-01 pair (Cpk 0.72, σ = 7.407 µm) for Measure-phase framing; pilot exit numbers are independent of that defect.

## Part 1 — Roadmap on the 26-week calendar

Program: 26 weeks; gates at weeks 5/9/15/21/26 (RUNNING-CASE.md). Implement = weeks 16–26.

| phase | weeks | content | exit |
|---|---|---|---|
| Develop closeout / prototype lot | 16 | 120-piece lot (3 days × 40 measured/day), confirms predicted Cpk 1.50 on one lot | lot Cpk LCB ≥ 1.33 |
| Pilot run | 16.5–20.8 | 30-day pilot at 150 pieces/day (starts week-16 day 4, immediately after the 3-day prototype lot); Module 42's four named exit tests | 4/4 criteria PASS |
| Week-21 gate | 21 | pilot exit review; Module 43 control plan approved; rollout approved | gate receipt |
| Rollout | 22–24 | production release; SPC live at rate; deviations tracked | zero unresolved OCAPs entering week 24 |
| Training | 21–24 | role matrix below, evidence-signed | 20/20 records |
| Audit + package assembly | 24–26 | layered audits; Module 44 court; handoff package assembled | audits complete, court exit 0 |
| Week-26 gate / handoff | 26 | checklist 7/7 signed, package transferred | week-26 receipt |

Arithmetic: 30 pilot days = 4.29 weeks (30/7). The prototype lot occupies week-16 days 1–3; the pilot starts week-16 day 4 (week 16.5) and ends at week 20.8 — before the week-21 gate, which consumes the pilot receipt. Counterfactual (proved by the court): a week-17 start ends at week 21.29, PAST the gate. Weeks 22–26 cover rollout/training/audit; the handoff is the week-26 event. No gaps, no overlaps.

## Part 2 — Training plan (who learns what)

20 role slots: 12 operators + 3 inspectors + 3 shift leaders + 1 process engineer + 1 quality manager; window weeks 21–24.

| role | learns | completion evidence |
|---|---|---|
| operator (12) | subgroup sampling discipline, chart plotting, OCAP containment step | 3 supervised subgroups + 1 simulated rule-1 containment, signed by shift leader |
| inspector (3) | air-gauge master checks, MSA sustainment, logging | repeat short-form MSA: %GRR ≤ 10% of tolerance re-demonstrated |
| shift leader (3) | rules 1–5 detection, OCAP-BORE-01 execution, quarantine | 1 witnessed OCAP drill (day-1-style scrap signal) |
| process engineer (1) | limit recalculation, capability recheck, OCAP DIAGNOSE/VERIFY | recalculated limits match court values (UCL 12.0108 / LCL 11.9990 / UCL-R 0.0216) |
| quality manager (1) | gate receipts, MRB, audit cadence ownership | handoff checklist signed |

Evidence, not attendance: every completion evidence is an observable artifact that can fail.

## Part 3 — Audit cadence

| period | cadence | content |
|---|---|---|
| weeks 22–26 | weekly | layered process audit: subgroups plotted as scheduled, OCAP drill, control plan current |
| months 2–3 | biweekly → monthly | capability recheck vs Cpk 1.33; p-chart review; gauge calibration records |
| month 4+ | quarterly | control-plan review: re-run Module 43 court; capability recheck |

Decay law: cadence decays only when the preceding period is clean (zero missed subgroups, zero unresolved OCAPs). Escalation back up: any rule-1 signal or missed-subgroup week restores weekly cadence. Exercise 2 answer: NO — the decay law is violated; two missed-subgroup weeks alone restore weekly cadence.

## Part 4 — Handoff package (closing-the-loop checklist)

| # | artifact | source | acceptance |
|---|---|---|---|
| 1 | Control plan (signed) | Module 43 | every row DFMEA-linked; OCAP refs live |
| 2 | OCAPs BORE-01, BORE-02, SCRAP-01 | Module 43 | containment precedes diagnosis in all three |
| 3 | Capability evidence (pilot receipt) | Module 42 | Cpk 1.481, LCB 1.429 ≥ 1.33 over 30 days (n=1200) |
| 4 | MSA evidence | Module 11 | %GRR ≤ 10% of tolerance, court-passed |
| 5 | Training records | Module 44 lab | 20/20 signed |
| 6 | Audit record | Module 44 lab | weeks 24–26 audits logged |
| 7 | 26-week program receipt | all modules | replay commands for every number |

Refusal law: any missing item → typed week-26 refusal naming the gate, the item, its source module, and the close condition (see Exercise 3).

## Part 5 — Program receipt (week 26)

| field | content |
|---|---|
| identity | CPPC SR-71 drone-gimbal CNC line (al 7075, 3-axis mill), 26-week DMEDI program |
| authority | week-21 and week-26 gate reviews per RUNNING-CASE.md calendar |
| consequence | CTQ-1: Cpk 1.481 (LCB 1.429) vs target ≥ 1.33 sustained 30 days — PASS; CTQ-2 lead time and CTQ-3 cost receipts owned by their lanes (Modules 03/13-series) |
| replay | `python3 modules/42-prototype-pilot/court.py && python3 modules/43-process-control/court.py && python3 modules/44-implementation-planning/court.py` from the curriculum root — all exit 0 |
| standing | handoff checklist 7/7, PASS as of 2026-11-04, contingent on Module 11 MSA artifact landing |

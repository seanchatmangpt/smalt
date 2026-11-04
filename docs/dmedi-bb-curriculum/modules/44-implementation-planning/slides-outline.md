# Module 44 — Implementation Planning (Slides Outline)

**Module**: 44-implementation-planning
**Learning objectives** — after this module the Black Belt candidate can:
1. Build an implementation roadmap (pilots → rollout → training → audit) mapped to the CPPC 26-week calendar and verify its week arithmetic with python3.
2. Write a role-keyed training plan whose completion evidence is named.
3. Set an audit cadence that decays as control evidence accumulates.
4. Assemble the stakeholder handoff package: control plan, OCAPs, capability evidence, MSA evidence, training records — the closing-the-loop checklist, each item exit-checked to exist.
5. Refuse a handoff with any missing item: a handoff without a named artifact is a narrative, not a transition.

**Timing estimate**: 3.5 h total (slides 1.0 h, lab 1.0 h, exercises 1.0 h, court/self-check 0.5 h).
**Required tools**: python3 (stdlib only), a terminal.

---

## Slide 1 — The last gate is a handoff, not a party (10 min)
- The week-26 gate: the process owner can RUN the process without the Black Belt. Everything needed must already exist as an artifact.
- The closing-the-loop checklist is the gate check: five artifact families, each with a receipt.

## Slide 2 — Roadmap mapped to the 26-week calendar (15 min)
- Gates at weeks 5/9/15/21/26 (RUNNING-CASE.md). Implement = weeks 16–26. Arithmetic note: a 30-day pilot is 4.29 weeks, so it must START mid-week 16 to exit before the week-21 gate — a week-17 start would end at week 21.3, past the gate. The court proves this.
- Roadmap below; the court re-derives every week span (no overlaps, no gaps, gate-week boundaries aligned).

| phase | weeks | content | exit |
|---|---|---|---|
| Develop closeout | 16 | prototype lot (120 pieces = 3 days), confirm predicted Cpk 1.50 on one lot | lot Cpk LCB ≥ 1.33 |
| Pilot run | 16.5–20.8 | 30-day pilot (starts week-16 day 4, after the 3-day prototype lot), 150/day, Module 42 exit criteria (4 named tests) | Module 42 receipt: 4/4 PASS |
| Week-21 gate | 21 | pilot exit review + control plan (Module 43) approved + rollout approval | gate receipt |
| Rollout | 22–24 | line released to production; SPC live at production rate; deviation requests tracked |
| Training | 21–24 | operator/inspector/lead training windows (Slide 3 matrix) |
| Audit | 24–26 | layered process audits; Module 44 court runs; handoff package assembled |
| Handoff | 26 | week-26 gate: handoff package signed, checklist 5/5 | week-26 receipt |

## Slide 3 — Training plan (who learns what) (15 min)
| role | learns | evidence of completion |
|---|---|
| operator (12) | subgroup sampling discipline, chart plotting, OCAP containment step | 3 supervised subgroups + 1 simulated rule-1 containment, signed by shift leader |
| inspector (3) | air-gauge masters check, MSA sustainment, measurement logging | repeat Module 11 short-form MSA, %GRR ≤ 10% re-demonstrated |
| shift leader (3) | rule 1–5 detection, OCAP-BORE-01 execution, quarantine rules | 1 witnessed OCAP drill (simulated day-1-style scrap signal) |
| process engineer (1) | limit recalculation, capability recheck, OCAP DIAGNOSE/VERIFY | recalculated limits match court values (12.0108/11.9990/0.0216) |
| quality manager (1) | gate receipts, MRB, audit cadence ownership | handoff checklist signed |

## Slide 4 — Audit cadence (10 min)
| period | cadence | content |
|---|---|---|
| weeks 22–26 | weekly | layered process audit: subgroups plotted as scheduled, OCAP drill, control plan current |
| months 2–3 | biweekly→monthly | capability recheck vs 1.33; p-chart review; gauge calibration records |
| month 4+ | quarterly | annual-control-plan review: re-run Module 43 court; capability recheck |
- Decay law: cadence decays only when the preceding period's evidence is clean (zero missed subgroups, zero unresolved OCAPs).
- Escalation back up: any rule-1 signal or missed-subgroup week restores weekly cadence.

## Slide 5 — Stakeholder handoff package (closing the loop) (15 min)
| # | artifact | source module | acceptance |
|---|---|---|
| 1 | Control plan (signed) | Module 43 | every row DFMEA-linked, OCAP refs live |
| 2 | OCAPs (BORE-01/02, SCRAP-01) | Module 43 | containment precedes diagnosis in every OCAP |
| 3 | Capability evidence | Module 42 pilot receipt | Cpk 1.481, LCB 1.429 ≥ 1.33 over 30 days |
| 4 | MSA evidence | Module 11 | %GRR ≤ 10% of tolerance, court-passed |
| 5 | Training records | Slide 3 matrix | all 20 roles filled, evidence column signed |
| 6 | Audit record | Slide 4 cadence | weeks 24–26 audits completed |
| 7 | 26-week program receipt | all modules | replay commands for every number |

- Refusal law: any missing item refuses the handoff (typed refusal, named gap).

## Slide 6 — The orphaned handoff failure case (10 min)
- Failure case: project "completed", owner left with a chart nobody plots and an OCAP nobody owns.
- Root cause: handoff treated as a ceremony, not an artifact transfer with an exit check.
- Encoded lesson: the checklist is exit-checked (court) and signed — a handoff that cannot be refused is not a gate.

## Slide 7 — Recap (5 min)
- Implement ends when the OWNER can run it. Total: 40 min of slide time; lab assembles the package.

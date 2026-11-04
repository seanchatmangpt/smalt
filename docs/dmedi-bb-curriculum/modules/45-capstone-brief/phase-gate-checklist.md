# Phase-Gate Checklist — Capstone (Module 45)

Reviewer's instrument for the five gate reviews. Each gate lists its deliverables checklist,
the GATE QUESTION, and the reject conditions. A gate verdict is PASS / FAIL / RESUBMIT;
RESUBMIT carries a dated re-review. Skipped gates void all downstream gates (brief §4).

## Gate 1 — Define (week 5)

**Gate question**: *If I stopped this project today, would the charter alone tell me what
success measured, who is accountable, and what could kill it — with numbers, not adjectives?*

- [ ] Charter complete on Module 03 template, sponsor-signed
- [ ] CTQ tree traceable to ≥ 1 customer statement per CTQ
- [ ] MGPP case quantified; $28.50 ceiling derived from cost buildup
- [ ] Risk register ≥ 8 risks, each with trigger + owner
- [ ] Comms plan with 5 gate reviews scheduled, attendees named
- [ ] DMEDI-vs-DMAIC framing memo present (why DMEDI for a new line)

Reject if: any CTQ lacks customer-statement traceability; the ceiling is asserted not
derived; risks lack observable triggers.

## Gate 2 — Measure (week 9)

**Gate question**: *Can I trust the numbers, and are they the numbers?*

- [ ] Gage R&R computed from gage-rr-bore.csv; %GRR + ndc + band verdict
- [ ] If %GRR > 30%: corrective action + provisional-baseline flag
- [ ] Baseline Cpk from both bore CSVs, with replay commands
- [ ] Pinned-constant discrepancy adjudicated (working pair chosen + justified)
- [ ] Baseline stability verdict explicit (capability on unstable process is inadmissible)
- [ ] QFD house complete with stated scoring convention
- [ ] COPQ baselines derived from baseline DPMO

Reject if: Cpk quoted without the command that produced it; the discrepancy silently
inherited; QFD roof asserted without a scoring convention.

## Gate 3 — Explore (week 15)

**Gate question**: *Does the selected concept win on evidence, and is its claim falsifiable?*

- [ ] ≥ 4 distinct-mechanism concepts generated
- [ ] Pugh matrix vs datum + AHP weights with CR < 0.10
- [ ] Selected concept states a falsifiable capability claim (number + CI)
- [ ] Lead-defectives excursion tested with assumptions checked
- [ ] Multi-Vari variance shares re-derive and sum to ~100%
- [ ] Regression with residual diagnostics; unexplained variance stated
- [ ] Monte Carlo: distributions, parameters, seed registered, predicted Cpk as CI

Reject if: fewer than 3 concepts scored; weights asserted without derivation; Monte Carlo
lacks stated assumptions; any test lacks its assumption check.

## Gate 4 — Develop (week 21)

**Gate question**: *Is the design proven, or merely proposed?*

- [ ] DFMEA with stated scales; ≥ 3 RPN-reduction actions, before/after RPN
- [ ] Screening DOE: resolution + aliasing named, randomized run order, effect Pareto
- [ ] RSM on surviving factors; optimum window + confirmation runs
- [ ] Predicted post-DOE Cpk stated as number with CI
- [ ] Helicopter lab: actual data + analysis + competence paragraph
- [ ] Robust design: control vs noise factors named, robust setting may differ from
      mean-optimal with reason
- [ ] Reliability allocation reconciles to MTBF 1,200 h / B10 900 h

Reject if: DOE lacks randomization or residual diagnostics; helicopter lab described but
data absent; allocation doesn't reconcile to targets; predicted capability has no CI.

## Gate 5 — Implement (week 26)

**Gate question**: *Would this line hold the gains if the Black Belt left tomorrow?*

- [ ] Pilot executed at production rate; deviations logged
- [ ] Pilot Cpk computed; before/after tests assumption-checked
- [ ] Control plan: every CTQ row has chart type + frequency + reaction rule + owner
- [ ] 30/30 consecutive daily sustainment records at/above target (or gate FAILS)
- [ ] Named owner accepted handoff (signature, not claim)
- [ ] ≥ 3 honest lessons-learned (what went wrong)
- [ ] Final receipt: identity / authority / consequence / replay / standing, all numbers
      replayable

Reject if: sustainment window has missing days; any CTQ lacks a reaction rule; the receipt
fails replay.

## Gate verdict record (reviewer fills one per gate)

```
Gate:        __  Date: ____
Question posed: ____
Verdict:     PASS / FAIL / RESUBMIT (re-review date: ____)
Deliverables missing: ____
Numbers failing replay: ____
Open risks carried forward: ____
Reviewer:    ____
```

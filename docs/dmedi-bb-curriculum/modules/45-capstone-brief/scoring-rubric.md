# Scoring Rubric — Capstone (Module 45)

Five weighted dimensions, 100 points total. Passing the capstone requires (a) total ≥ 70,
(b) the Implement dimension ≥ 9/15 (the gains must be proven held), and (c) no dimension
scoring 0 (a zero means the phase did not happen — evidence discipline forbids averaging
over it).

## Weights and their justification

| Dimension | Weight | Justification |
|---|---|---|
| Measure rigor | 20 | Everything downstream inherits the baseline: a wrong MSA verdict or an unreconciled Cpk poisons Explore, Develop, and Implement. Scored high enough that sloppy measurement alone can fail the capstone, but not the maximum — a sound baseline with weak downstream design is a real, if lesser, capstone. |
| Explore methods | 25 | Method breadth lives here (concept gen, Pugh/AHP, hypothesis testing, Multi-Vari, regression, Monte Carlo). This is the largest survey of the toolkit and the phase where concept selection is either evidenced or narrated — second-heaviest weight. |
| Develop methods | 30 | The heaviest weight, because DMEDI is a DESIGN curriculum: in a new-line program the capability is engineered in Develop (DOE program, robust design, reliability allocation). Explore selects; Develop proves. A capstone that selects well but never demonstrates a working design has not done the course's core work. The helicopter lab (skills proof) and the falsifiable predicted-Cpk claim live here. |
| Implement + control | 15 | Verification, not creation: the phase proves the design holds (pilot, control plan, 30-day sustainment, handoff). Weighted below Develop because the hard engineering happened earlier — but floor-gated at 9/15 because sustained, handed-off gains are the program's reason to exist; no amount of earlier brilliance compensates for unheld gains. |
| Documentation / evidence discipline | 10 | The honesty layer: replay commands, registered seeds, receipt fields, honest NOT-METs. Deliberately the smallest weight — it is an enabler, and its real enforcement is binary (falsifiers in brief §4 void the capstone regardless of points), so it needs no more than 10 points to matter. |

Weights sum to 100 (python3-verified; see court receipt).

## Dimension detail

### 1. Measure rigor (20)
| Points | Standard |
|---|---|
| 17–20 | MSA verdict correct with band logic applied to computed %GRR; both Cpk estimates re-derive; discrepancy adjudicated with a reasoned working pair; stability verdict explicit; QFD scoring convention stated; COPQ derived from DPMO. |
| 12–16 | MSA + capability correct but reconciliation shallow, or one secondary artifact (COPQ/QFD) thin. |
| 6–11 | Numbers right but partially unreplayable, or discrepancy handled mechanically. |
| 1–5 | Capability quoted without derivation; MSA verdict wrong or missing. |
| 0 | Phase not performed. |

### 2. Explore methods (25)
| Points | Standard |
|---|---|
| 21–25 | ≥ 4 distinct concepts; Pugh+AHP with CR < 0.10; all tests assumption-checked; Multi-Vari shares re-derive; regression diagnosed; Monte Carlo fully stated with CI. Selection follows from evidence. |
| 15–20 | Methods all present, one executed shallowly (e.g. AHP without CR, MC without sensitivity). |
| 8–14 | 2–3 method families missing or executed without assumption checks. |
| 1–7 | Concept selected by assertion; tests report p-values without checks. |
| 0 | Phase not performed. |

### 3. Develop methods (30)
| Points | Standard |
|---|---|
| 25–30 | Screening + RSM with aliasing, randomization, diagnostics, confirmation gap in CI; predicted Cpk falsifiable; robust setting reasoned; reliability reconciles; helicopter lab run with data. |
| 18–24 | DOE program complete but one element thin (e.g. robust design mechanical, confirmation runs missing). |
| 10–17 | DOE present without diagnostics/aliasing discipline, or reliability unreconciled, or lab not run. |
| 1–9 | Design proposed, never tested; no falsifiable capability claim. |
| 0 | Phase not performed. |

### 4. Implement + control (15)
| Points | Standard |
|---|---|
| 13–15 | Pilot at rate with logged deviations; assumption-checked comparisons; complete control plan; 30/30 sustainment; signed handoff; ≥ 3 honest lessons. |
| 9–12 | Pilot + control plan complete; sustainment complete; minor gaps (lessons thin, one reaction rule vague). |
| 4–8 | Pilot ran but control plan has gaps, or sustainment window incomplete. |
| 1–3 | Handoff narrated, not evidenced. |
| 0 | Phase not performed. |

### 5. Documentation / evidence discipline (10)
| Points | Standard |
|---|---|
| 9–10 | Every number replays; seeds registered; receipt five-field complete; honest NOT-METs where true. |
| 6–8 | Mostly replayable; a few commands missing; receipt complete. |
| 3–5 | Receipts partial; replay requires hand-holding; some unregistered data. |
| 1–2 | Claims without commands; receipt fields missing. |
| 0 | No evidence discipline at all — triggers brief §4 falsifier review. |

## Scoring procedure (reviewer)

1. Score each dimension bottom band first: find the highest band whose conditions are ALL
   met. Never average up from partial conditions.
2. Apply the floors and the zero rule.
3. Record per-dimension one-line evidence citations (workbook section refs).
4. Any falsifier in brief §4 → capstone void regardless of score.

```
Score record:  Measure __/20  Explore __/25  Develop __/30  Implement __/15
               Documentation __/10   TOTAL __/100
Floors:        Implement >= 9? __   No dimension = 0? __
Falsifier check: ____
Verdict: ____
```

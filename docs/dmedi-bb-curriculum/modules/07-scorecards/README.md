# Module 07 — Scorecards (all three spine CTQs)

Six Sigma DMEDI Black Belt curriculum — CPPC running case. Pinned spine:
`../../RUNNING-CASE.md`.

## Learning objectives

After this module the BB candidate can:

1. Build a CTQ -> Y -> x hierarchy for product, transactional, and cost CTQs,
   with every x measurable at a setpoint or threshold.
2. Write operational definitions that pin gauge, sample, frequency, and
   calculation — a metric missing any field is not scorecard-eligible.
3. Design a data-collection plan that traces every metric to a collector,
   method, recording system, and stratification, honoring the case's data
   provenance law.
4. Split leading from lagging measures and wire reaction rules so leading
   misses avert lagging failures.
5. Trace every scorecard metric into the MGPP (Master Gate/Phase Plan) so each
   gate review (weeks 5/9/15/21/26) has its exit criteria on the scorecard.

## Bundle contents

| File | Content |
|---|---|
| `worksheets/01-hierarchy.md` | CTQ -> Y -> x for CTQ-1 (bore), CTQ-2 (lead time), CTQ-3 (cost) |
| `worksheets/02-operational-definitions.md` | OD-1..OD-15 with gauge/sample/frequency/calculation |
| `worksheets/03-data-collection-plan.md` | collector, method, system, stratification, checks |
| `worksheets/04-leading-lagging.md` | split + reaction rules |
| `worksheets/05-mgpp-traceability.md` | metric -> CTQ -> gate -> criterion -> owner matrix |
| `courts/court.py` | arithmetic re-derivation + structural completeness; exit 0 required |

## Court (exit-checked)

```
python3 courts/court.py
```

Re-derives: lead-time decomposition (11.2+3.1+2.6+1.5 = 18.4 baseline;
2.5+2.4+0.6+0.5 = 6.0 <= 7 target), Cpk yield math (0.72 -> 3.077%,
1.33 -> 0.006607%), module-06 tie-outs (13.08 min cycle, $3.46 tooling,
1.05 h setup, $28.50 ceiling, 630 mm/min, 11,500 RPM). Structurally: 15 ODs
complete, data-collection plan covers every OD, MGPP matrix has every metric
exactly once with valid gate weeks and role owners.

## Cross-lane couplings

- Module 06: CTQ-3 x-targets (cycle, tooling, setup, defect rate) must equal the
  06 teardown values; the court tie-outs enforce this.
- Lane 05 (Measure): OD-2 must reproduce Cpk 0.72 from raw data.
- Lane 11 (DOE): x1.1/x1.2 setpoints are module 06's assumed optimum.
- Lane 19 (coherence court): `05-mgpp-traceability.md` is the gate-exit
  authority for weeks 9/15/21/26 metric criteria.

## Timing estimate

4.0 h total: hierarchy build walkthrough (45 min), operational-definitions
workshop (40 min), data-collection-plan exercise (35 min), leading/lagging split
with reaction rules (30 min), MGPP traceability matrix (35 min), solution-key
reconciliation vs your own worksheets (25 min), court run and debrief (30 min).

## Tool note

python3 mirror: `python3 courts/court.py` re-derives all arithmetic and structure
checks (stdlib only; 22/22 checks, exit 0 required) — the keyed derivations live
in `solution-key.md`. Minitab path: this module needs no statistical engine; the
only distribution math is the centered-normal defect rate 2 x Phi(-3 x Cpk),
computed in Minitab as Calc > Probability Distributions > Normal (cumulative,
x = -3 x Cpk, mean 0, SD 1), doubled for the two-sided rate.

# Data-Collection Plan

Who takes each measurement, where it is recorded, and how it lands in the
scorecard. Every row traces to an operational definition in
`02-operational-definitions.md` and a scorecard row in `01-hierarchy.md`.

| Metric (OD) | Collector | Method | Where recorded | Stratification | Checks |
|---|---|---|---|---|---|
| Bore diameter (OD-1) | op20 operator | CMM program BORE-12v3, auto report | MES, per-part record | by shift, machine, insert age | out-of-control points flagged same shift |
| Cpk 30-day (OD-2) | quality engineer | script over MES export | weekly scorecard workbook | none (program-level) | recompute sigma both within and overall; report both |
| RPM adherence (OD-3) | automatic | CNC log poll job | MES daily rollup | by machine | <98% triggers same-day andon |
| Feed adherence (OD-4) | automatic | CNC log poll job | MES daily rollup | by machine | <98% triggers same-day andon |
| Coolant % (OD-5) | shift lead | refractometer, logged on tablet | MES shift record | by machine | outside 8.5-9.5% -> adjust + resample |
| Tool wear (OD-6) | operator + CNC timer | insert log sheet + in-cut timer | tool crib log | by insert set ID | 48-min swap enforced by crib audit |
| Lead time (OD-7) | planner | ERP cohort query | weekly scorecard workbook | by customer segment | median + IQR reported; no mean (skewed) |
| Queue depth (OD-8) | planner | ERP release/first-cut query | daily scorecard workbook | by job size | >2.5-day median 3 days running -> WIP cap review |
| QC hold (OD-9) | quality clerk | ERP submit/disposition stamps | daily scorecard workbook | by lot | until OD-11 proven, then sampled lots only |
| Ship docs (OD-10) | shipping clerk | ERP stamps | weekly scorecard workbook | by clerk? no — by carrier only | privacy: no per-clerk stratification |
| Cycle time (OD-11) | automatic | CNC cycle timer | MES daily rollup | by op, machine | exclude machine-down intervals |
| Bore FPY (OD-12) | quality engineer | OD-1 + scrap ledger join | weekly scorecard workbook | by defect code | reconcile scrap ledger monthly |
| Changeover hours (OD-13) | SMED observer | clocked sheet | SMED board + MES | internal vs external steps | post-SMED: audit 1-in-4 changeovers |
| Tooling $/unit (OD-14) | finance analyst | crib log vs completions | monthly scorecard workbook | by insert type | ties to ERP spend ledger monthly |
| Billet price (OD-15) | purchasing | quote register | monthly scorecard workbook | by mill | contract-price variance flagged |

## Provenance law (RUNNING-CASE.md)

Synthetic training datasets generated for these metrics must carry a STATED seed
registered in `datasets/MANIFEST.md` by the owning lane, and any solution key
re-derives from the raw CSV. This module consumes no dataset directly; its court
re-derives arithmetic from the worksheets.

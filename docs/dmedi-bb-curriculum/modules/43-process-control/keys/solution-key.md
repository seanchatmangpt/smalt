# Module 43 Solution Key — Control Plan (all numbers re-derived from Module 42 pilot data, seed 42016)

## Part 1 — Bore-operation control limits (n = 5, 240 subgroups)

Source: `modules/42-prototype-pilot/data/pilot-bore-30day.csv`.

| quantity | formula | value |
|---|---|---|
| X-double-bar | mean of 240 subgroup means | 12.0049 mm |
| R-bar | mean of 240 ranges | 0.0102 mm |
| UCL(X-bar) | Xbb + A2·Rbar, A2 = 0.577 | 12.0108 mm |
| LCL(X-bar) | Xbb − A2·Rbar | 11.9990 mm |
| UCL(R) | D4·Rbar, D4 = 2.114 | 0.0216 mm |
| LCL(R) | D3·Rbar, D3 = 0 | 0 mm |
| sigma-hat | Rbar / d2, d2 = 2.326 (R-bar = 0.010217) | 0.004392 mm |
| PCR | 0.050 / (6 × 0.004392) = 0.050/0.02635 | 1.897 |

Limits-inside-specs: LCL(X-bar) 11.9990 > LSL 11.975 and UCL(X-bar) 12.0108 < USL 12.025 — expected at PCR 1.90 because the natural spread (6σ = 0.02635 mm) is only 53% of the tolerance. Control limits are the VOICE OF THE PROCESS; moving them to the specs would guarantee both missed signals and false alarms.

## Part 2 — Control plan, worked example row (OP30 finish bore)

| field | entry |
|---|---|
| process step | OP30 — finish bore, 3-axis mill |
| characteristic | bore diameter, CTQ-1 |
| specification | 12.000 ± 0.025 mm (LSL 11.975 / USL 12.025) |
| DFMEA ref | DFMEA row "bore oversize — progressive tool wear" (detection 5 → 8 with this control); links to the lane-11 DFMEA register |
| evaluation | air gauge, Module 11 MSA-accepted: %GRR ≤ 10% of tolerance (0.050 mm), bias/negative acceptance per the module 11 court |
| sample / freq | n = 5 consecutive housings every 2 h, two shifts (8 subgroups/day) |
| control method | X-bar/R, rule 1 mandatory (rules 2–5 advisory), limits above |
| reaction plan | OCAP-BORE-01 |
| owner | shift leader (react within the hour), quality engineer (investigate) |

Ra row: I-MR daily individuals, rule 1, owner process engineer, OCAP-BORE-02 (same format).
Scrap row: p-chart n = 150/day, rule 1, owner shift leader, OCAP-SCRAP-01.

## Part 3 — p-chart for scrap

p-bar = 5/4500 = 0.001111. Limits (n = 150): sigma_p = sqrt(0.001111 × 0.998889/150) = 0.002722.
UCL = 0.001111 + 3(0.002722) = 0.00927; LCL = max(0, 0.001111 − 0.008166) = 0.

Day 1 check: 3/150 = 0.0200 > UCL 0.00927 → **rule-1 signal on day 1**. This is the teaching point: the Module 42 scrap exit (aggregate binomial, 5 ≤ 14) PASSED, and the p-chart still flags day 1 for an OCAP investigation (champion circle pattern — early-run scrap while the line warm-stabilized). An aggregate exit and a per-day chart answer different questions; a pilot can exit while its first day still owes an OCAP record.

Variable n: if daily production varied 80–120, the limits are recomputed per day (or use a standardized-z chart); constant-width limits are valid only at constant n.

## Part 4 — OCAP-BORE-01 (reference format)

| field | entry |
|---|---|
| SIGNAL | rule 1 on X-bar or R chart for OP30 bore |
| CONTAIN | shift leader quarantines ALL parts since the last in-control subgroup, tags HOLD, re-measures 10 pieces on the CMM |
| DIAGNOSE | quality engineer, in order: gauge fault (re-check master ring), tool wear (compare to life log), thermal drift (warm-up state), setup/offset |
| DISPOSITION | contained parts: accept/rework/scrap per CMM results, MRB sign-off if any scrap |
| VERIFY | process returned to control: 3 consecutive in-control subgroups, R chart first |
| RECORD | SPC log entry same shift; scrap logged to pilot-scrap ledger; MRB record if applicable |

Ordering law: CONTAIN precedes DIAGNOSE — quarantine the output before touching the process; "adjust and keep running" is the banned anti-pattern (treats signal as noise).

## Vacuity test (week-26 auditor)

Pick any control-plan row, simulate one rule-1 violation, and confirm the named OCAP exists with named owners and a containment boundary. A row that cannot fail is decoration.

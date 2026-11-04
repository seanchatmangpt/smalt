# Module 43 Lab — Build the CPPC Control Plan

**Data**: reuse the Module 42 pilot dataset `modules/42-prototype-pilot/data/pilot-bore-30day.csv` (seed 42016, 240 subgroups × n=5) and `pilot-scrap-daily.csv`.

## Part 1 — Control-limit arithmetic for the bore operation
Compute from the 240 subgroups (n=5): X-double-bar, R-bar, UCL/LCL(X-bar) with A2=0.577, UCL(R) with D4=2.114, D3=0. Then sigma-hat = R-bar/d2 (d2 = 2.326 for n=5), PCR = tolerance/(6·sigma-hat). Verify the control limits lie inside the spec limits 11.975–12.025 and explain why that is expected at PCR 1.9.

## Part 2 — Fill the control plan
One row per measurement, using the Slide-2 template: OP30 finish bore (X-bar/R, n=5 every 2 h, air gauge per Module 11 MSA, DFMEA ref, OCAP ref, owners), daily Ra (I-MR), daily scrap (p-chart, n=150).

## Part 3 — p-chart for scrap
From `pilot-scrap-daily.csv`: p-bar = total scrap / total produced; limits 3·sqrt(p(1-p)/150). Confirm LCL floors at 0. Then check the real data: day 1 had 3 scrapped pieces in 150 — is day 1 a rule-1 signal against these limits? Show the arithmetic.

## Part 4 — Write OCAP-BORE-01
Use the six-field format (SIGNAL → CONTAIN → DIAGNOSE → DISPOSITION → VERIFY → RECORD) with named owners and a containment boundary ("since the last in-control subgroup").

## Part 5 — Court your plan
Run `python3 modules/43-process-control/court.py` from the curriculum root after your lab; it re-derives every limit you computed and exits 1 on any mismatch. Compare against `keys/solution-key.md`.

## Timing (per activity)

| Part | Activity | Time |
|---|---|---|
| 1 | Control-limit arithmetic for the bore operation | (15 min) |
| 2 | Fill the control plan | (15 min) |
| 3 | p-chart for scrap | (15 min) |
| 4 | Write OCAP-BORE-01 | (10 min) |
| 5 | Court your plan | (5 min) |

Total 60 min — consistent with the slides-outline estimate (lab 1.0 h).

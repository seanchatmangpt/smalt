# CTQ -> Y -> x Hierarchy — All Three Spine CTQs

Each spine CTQ decomposes into a measurable Y (the lagging outcome on the
scorecard) and the process x's that drive it (the leading indicators). The x's
are what the teams control daily; the Y's are what the gates judge.

## CTQ-1 (product): bore diameter 12.000 +/- 0.025 mm

| Level | Element | Measure | Target |
|---|---|---|---|
| CTQ | bore diameter | 12.000 mm +/- 0.025 mm | Cpk >= 1.33 sustained 30 days |
| Y1 | bore process capability | Cpk on bore diameter (30-day rolling) | >= 1.33 |
| x1.1 | spindle speed | 11,500 RPM (DOE optimum) | +/- 2% of setpoint |
| x1.2 | feed rate | 630 mm/min (DOE optimum) | +/- 2% of setpoint |
| x1.3 | coolant concentration | 9.0% | 8.5-9.5% |
| x1.4 | tool coating | coated (TiAlN) | coated only, per tool crib log |
| x1.5 | tool wear state | inserts in-cut minutes vs 52-min edge life | replace at 48 min (92%) |

## CTQ-2 (transactional): order-to-ship lead time

Baseline 18.4 days, target <= 7 days. Baseline decomposition (Measure):

11.2 queue + 3.1 machining + 2.6 QC hold + 1.5 ship docs = 18.4 days.

| Level | Element | Measure | Target |
|---|---|---|---|
| CTQ | lead time | order-to-ship calendar days | <= 7 days |
| Y2 | order-to-ship lead time | median calendar days, weekly cohort | <= 7 |
| x2.1 | queue time before op10 | WIP queue depth, days | <= 2.5 days (from 11.2) |
| x2.2 | machining flow time | op10+op20 calendar days | <= 2.4 days (from 3.1) |
| x2.3 | QC hold time | days in inspection queue | <= 0.6 day (from 2.6, in-cycle probing) |
| x2.4 | ship docs cycle | packing/paperwork hours | <= 0.5 day (from 1.5) |

Future-state sum: 2.5 + 2.4 + 0.6 + 0.5 = 6.0 days <= 7 (0.9 day margin).

## CTQ-3 (cost): unit cost

Baseline $41.80, ceiling $28.50. Module 06 owns the teardown; the scorecard
tracks the cost lines as x's.

| Level | Element | Measure | Target |
|---|---|---|---|
| CTQ | unit cost | should-cost per finished unit | <= $28.50 |
| Y3 | unit cost | monthly should-cost rollup (module 06 model) | <= $28.50 |
| x3.1 | cycle time | min/unit (op10+op20) | 13.08 min (from 22.40) |
| x3.2 | first-pass yield (bore) | 2*Phi(-3*Cpk) defect rate | <= 0.007% (from 3.077%) |
| x3.3 | setup hours per changeover | clocked changeover | <= 1.05 h (from 3.2) |
| x3.4 | insert consumption | $/unit tooling line | <= $3.46 (from $6.05) |
| x3.5 | billet price | $/kg mill quote | <= $4.65/kg held |

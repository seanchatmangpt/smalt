# Cost-Driver Table — CTQ-3, Ranked

Ranked by baseline $/unit exposure (line totals from `01-should-cost-teardown.md`),
highest first. Improvement levers are the DMEDI Develop-phase changes; each lever
is quantified in `03-gap-worksheet.md` and re-derived by the court.

| Rank | Driver | Baseline $/unit | Mechanism | Lever (Develop) | Future $/unit | Savings $/unit |
|---|---|---|---|---|---|---|
| 1 | Machine time (22.40 min cycle) | 19.41 | cycle time x $52/h loaded rate | DOE-optimized feed 360 -> 630 mm/min + spindle 8,200 -> 11,500 RPM shrinks in-cut 17.47 -> 9.98 min; optimized tool paths cut air time 4.93 -> 3.10 min; cycle 22.40 -> 13.08 min | 11.34 | 8.07 |
| 2 | Tooling consumables | 6.05 | in-cut minutes x $0.40/min wear rate | shorter in-cut time (same lever as rank 1) at unchanged wear rate | 3.46 | 2.59 |
| 3 | Overhead absorption | 3.07 | 11% of conversion cost | conversion falls with ranks 1-2, 5 | 1.75 | 1.32 |
| 4 | Net material | 10.21 | billet mass x price - chip credit | near-net billet 90x90x115 -> 88x88x110 mm (2.6175 -> 2.3937 kg); same chip credit basis | 9.43 | 0.78 |
| 5 | Inspection (QC) | 1.75 | 1.8 min/unit manual CMM sampling + gauge amortization | in-cycle probing (gauge R&R passed) 1.8 -> 0.9 min/unit | 0.97 | 0.78 |
| 6 | Scrap allowance | 0.64 | bore defect rate 3.0773% at Cpk 0.72 x $20.88 scrapped-unit content | Cpk 0.72 -> 1.33 -> defect rate 0.006607%; content falls with machine time too | 0.00 | 0.64 |
| 7 | Setup amortization | 0.67 | $166.40/changeover / 250-unit lots | SMED: 3.2 -> 1.05 h/changeover; lot 250 -> 400 | 0.14 | 0.53 |

Notes:

- Rank 1 and 2 share one mechanism (in-cut time) — the table shows the exposure
  ranking; the gap worksheet decomposes savings per cost line so the decomposition
  is additive by construction.
- Scrap allowance rounds to $0.00 in the future state (raw $0.001); the court
  checks the raw value, not the rounded display.

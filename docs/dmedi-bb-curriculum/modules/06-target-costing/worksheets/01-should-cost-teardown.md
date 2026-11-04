# Should-Cost Teardown — CPPC SR-71 Gimbal Housing (CTQ-3)

Case spine: `RUNNING-CASE.md`. Re-derivation court: `courts/court.py`.

## Method

Should-cost is built bottom-up from physical parameters (billet mass, cycle time,
edge life, rates), not from vendor quotes. Every line is derived; the court
re-computes all seven lines and the rollup.

## Baseline parameters (Measure phase)

| Parameter | Value | Source / derivation |
|---|---|---|
| Material | 7075-T6, density 2.81 g/cm^3 | alloy spec |
| Billet | 90 x 90 x 115 mm | current stock cut list |
| Billet mass | 2.6175 kg | 90*90*115 mm^3 = 931.5 cm^3 * 2.81 g/cm^3 |
| Part weight (finished) | 0.98 kg | weighed finished housing |
| Billet price | $4.65/kg | mill quote, 7075-T6 plate |
| Scrap (chip) credit | $1.20/kg | reclaimer contract |
| Machine + operator rate | $52.00/h | shop loaded rate |
| Baseline cycle time | 22.40 min | shop floor study, op10 + op20 |
| In-cut share of cycle | 78% (17.47 min) | cycle study; 22% air/rapid |
| Cutter | 4 inserts, 52 min edge life, $4.50/insert | tooling log |
| Setup per changeover | 3.2 h @ $52/h = $166.40 | current (pre-SMED) |
| Lot size | 250 units | current production plan |
| Inspection | 1.8 min/unit + $0.19 gauge/calibration amortization | QC ledger |
| Bore Cpk (baseline) | 0.72 | pinned in RUNNING-CASE.md |
| Overhead absorption | 11% of conversion cost | FY absorption schedule |

## Baseline should-cost lines

| # | Line | Derivation | $/unit |
|---|---|---|---|
| 1 | Net material | gross 2.6175 kg * $4.65 = $12.17; chip credit (2.6175 - 0.98) kg * $1.20 = $1.96; net | 10.21 |
| 2 | Machine time | 22.40 min / 60 * $52/h | 19.41 |
| 3 | Setup amortization | $166.40 / 250 units | 0.67 |
| 4 | Tooling consumables | in-cut 17.47 min * (4 inserts / 52 min * $4.50) = $0.40/in-cut-min | 6.05 |
| 5 | Inspection (QC) | 1.8 min * $52/60 + $0.19 | 1.75 |
| 6 | Scrap allowance | bore defect rate at Cpk 0.72 (see yield math) * cost content of a scrapped unit | 0.64 |
| 7 | Overhead absorption | 11% * conversion cost 27.88 (19.41 + 0.67 + 6.05 + 1.75) | 3.07 |
| — | **Total should-cost** | sum of lines 1-7, each rounded to cents | **41.80** |

Each line is rounded to cents at the line level; the rollup is the sum of rounded
lines. The court asserts the rounded rollup equals the pinned $41.80 exactly.

## Yield math (line 6)

Bore is the final operation; a bore escape scraps the finished housing
(constrained press fit, no rework). Bore defect rate from the pinned Cpk via the
centered-normal relationship defects = 2 * Phi(-3 * Cpk):

- Baseline Cpk 0.72 -> 2 * Phi(-2.16) = 3.0773% of units
- Cost content of a scrapped unit = net material + 55% of machine time
  (scrap is detected at final bore op, after roughing on both ops):
  10.21 + 0.55 * 19.41 = $20.88
- Scrap allowance = 0.030773 * 20.88 = $0.64/unit

Target Cpk 1.33 -> 2 * Phi(-3.99) = 0.006607% -> see the gap worksheet for the
future-state line.

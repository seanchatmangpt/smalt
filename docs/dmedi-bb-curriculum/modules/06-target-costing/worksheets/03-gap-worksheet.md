# Allowable-vs-Driven Cost Gap Worksheet — CTQ-3

The gap between what the part currently costs to make (driven cost = $41.80
should-cost teardown) and what the market permits it to cost (allowable cost =
$28.50 target-costing ceiling) is $13.30. This worksheet decomposes the gap to
driver targets and shows the ceiling is met with design margin.

## Allowable cost derivation (link to 04-price-point.md)

- Allowable cost = target price - required profit = $30.00 - $1.50 = **$28.50**
  (5% return-on-sales requirement, pinned as the CTQ-3 ceiling in RUNNING-CASE.md)

## Driver-target decomposition

Each driver target is worked bottom-up; savings are line-level differences of the
teardown (additive by construction), future state at full driver deployment:

| Cost line | Baseline | Driver target (mechanism) | Future | Savings |
|---|---|---|---|---|
| Net material | $10.21 | near-net billet 88x88x110 mm (2.3937 kg), nesting study | $9.43 | $0.78 |
| Machine time | $19.41 | DOE optimum feed 630 mm/min + 11,500 RPM -> in-cut 9.98 min, air 3.10 min, cycle 13.08 min | $11.34 | $8.07 |
| Setup amortization | $0.67 | SMED 1.05 h changeover, 400-unit lots ($54.60/lot) | $0.14 | $0.53 |
| Tooling | $6.05 | in-cut 9.98 min x $0.40/min | $3.46 | $2.59 |
| Inspection | $1.75 | in-cycle probing 0.9 min + $0.19 gauge amortization | $0.97 | $0.78 |
| Scrap allowance | $0.64 | Cpk 1.33: 0.006607% defect rate x $15.67 scrapped-unit content | $0.00 | $0.64 |
| Overhead | $3.07 | 11% x conversion $15.90 | $1.75 | $1.32 |
| **Total** | **$41.80** | — | **$27.09** | **$14.71** |

Future-state scrap content of a scrapped unit: 9.43 + 0.55 x 11.34 = $15.67.

## Gap closure

| Quantity | Value |
|---|---|
| Driven cost (baseline should-cost) | $41.80 |
| Allowable cost (target-costing ceiling) | $28.50 |
| **Cost gap** | **$13.30** |
| Sum of driver-target savings | $14.71 |
| **Design margin below ceiling** | **$1.41** |
| Projected unit cost at full deployment | $27.09 |
| Status | Gap closed, $27.09 <= $28.50 — ceiling met with $1.41 (5.2%) margin |

## Cross-lane coupling (resolution notes)

- Feed 630 mm/min and spindle 11,500 RPM are the assumed DOE optimum; Lane 11
  (DOE) must confirm or supersede these settings and the resulting cycle time —
  if Lane 11's optimum differs, the machine/tooling/overhead lines re-derive from
  its cycle time and this worksheet updates.
- Cpk 1.33 is the pinned Define-gate target; the yield math uses only the pinned
  constant (2 * Phi(-3 * Cpk)), so it is stable across lanes.
- Cpk 0.72 baseline sigma is a bore-diameter statistic; the scrap allowance uses
  it as the unit-level scrap driver because the bore is the final, scrap-forcing
  operation.

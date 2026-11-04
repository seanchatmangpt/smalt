# Scorecard-to-MGPP Traceability Matrix

MGPP = Master Gate/Phase Plan — the 26-week DMEDI program plan with gate reviews
at weeks 5 (Define), 9 (Measure), 15 (Explore), 21 (Develop), 26 (Implement),
pinned in RUNNING-CASE.md. Every scorecard metric must trace to at least one
gate checkpoint; the court checks completeness (no empty cells, every metric ID
present).

| Scorecard metric (OD) | CTQ | Type | Gate (week) | Phase-exit criterion at that gate | Owner |
|---|---|---|---|---|---|
| OD-1 bore diameter | CTQ-1 | lagging | W9, W21 | Measure: baseline Cpk 0.72 reproduced from raw data; Develop: pilot line Cpk >= 1.33 on pilot lot | Quality eng |
| OD-2 Cpk 30-day | CTQ-1 | lagging | W21, W26 | Develop exit: Cpk >= 1.33 on 30-day pilot window; Implement exit: sustained 30 days in production | Quality eng |
| OD-3 RPM adherence | CTQ-1 | leading | W21 | process control plan live, >= 98% in-band on pilot | Mfg eng |
| OD-4 feed adherence | CTQ-1 | leading | W21 | same as OD-3 | Mfg eng |
| OD-5 coolant % | CTQ-1 | leading | W21 | control plan live; refractometer log per shift | Shift lead |
| OD-6 tool wear | CTQ-1 | leading | W21 | 48-min swap rule enforced in crib audit | Tool crib |
| OD-7 lead time | CTQ-2 | lagging | W9, W26 | Measure: 18.4-day baseline reproduced; Implement: median <= 7 days for 4 consecutive weekly cohorts | Planner |
| OD-8 queue depth | CTQ-2 | leading | W15, W26 | Explore: WIP cap design approved; Implement: <= 2.5-day median sustained | Planner |
| OD-9 QC hold | CTQ-2 | leading | W15, W26 | Explore: in-cycle probing gauge R&R passed; Implement: <= 0.6-day median | Quality eng |
| OD-10 ship docs | CTQ-2 | leading | W15 | Explore: docs process map + target hours approved | Shipping |
| OD-11 cycle time | CTQ-2/3 | leading | W15, W21 | Explore: DOE optimum confirmed (feed 630, 11,500 RPM); Develop: 13.08-min cycle on pilot | Mfg eng |
| OD-12 bore FPY | CTQ-3 | leading | W21, W26 | Develop: <= 0.007% on pilot; Implement: sustained | Quality eng |
| OD-13 changeover | CTQ-3 | leading | W15, W21 | Explore: SMED plan (internal/external split); Develop: 1.05 h clocked on 3 consecutive changeovers | Mfg eng |
| OD-14 tooling $/unit | CTQ-3 | leading | W21, W26 | Develop: <= $3.46/unit on pilot; Implement: monthly | Finance |
| OD-15 billet price | CTQ-3 | leading | W9, W26 | Measure: $4.65/kg baseline pinned; Implement: near-net billet (88x88x110) qualified, price held | Purchasing |
| Y3 unit cost | CTQ-3 | lagging | W21, W26 | Develop: pilot should-cost <= $28.50; Implement: monthly rollup <= $28.50 sustained | BB lead |

## Completeness rules (court-enforced)

1. Every OD-1..OD-15 and Y3 appears exactly once, with CTQ, type, gate, owner.
2. Each spine CTQ has >= 2 lagging-paired leading metrics (see
   `04-leading-lagging.md`).
3. Gate weeks drawn only from {5, 9, 15, 21, 26}.
4. No empty cells; every owner is a role, never a name.

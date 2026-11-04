# Leading / Lagging Split

Law: every lagging Y on a scorecard must be paired with at least two leading x's
that move earlier in time; a scorecard of only lagging measures reports losses
after they are sunk. Split below for all three spine CTQs.

| CTQ | Lagging (Y — gate-judged) | Leading (x — daily-controlled) |
|---|---|---|
| CTQ-1 bore | Cpk 30-day rolling (OD-2) | RPM adherence (OD-3), feed adherence (OD-4), coolant % (OD-5), tool wear state (OD-6) |
| CTQ-2 lead time | order-to-ship median (OD-7) | queue depth (OD-8), QC hold (OD-9), ship-docs hours (OD-10), cycle time (OD-11) |
| CTQ-3 cost | unit-cost monthly rollup (Y3) | changeover hours (OD-13), tooling $/unit (OD-14), billet price (OD-15), bore FPY (OD-12), cycle time (OD-11) |

## Reaction rules (what a leading miss triggers)

| Leading signal | Threshold | Reaction | Lagging risk averted |
|---|---|---|---|
| RPM/feed adherence (OD-3/4) | < 98% of parts in-band, one day | same-day andon; quarantine parts made off-band for OD-1 check | Cpk erosion (CTQ-1) |
| Tool wear (OD-6) | 48 min accumulated | forced insert swap at crib audit | bore drift near edge life (CTQ-1), scrap line (CTQ-3) |
| Queue depth (OD-8) | median > 2.5 days for 3 days | WIP cap review, expediting policy | lead-time miss (CTQ-2) |
| Changeover (OD-13) | > 1.05 h clocked | SMED re-audit of that changeover | setup amortization (CTQ-3) |
| Bore FPY (OD-12) | > 0.007% for a week | containment: 100% bore check + Cpk refresh | scrap allowance (CTQ-3), Cpk gate (CTQ-1) |
| Billet price (OD-15) | > $4.65/kg on a PO | purchasing variance review before lot release | material line (CTQ-3) |

Review cadence: leading metrics daily/weekly at the line level; lagging Y's
weekly workbook + gate reviews (weeks 5/9/15/21/26). A lagging Y failing its
target at a gate is a phase-exit block even if all leading x's are green — the
hierarchy direction is x -> Y, never Y inferred from x.

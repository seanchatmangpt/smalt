# Operational Definitions — Every Scorecard Metric

An operational definition pins gauge, sample, frequency, and calculation so two
people taking the same measurement get the same number. A metric without all
four fields is not scorecard-eligible.

| ID | Metric | Gauge / instrument | Sample | Frequency | Calculation |
|---|---|---|---|---|---|
| OD-1 | Bore diameter | CMM, 0.001 mm resolution; gauge R&R passed (<10% study variation) | 5 parts/shift, positions 3-depth x 2-angle per bore | every shift | mean of 6 probe results per part; spec 12.000 +/- 0.025 mm |
| OD-2 | Cpk (30-day) | derived from OD-1 data | all OD-1 points in trailing 30 days (n >= 250) | weekly at gate reviews | min(USL-mu, mu-LSL) / (3*sigma), sigma = overall std dev |
| OD-3 | Spindle speed setpoint adherence | machine CNC log | every part, automatic | continuous (daily rollup) | % parts with RPM within +/- 2% of 11,500 |
| OD-4 | Feed rate adherence | machine CNC log | every part, automatic | continuous (daily rollup) | % parts with feed within +/- 2% of 630 mm/min |
| OD-5 | Coolant concentration | refractometer, 0.5% resolution | 1 sample/machine/shift | every shift | refractometer reading x 1.0, % v/v |
| OD-6 | Tool wear state | insert changeover log + CNC in-cut timer | every insert | at each change | in-cut minutes accumulated; replace at 48 min |
| OD-7 | Order-to-ship lead time | ERP timestamps (order-entered, ship-confirm) | all shipped orders in the week | weekly cohort | median(ship_date - order_date) in calendar days |
| OD-8 | Queue depth before op10 | ERP: release-to-first-cut interval | all released jobs | daily | median calendar days from release to op10 start |
| OD-9 | QC hold time | ERP: first-article-submit to disposition | sampled lots (all lots until OD-11 proves in-cycle) | daily | median calendar days in inspection hold |
| OD-10 | Ship docs cycle | ERP: final-inspect to ship-confirm | all shipped orders | weekly | median hours, final-inspect to ship-confirm |
| OD-11 | Cycle time | CNC controller cycle timer | every completed part | daily | mean min/unit, op10+op20, excluding machine-down |
| OD-12 | Bore first-pass defect rate | OD-1 data + scrap ledger | all parts started | weekly | defects / units started (bore escapes scrapping the housing) |
| OD-13 | Changeover hours | clocked SMED sheet, op10 last-good to op10 first-good | every changeover | every change | elapsed clock hours; internal vs external steps split |
| OD-14 | Tooling $/unit | tool crib issue log vs completions | monthly | monthly | insert spend / good units completed |
| OD-15 | Billet price | mill quote register | per PO | monthly | latest PO $/kg for 7075-T6 plate |

Consistency law: OD-2 must reproduce the pinned Measure baseline (Cpk 0.72 from
mu = 12.009 mm, sigma = 7.407 um, adjudicated 2026-11-04) when run on the archived Measure-phase dataset —
re-derived from raw data, never from a remembered answer (RUNNING-CASE provenance
law).

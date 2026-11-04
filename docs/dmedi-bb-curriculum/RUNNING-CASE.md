# RUNNING CASE — CascadeProjects Precision Components (course-wide spine)

Every worked example, dataset, capability study, DOE response, and control chart in
this curriculum references THIS case unless a module explicitly labels a
secondary/standalone example. Coherence court (Lane 19) pins cross-module numbers
to these constants.

## Business
CascadeProjects Precision Components (CPPC) — a 140-person machining shop launching
a CNC production line for the SR-71 drone-gimbal housing (aluminum 7075, 3-axis mill).

## Pinned constants (do not vary between modules)
- CTQ-1 (product): bore diameter, spec 12.000 mm ± 0.025 mm (LSL 11.975 / USL 12.025)
- Baseline (Measure): Cpk = 0.72 on bore diameter, mu = 12.009 mm, sigma = 7.407 um
  (ADJUDICATED 2026-11-04: the original sigma=4.17um pair computed Cpk~1.28, inconsistent
  with 0.72; formula-consistent pair is sigma=7.407um — (12.025-12.009)/(3*0.007407)=0.72.
  Re-derive in Lane 05, must match. Any artifact carrying sigma=4.17um is STALE and must
  be corrected to 7.407um.)
- Target (Define gate): Cpk >= 1.33 sustained 30 days
- CTQ-2 (transactional): order-to-ship lead time, baseline 18.4 days, target <= 7 days
- CTQ-3 (cost): unit cost baseline $41.80, target costing ceiling $28.50 (Lane 03)
- Primary DOE factors (Develop): spindle speed (RPM), feed rate (mm/min), coolant
  concentration (%), tool coating (coated/uncoated); response: bore diameter deviation
  from 12.000 mm (um) + surface finish Ra (um)
- Reliability case: spindle assembly MTBF target 1,200 h; B10 = 900 h (Lane 14)
- Program: 26-week DMEDI program, gate reviews at weeks 5/9/15/21/26

## Data provenance law
Every dataset is synthetic, generated with a STATED seed (python3 random/np-style),
registered in datasets/MANIFEST.md by its owning lane, and internally consistent:
any solution key must re-derive from the raw CSV, never from a remembered answer.

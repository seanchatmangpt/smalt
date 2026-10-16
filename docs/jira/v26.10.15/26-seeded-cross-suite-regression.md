# WO v26.10.15 / 26 — Seeded Cross-Suite Regression (the gate's own mutation court)

**Status:** STUB — full authoring is lane 26's job before any code lands.
**Seeds:** WO 04 §4 falsifier, dod-07-court-x2, 18-mutation-courts.

## Problem

WO 04's falsifier seeds a cross-suite regression once, as a falsifier run. If the gate is
never re-proven, the proof decays: slice contracts tighten, seams move, and the court-x2
gate's ability to catch cross-suite regressions becomes an unverified standing claim —
exactly the vacuity class 18-mutation-courts was built to kill.

## Move

Make the seeding permanent: a maintained, seeded broken cross-suite dependency (a shared
helper's return shape consumed across two independent slices) checked in behind a flag,
run at integration as the gate's own mutation court. The gate is healthy iff court-x2 goes
red on the seeded subject and green on revert — recorded as a receipt each window.

## Falsifier

Run the seeded subject through integration: both slices stay green (isolation proof),
court-x2 goes red with a signature naming the seam. If the slices catch it, the slices
are not isolated (tighten ownership); if court-x2 passes the seeded subject, the gate is
weaker than a full suite and WO 04's premise is refuted. Either outcome kills the window's
gate claim — a silent green is the one forbidden result.

# Module 01 Exercises

Answers with shown derivations live in `solution-key.md`. Constants: RUNNING-CASE.md
pinned pair (Cpk 0.72, mu 12.009 mm, sigma 7.407 um, adjudicated 2026-11-04) and
spec 11.975/12.025 mm.

1. From `data/baseline-bore-diameter.csv` (50 runs): compute n, mean, sample sd,
   and Cpk against the spine spec. Which spec side governs? (10 min)
2. Show the distance from the pinned mu (12.009 mm) to USL and to LSL in sigma
   units using the adjudicated sigma (7.407 um). Confirm these give Cpk 0.72.
   (5 min)
3. A teammate claims the baseline sigma is 4.17 um "because that's what the
   registry says." That value was adjudicated STALE on 2026-11-04. Compute the
   Cpk the stale pair implies and explain why it is inconsistent with the
   pinned Cpk 0.72. Which number wins and why? (10 min)
4. Reconciliation: your sample Cpk from exercise 1 (0.94) differs from the pinned
   baseline 0.72. Give the two lawful explanations and state which applies here.
   (5 min)
5. DMEDI vs DMAIC: for each brief, name the method and the one-sentence reason —
   (a) a NEW CNC line for a drone-gimbal housing; (b) reducing order-to-ship
   lead time on an existing fulfillment flow; (c) re-cutting the fixture of an
   EXISTING mill cell whose bore capability regressed. (5 min)
6. Evidence-based tollgates: a gate reviewer is handed "Measure phase complete"
   as a status report. List the four receipt fields that must accompany the
   claim, and state what a court must do when any one is missing. (10 min)
7. The zero-artifacts case: a program receipted SUCCESS with zero build
   artifacts on disk at receipt time. Identify the two structural defects that
   let this happen (one per intermediate gate, one at the final gate), and the
   one property every gate check needs to prevent it. (10 min)
8. Compute the sigma level (1.5-shift convention) of the pinned baseline using
   the USL-side z. Compare it with the sample's sigma level and state which one
   is the course constant. (5 min)

Total: 60 min. Gate: 6 of 8 correct, with derivations shown on 1-4.

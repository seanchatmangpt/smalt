# Module 33 — Key Lean Concepts (Slides Outline)

**Module**: 33-key-lean-concepts
## Learning objectives

After this module the Black Belt candidate can:
1. Construct a text-form value-stream map of the CPPC order-to-ship stream and classify every
   elapsed day as queue/wait, processing, or inspection.
2. Compute process-cycle efficiency (PCE) and explain why a 4% PCE is typical for job-shop
   machining streams.
3. Derive takt time from demand and net available time, and use it to size resources (bottleneck
   detection on Op20-mill).
4. Locate all 7 wastes on the CPPC value stream with the stream step each waste lives in.
5. Decompose the pinned 18.4-day lead-time baseline into wait vs processing and identify the
   three largest wait pools (order entry, vendor anodize, pack/transit).

**Timing estimate**: 4.0 h (slides 1.5 h, lab 1.0 h, exercises 1.0 h, court 0.5 h).
**Required tools**: python3 (stdlib only), spreadsheet or text editor.

---

## Slide 1 — Wait time is not work time (10 min)
- Lead time = wait + processing + inspection. On job shops, processing is the SMALLEST term.
- CPPC CTQ-2: order-to-ship lead time 18.4 d baseline, target ≤ 7 d. The gap is not machining
  speed; it is queue design.
- Per-slide contract: every number re-derives from `data/vsm-baseline.csv` via the module court.

## Slide 2 — The CPPC value stream, in text form (20 min)
Text VSM (baseline, from the census CSV; 1 day = 880 productive min, 2 shifts x 8 h less 80 min
planned downtime):

```
Orders --2.2d--> [Saw 4.5min] --2.1d--> [Mill 6.8min] --2.6d--> [Deburr 2.2min] --1.2d-->
   [Anodize 660min] --4.6d--> [CMM 2.5min] --1.8d--> [Pack 1.5min] --3.1d--> Ship
                       (I)                                        (I)
```
- (I) marks inspection steps: Op20 in-process bore checks and Op50 final CMM (CTQ-1).
- Elapsed decomposition (re-derived in the court): wait total 17.6 d, processing total
  677.5 min = 0.77 d, lead time 17.6 + 0.77 = 18.37 d ≈ pinned 18.4 d (CSV rounding).

## Slide 3 — Process-cycle efficiency (15 min)
- PCE = value-added time / total lead time.
- CPPC baseline: 0.77 / 18.37 = 4.2%.
- Benchmark bands: < 1% traditional job shop; 1–5% typical with vendor loops; > 10% lean
  operation; world-class discrete > 20%.
- Reading: a 61% lead-time cut (18.4 -> 7 d) does NOT require any machine to run faster.

## Slide 4 — Takt time (20 min)
- Takt = net available time / customer demand.
- CPPC: 2 shifts x 8 h = 960 min, less 80 min planned downtime = 880 min = 52,800 s/day.
  Demand = 240 housings/day. Takt = 52,800 / 240 = 220 s/housing.
- Bottleneck law: any operation with cycle time > takt caps daily output. Op20-mill = 6.8 min
  = 408 s = 1.85x takt -> the mill caps the line at 880/6.8 = 129 housings/day, not 240.
- Sizing fix: 2 mills -> 204 s effective < 220 s takt.

## Slide 5 — The 7 wastes located on the stream (20 min)
1. Waiting — all seven queue pools (17.6 d).
2. Inventory — WIP between ops, driven by 300-piece anodize batches (demand is 240/day:
   over 1 day of line output queued at one vendor step).
3. Transport — Op40-anodize is off-site vendor transport (only step with shifts_covered = 0).
4. Overprocessing — duplicate bore checks (Op20 in-process + Op50 CMM both verify CTQ-1).
5. Overproduction — machining to lot size, not takt (300-piece batches vs 240/day demand).
6. Motion — Op50 CMM is off-line; inspectors walk parts to a remote lab.
7. Defects — mill rework loop feeds back from Op50 CMM to Op20 (8% of lots re-milled).

## Slide 6 — From map to improvement backlog (15 min)
- Rank the wait pools: anodize queue 4.6 d, pack/transit 3.1 d, mill queue 2.6 d, order entry
  2.2 d. These four carry 12.5 of 17.6 wait days (71%).
- Every backlog item must name its stream step and its falsifiable wait reduction.
- Lab: recompute lead time under three candidate improvements; exercises: derive takt for a
  demand change and locate a new waste.

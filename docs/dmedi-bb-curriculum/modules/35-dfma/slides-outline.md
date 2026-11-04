# Module 35 — Design for Manufacture and Assembly (Slides Outline)

**Module**: 35-dfma
## Learning objectives

After this module the candidate can:
1. Run a DFA teardown of the SR-71 gimbal assembly: part count, handling/insertion times per
   part, before vs after.
2. Apply the three taught consolidation moves — fastener elimination, bracket merge,
   self-locating feature — and quantify each in parts and seconds.
3. Compute the part-count reduction % and DFA assembly-time reduction %.
4. Price the DFMA saving and place it against Lane 03's unit-cost gap ($41.80 -> $28.50,
   gap $13.30).
5. Apply the DFA theoretical-minimum-part-count criteria and expose the residual opportunity.

**Timing estimate**: 4.0 h (slides 1.5 h, lab 1.0 h, exercises 1.0 h, court 0.5 h).

---

## Slide 1 — Part count is cost (10 min)
- Every part costs three times: material, assembly time, and a defect/inventory tail.
- DFA heuristic: no assembly should exist that a customer would not pay for.
- Subject: the gimbal assembly that carries the CTQ-1 bore housing.

## Slide 2 — Teardown before (20 min)
From `data/gimbal-teardown.csv`: **37 parts**, **228.5 s** total assembly time
(handling + insertion, Boothroyd-Dewhurst-style 3-second-scale scoring).
Dominant rows: 12 M3 screws = 84 s (37% of assembly time for 32% of the parts).

## Slide 3 — The three consolidation moves (30 min)
1. **Fastener elimination**: 12 M3 screws -> 4 (cover quarter retained). Saves 8 parts,
   56 s.
2. **Bracket merge**: bracket-L + bracket-R + sensor-bracket + cover-plate + gasket ->
   one machined bracket-cover-merged (gasket eliminated by a machined face seal). Saves
   4 parts, 35.5 s gross; the merged part adds back 8 s + $4.60 material (net 27.5 s).
3. **Self-locating feature**: press-fit bushings with locate lugs replace 4 m4-washers
   (alignment shimming) and 4 set screws (axial retention). Saves 8 parts, 36 s.

## Slide 4 — After-design totals (15 min)
- **17 parts** (from 37): reduction **20 parts = 54.1%**.
- Assembly time **109.0 s** (from 228.5 s): net reduction **119.5 s = 52.3%**
  (gross removed 127.5 s less the merged part's 8 s).
- Theoretical minimum per DFA criteria (relative motion / different material / must-be-separate
  for service): **6 parts** — outer ring, inner ring, 2 shafts + 2 bushings (relative motion
  family) + merged bracket-cover. Actual-after 17 vs minimum 6 -> residual DFMA opportunity
  remains (retaining rings, remaining fasteners).

## Slide 5 — Cost impact vs the Lane 03 gap (20 min)
- Loaded assembly labor $84/h: 228.5 s = $5.33 -> 109.0 s = $2.54; labor saving **$2.79**.
- Material saving: removed 8 screws ($0.16) + washers ($0.12) + set screws ($0.08) +
  bracket/cover/gasket net of the merged part ($12.75 - $4.60 = $8.15) = **$8.51**.
- Total DFMA saving **$11.30 per unit** = **85.0%** of the $13.30 gap; remaining **$2.00**
  must come from machining/process cost (Lanes 03/15), not from this assembly.

## Slide 6 — Courts over claims (10 min)
- Every count, second, and dollar re-derives from the teardown CSV; the court exits nonzero on
  any drift. A DFMA claim without a teardown table is a narrative, not a design.

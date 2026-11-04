# Module 35 Solution Key (all numbers python3-re-derived; see courts/court.py)

## Part 1 — Baseline
- Parts before = **37**.
- Assembly time before = **228.5 s**.
- Largest share: m3-screw = 12 x 7.0 = 84.0 s = **36.8%** of assembly time (12/37 = 32.4% of
  parts). Fasteners are the dominant assembly cost, not the dominant part cost.

## Part 2 — After-design
- Parts after = **17**; reduction **20 parts = 54.1%**.
- Assembly time after = **109.0 s**; net reduction **119.5 s = 52.3%**
  (gross removed 127.5 s, merged part adds 8 s).

## Part 3 — Move-by-move
| move | parts saved | gross s | net s |
|---|---|---|---|
| fastener elimination (M3 12->4) | 8 | 56.0 | 56.0 |
| bracket merge (3 brackets+cover+gasket -> merged part) | 4 | 35.5 | 27.5 |
| self-locating feature (4 washers + 4 set screws) | 8 | 36.0 | 36.0 |
| merged part added | -1 | -(8.0) | -(8.0) |
| **net** | **20** | **127.5** | **119.5** |
- Check: 56.0 + 27.5 + 36.0 = 119.5 = total reduction (exact).

## Part 4 — Cost roll-up ($84/h loaded)
- Labor: 228.5 s = **$5.33**; 109.0 s = **$2.54**; saving **$2.79**.
- Material: 8 screws x 0.02 = 0.16; 4 washers x 0.03 = 0.12; 4 set screws x 0.02 = 0.08;
  brackets+cover+gasket 3x3.10 + 2.60 + 0.85 = 12.75, less merged part 4.60 = 8.15.
  Material saving = **$8.51**.
- Total = **$11.30/unit** = **85.0%** of the $13.30 gap (41.80 -> 28.50). Residual **$2.00**
  must come from machining/process cost (Lanes 03/15), NOT from this assembly.

## Part 5 — Theoretical minimum
- Criteria hits: outer ring, inner ring (different function/material family), shaft + bushing
  (relative motion), merged bracket-cover (must be separate for service).
- Minimum = **6 part types** (outer ring, inner ring, shaft+bushing pair as a relative-motion
  family counted once, merged bracket-cover, retained service fastener set) — vs 17 actual.
  Actual-after 17 vs minimum 6 -> residual targets: 4 remaining M3 screws, 4 retaining rings
  (candidates: snap grooves in the merged part), 4 bushings (candidates: integral in rings).

## Exercise answers
1. $96/h: labor saving = 119.5 x 96/3600 = **$3.19**; total = 3.19 + 8.51 = **$11.70** =
   **88.0%** of gap. Ranking unchanged: material dominates (8.51 > 3.19) at both rates.
2. 7 s x rate/3600 = 10 x 0.02 = 0.20 -> rate = 0.20 x 3600/7 = **$102.86/h**. Above ~$103/h
   loaded, one screw's assembly time costs 10x its purchase price — "cheap part" reasoning
   ignores the assembly tail.
3. Rule: "If two parts have no relative motion, no material conflict, and no service
   requirement, merge them into one part and locate it by geometry, not by fasteners."
4. $2.00 at $62/h = 2.00/(62/60) = 1.935 min = **116 s** off the 408 s mill cycle = **28.4%**
   reduction. Plausible only as a DOE outcome (Module 33 takt says the mill is the bottleneck;
   a 28% cycle cut also doubles as capacity relief). Not achievable by feed tweaking alone —
   it is exactly what the Develop-phase DOE (speed/feed/coolant/coating) exists to find.
5. Receipted claim: "Gimbal-assembly DFMA removes $11.30/unit ($2.79 assembly labor at $84/h
   on 119.5 s, plus $8.51 material), which is 85.0% of the $13.30 unit-cost gap. The gap is
   NOT closed by DFMA alone; the residual $2.00 is a machining-cost obligation." Teardown:
   data/gimbal-teardown.csv; replay: python3 courts/court.py.

## Court
`python3 courts/court.py` re-derives: 37/17 counts, 228.5/109.0 s, 54.1%/52.3%, the three
move nets, labor 5.33/2.54/2.79, material 8.51, total 11.30, 85.0%, residual 2.00, screw
share 36.8%. Exit 0 = match.

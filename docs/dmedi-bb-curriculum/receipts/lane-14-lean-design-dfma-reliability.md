# Lane 14 Receipt — Modules 33–36 (Lean Concepts, Lean Design, DFMA, Reliability)

Standing: **ALIVE** — all four courts executed this session, exit 0, real output below.

## Subject

`/Users/sac/smalt/docs/dmedi-bb-curriculum/` — Lane 14 owned surfaces only:
`modules/33-key-lean-concepts/`, `modules/34-lean-design/`, `modules/35-dfma/`,
`modules/36-intro-reliability/`, MANIFEST rows (4 module rows + 4 dataset rows).

## Delivered (all files on disk, verified by find)

Per module (x4): `slides-outline.md`, `lab.md`, `exercises.md`,
`keys/solution-key.md`, `courts/court.py`, `data/*.csv`. Module 36 additionally:
`scripts/generate_dataset.py` (seeded generator, byte-identical replay is
court-checked inside `courts/court.py`).

## Pinned spine numbers used (never varied)

- CTQ-2 lead time 18.4 d -> <= 7 d (module 33 decomposes it; 33-court re-derives 18.37 d,
  within 0.05 of the pin; stated CSV-rounding reconciliation in the key).
- Spindle MTBF 1200 h / B10 900 h (module 36): proven jointly consistent ONLY under
  Weibull wear-out beta = 6.2417 (court bisection), eta = 1290.7 — under exponential the
  pair is contradictory (B10 would be 126.4 h). This is a module-teaching finding, not a
  defect: the spine pair is internally consistent, and module 36 makes its hidden shape
  parameter explicit.
- Lane 03 cost gap $13.30 (module 35): DFMA closes $11.30 = 85.0%, residual $2.00 is
  machining-cost obligation (Lanes 03/15).
- Module 34 treats the 26-week program (gates weeks 5/9/15/21/26) as the process.

## Verification ladder (actual exits)

```
python3 modules/33-key-lean-concepts/courts/court.py  -> EXIT 0
  MODULE 33 COURT: PASS (all 15 derivations match key)
python3 modules/34-lean-design/courts/court.py        -> EXIT 0
  MODULE 34 COURT: PASS (all 16 derivations match key)
python3 modules/35-dfma/courts/court.py               -> EXIT 0
  MODULE 35 COURT: PASS (all 21 derivations match key)
python3 modules/36-intro-reliability/courts/court.py  -> EXIT 0
  MODULE 36 COURT: PASS (all 22 derivations match key)
```

Module 36 court also proves dataset non-vacuity: re-runs
`scripts/generate_dataset.py` (seed 42114) and asserts the CSV regenerates
byte-identically.

## Key derived results (all re-derived by the courts, not asserted)

- M33: wait 17.6 d + processing 0.77 d = 18.37 d (pin 18.4 within rounding); PCE 4.2%;
  takt 220 s; mill bottleneck 1.85x takt (129 housings/day < 240 demand, needs 2 mills);
  no single improvement reaches <= 7 d; kanban + top-3 -> 5.27 d.
- M34: 130 d split 92/23/15 exact; FE 70.8%; scenario F = 107 d (23 d saved, FE 86.0%);
  gate-cadence-only saves 10 d; honest rework finding: a 2-day peer review at first-pass
  0.9 is flow-NEGATIVE unless it costs <= 1.86 work-days.
- M35: 37 -> 17 parts (54.1%), 228.5 -> 109.0 s (52.3%); fastener elimination 8 parts/56 s,
  bracket merge 4 parts/27.5 s net, self-locating 8 parts/36 s; nets sum to the total
  exactly; $2.79 labor + $8.51 material = $11.30 (85.0% of gap).
- M36: allocation lambdas sum to 1/1200 exactly; A_sys 0.9962 -> 33 h/year downtime;
  bearing set dominates (MTBF 1500 case: A_sys 0.9949, 44.3 h/yr); parallel redundancy
  0.9999858 -> $4,927/yr ceiling; PM interval 617.7 h at 1% risk (F(900) = 10% by
  definition — B10 is a risk statement, not a schedule).

## Court catches during authoring (caught by the courts, not by pre-reading)

1. M33: takt ratio 1.86 -> 1.85 and kanban-variant arithmetic 5.77 -> 5.27 d.
2. M34: peer-review breakeven 0.86 -> 1.86 work-days.
3. M35: after-count 16 -> 17 (merged part miscounted in the hand check), which moved
   reduction 56.8% -> 54.1% and time reduction 127.5 -> 119.5 s net.
4. M36: drawbar lambda 0.833e-4 -> 1/12000 (exact 1/1200 sum), parallel availability
   0.9999856 -> 0.9999858 and saving $4,931 -> $4,927 (full-precision A).

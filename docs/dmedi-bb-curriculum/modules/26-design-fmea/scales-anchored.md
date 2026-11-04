# Module 26 — ANCHORED Scales for the CPPC Gimbal-Boring DFMEA

This file holds the anchored-scale tables + why generic scales are rejected.
Slides: `slides-outline.md`. Worksheet: `data/dfmea-worksheet.csv`.
Court: `scripts/derive_keys.py` (re-derives every RPN, rank, AP class; exit 1 on drift).

## Why NOT generic 1-10 scales (teach this first)

A generic scale says "7 = customer dissatisfied" — words that fit any product
in any industry. Three failure channels follow:

1. **Anchor drift between raters.** Two engineers rate the same misload 6 and
   9 because "customer dissatisfaction" has no observable referent on the shop
   floor. The RPN difference (a factor of 1.5) is pure rater noise.
2. **No PPM linkage.** Generic occurrence words ("occasional", "frequent") map
   to nothing measurable, so occurrence ratings cannot be validated against
   the baseline dataset (`data/bore-baseline-100.csv`) or later process data.
3. **Detection ratings detached from real controls.** "Detection = 4" says
   nothing about WHICH gauge, at WHAT frequency, with WHAT escape probability
   — so DFMEA actions cannot be costed or verified.

The fix is **anchoring**: each scale point names a CPPC-specific observable
outcome, a PPM band, or a named detection control. Anchoring converts rating
from opinion to classification against evidence — the same discipline as the
course-wide data-provenance law.

## Severity (S) — anchored to CPPC-specific outcomes

| S | Anchor (what actually happens at CPPC) |
|---|---|
| 10 | Scrap + potential shipment escape (bore oversize reaches USL and ships; safety/functional failure undetected) |
| 9 | Scrap likely (tool breakage scores bore; misload crash) — contained internally, high cost, or degradation requiring customer notification |
| 8 | Functional failure at customer (true-position error misaligns bearing fit) |
| 7 | Major rework / off-size first pieces (thermal warmup drift; spindle-related dimensional instability) |
| 6 | Function degraded at depth (bore taper breaks fit class along bore) |
| 5 | Reworkable nonconformance (undersize recut; coolant drift compounding) |
| 4 | Visual/geometry reject (chatter marks; exit burrs) |
| 3 | Cosmetic Ra drift within functional tolerance |
| 2 | Minor cosmetic deviation, no fit or function impact |
| 1 | No discernible effect |

## Occurrence (O) — anchored to PPM bands

PPM bands tie ratings to the defective-per-million vocabulary the Measure
phase already established (DPMO in module 02). Ratings are validated against
real counts, not adjectives.

| O | PPM band (defective parts per million at this operation) | In baseline data terms |
|---|---|---|
| 10 | >= 100,000 PPM (> 1 in 10) | not observed at CPPC — would gate launch |
| 9 | ~ 50,000 PPM (1 in 20) | not observed at CPPC |
| 8 | ~ 20,000 PPM | not observed at CPPC |
| 7 | ~ 7,000 PPM (burr rate at exit edge, deburr log) | observed (FM-09) |
| 6 | ~ 3,000 PPM (tool-wear oversize trend, tool-wear.csv drift > 8 um by part 900+) | observed (FM-01, FM-08) |
| 5 | ~ 1,000 PPM (chatter/thermal events per shift, 1 in ~20 parts touches a limit) | observed (FM-02, FM-03, FM-10, FM-11) |
| 4 | ~ 300 PPM (setup-class errors, occasional recuts) | observed (FM-04, FM-06) |
| 3 | ~ 60 PPM (insert-class failures, rare) | observed (FM-05, FM-07) |
| 2 | ~ 10 PPM (program mismatch — rare but has happened once in ramp-up) | observed (FM-12) |
| 1 | < 10 PPM, eliminated by error-proofing | target state |

Every O rating in `data/dfmea-worksheet.csv` cites its band; the bands cite
CPPC evidence (tool-wear.csv drift, deburr logs, ramp-up incident log). A
rater who cannot cite the band's evidence cannot rate.

## Detection (D) — anchored to named detection controls

D rates the CONTROL, not the hope. Named controls, ordered weakest to
strongest. The scale point is a property of the control itself (where in the
flow it acts, sample size, automation), not of the operator's diligence.

| D | Detection control (named, CPPC-specific) |
|---|---|
| 10 | No control / defect found by customer (escape) |
| 9 | Downstream op discovers it (deburr station finds chatter) |
| 8 | 100% manual visual only |
| 7 | First-article/spot check, single point in time (first piece per shift; single-depth gauge) |
| 6 | Periodic sample at end of line (EOL CMM n=3/shift) |
| 5 | Periodic in-process gauge, partial coverage (weekly fixture PM; weekly refractometer) |
| 4 | 100% automated gauge with manual reaction (Ra spot check on production gauge) |
| 3 | 100% automated measurement with automated reaction (in-process gauge traverse w/ offset; daily inline refractometer) |
| 2 | Error-proofing / poka-yoke (seating sensor, program-match interlock, offset-verify) |
| 1 | Prevented by design — defect cannot be produced (error-proofed fixture + interlock) |

## Rating discipline (the law)

1. Rate S from the EFFECT row (worst credible effect), O from the PPM band,
   D from the named control. If you cannot name the control, D is 7 or worse.
2. Post-action ratings re-rate the SAME three anchors after the recommended
   action is in place — never "we'll be more careful".
3. The severity of an effect never improves unless the DESIGN changes
   (FM-01's S stays 10; the action moves O and D only).

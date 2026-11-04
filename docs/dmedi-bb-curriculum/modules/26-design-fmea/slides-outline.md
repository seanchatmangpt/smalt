# Module 26 — Design FMEA (DFMEA) for the Gimbal Boring Operation

DMEDI Black Belt curriculum. Running case: CascadeProjects Precision Components
(CPPC), SR-71 drone-gimbal housing, aluminum 7075. Course constants come from
`../../RUNNING-CASE.md`; anchored S/O/D tables live in `scales-anchored.md`.
Every number re-derives from `data/dfmea-worksheet.csv` via
`scripts/derive_keys.py` (court exit 0 = green).

## 1. Why DFMEA sits in DMEDI Develop

- Explore produced the concept portfolio (modules 13-16; TRIZ concepts C1-C8).
  DFMEA is where the surviving concepts are stress-tested against the ways the
  DESIGN can fail before the pilot (module 42) exists.
- DFMEA attacks part- and process-design failure modes (boring operation:
  tools, fixtures, gauging strategy, setup method). PFMEA attacks the running
  process in production. Boundary case: FM-12 (wrong NC program at setup) —
  its action is PFMEA-class, and the worksheet flags the boundary explicitly.
- Forward links: the recommended-action list feeds the detailed-design
  checklist (module 27), and the physics-bearing modes feed the DOE factors
  (modules 29-31, 37): spindle speed, feed rate, coolant concentration, tool
  coating; responses bore-diameter deviation (um) and Ra (um).

## 2. Generic scales are rejected — teach why anchoring matters

Generic 1-10 FMEA scales ("7 = customer dissatisfied") fail three ways:

1. **Rater drift** — two engineers split 6 vs 9 on the same misload because
   the generic anchor names no observable referent; the resulting RPN spread
   is pure rater noise.
2. **No PPM linkage** — occurrence words ("occasional", "frequent") map to
   nothing measurable, so ratings cannot be validated against process data.
3. **Detection detached from controls** — "D = 4" names no gauge, frequency,
   or escape probability, so DFMEA actions cannot be costed or verified.

Anchoring converts rating from opinion into classification against
CPPC-specific observables: severity anchored to CPPC outcomes (3 = cosmetic
Ra drift ... 10 = scrap + shipment escape), occurrence anchored to PPM bands,
detection anchored to named detection controls. Rating law: **a rating you
cannot cite an anchor row for is an opinion wearing a number**; if you cannot
name the detection control, D is 7 or worse. Full anchor tables:
`scales-anchored.md` — each row cites CPPC evidence (tool-wear.csv drift,
deburr logs, ramp-up incident log).

## 3. DFMEA anatomy on one mode (FM-01)

- Item/function: bore diameter / hold 12.000 mm ± 0.025 mm (CTQ-1).
- Failure mode: progressive insert flank wear → bore oversize.
- Effect: bore drifts oversize toward USL; end-of-tool-life escape possible.
  S = 10 (scrap + shipment escape anchor). Severity is rated on the worst
  credible EFFECT, not the likely one.
- Cause: wear rate not modeled in offsets. O = 6 (~3,000 PPM band; matches
  tool-wear.csv drift exceeding 8 um by part ~900).
- Current control: EOL CMM sample n=3/shift, manual → D = 6.
- RPN = 10 x 6 x 6 = 360 — top-ranked mode.
- Action DC-01 (AE tool monitor + compensated in-process gauge, TRIZ C6+C1):
  O 6→3, D 6→3, post RPN 90. Severity stays 10 — **actions move occurrence
  and detection; only a design change moves severity** (a 12.000 mm bore in
  7075 is fixed by the product, not the process).

## 4. The full worksheet — 12 failure modes, ranked by the court

Do not trust these literals — the court re-derives them; the table below is
the court's verified output. RPN = S x O x D.

| Rank | Mode | RPN pre | S/O/D pre | AP pre | Action (TRIZ link) | RPN post | AP post |
|---|---|---|---|---|---|---|---|
| 1 | FM-01 tool-wear oversize | 360 | 10/6/6 | High | DC-01 AE monitor + compensated gauge (C6+C1) | 90 | High |
| 2 | FM-06 misload / not seated | 288 | 9/4/8 | High | DC-06 poka-yoke fixture + seating sensor (TRIZ 24) | 36 | Medium |
| 3 | FM-10 thermal warmup drift | 245 | 7/5/7 | High | DC-10 warmup + thermal offset model (C7) | 42 | Low |
| 4 | FM-09 exit burrs | 224 | 4/7/8 | Medium | DC-09 edge break on drawing (C3) | 12 | Low |
| 5 | FM-05 tool breakage | 216 | 9/3/8 | High | DC-05 AE monitor + insert schedule (C6) | 72 | High |
| 6 | FM-03 taper | 210 | 6/5/7 | High | DC-03 segmented rough/finish toolpath (C3) | 48 | Low |
| 7 | FM-04 undersize (cutter comp) | 140 | 5/4/7 | Low | DC-04 offset verify + compensated gauge (C1) | 20 | Low |
| 8 | FM-02 chatter marks | 140 | 4/5/7 | Medium | DC-02 adaptive feed control (C2) | 32 | Low |
| 9 | FM-08 Ra drift | 126 | 3/6/7 | Medium | DC-08 Ra on production gauge (C2) | 36 | Low |
| 10 | FM-07 true-position error | 120 | 8/3/5 | Medium | DC-07 fixture PM + seating sensor (C5) | 32 | Low |
| 11 | FM-12 wrong program at setup | 108 | 9/2/6 | High | DC-12 program-match interlock (TRIZ 24) | 36 | Medium |
| 12 | FM-11 coolant drift | 100 | 5/5/4 | Low | DC-11 inline refractometer (C7) | 40 | Low |

## 5. RPN vs risk matrix vs AP table — teach all three

- **RPN (S x O x D)**: continuous 1-1000 scale, easy to rank, easy to misuse.
  Computed teaching moment from the table above: FM-09 (burrs, S=4, RPN 224)
  outranks FM-05 (tool breakage, S=9, RPN 216) — an equal-weight product lets
  a cosmetic-adjacent mode outrank a scrap-class mode. The AP table separates
  what RPN collapses: FM-01 (S=10) stays High even after its RPN falls 360→90.
- **S x O risk matrix**: plot each mode on a 10x10 grid (severity rows,
  occurrence columns); zones set review depth. It drops D entirely — useful
  for design-phase review where detection controls do not exist yet, weak as
  a production queue. CPPC zones: S>=9 AND O>=4 (contains FM-06 pre-action)
  is "design change required before pilot"; S>=9 anywhere is "cannot launch
  without a named control"; the diagonal band S x O >= 24 is "review monthly".
- **AP table (AIAG-VDA)**: severity-first lookup — for each S band, the
  (O, D) cell sets High/Medium/Low. Implemented in `scripts/derive_keys.py`
  as `ap_class()` and documented in `scales-anchored.md`. Severity-first law:
  an S=10 mode can never de-escalate below High (FM-01 stays High post-action:
  it earns monitoring, not closure); S=9 modes with weak controls stay High
  until BOTH O and D drop (FM-05: O 3→2, D 8→4 still High because D=4).
- Teach the division of labor: **RPN orders the workload; the matrix gates
  the design review; AP decides the queue.** The three disagree by design —
  where they disagree (FM-09 vs FM-05) is where the team must think, not
  where a formula should be trusted blindly.

## 6. Recommended actions → TRIZ traceability (Lane 06 concepts)

Every action cites its module 13/14 concept portfolio entry:

- DC-01 (FM-01): C6 acoustic-emission tool monitor (TRIZ 23 feedback) + C1
  compensated in-process gauge (TRIZ 24 intermediary). Tool wear becomes a
  measured, compensated signal instead of an unmodeled drift.
- DC-02 (FM-02): C2 adaptive feed control (TRIZ 25). C8 gradient boring bar
  (TRIZ 40) explicitly PARKED — feasibility 1/5; DFMEA records the park.
- DC-03 (FM-03): C3 segmented rough/finish toolpath (TRIZ 3 local quality).
- DC-04 (FM-04): C1 compensated gauge as detection backstop behind an offset
  verify step (error-proofing first, gauge second).
- DC-05 (FM-05): C6 AE monitor + scheduled insert changes.
- DC-06 (FM-06): poka-yoke fixture (TRIZ 24 intermediary) + seating sensor.
- DC-07 (FM-07): C5 re-grip elimination reduces datum re-establishment error.
- DC-08 (FM-08): C2 adaptive feed + shared production gauge.
- DC-09 (FM-09): C3 local quality applied at the drawing (edge break).
- DC-10 (FM-10): C7 thermal-error model + offset (TRIZ 35). C4 cryogenic
  cooling (TRIZ 39) PARKED at feasibility 2/5 — recorded, not forgotten.
- DC-11 (FM-11): C7 applied to coolant state monitoring.
- DC-12 (FM-12): poka-yoke interlock (TRIZ 24 intermediary).

## 7. Forward links to DOE (module 29-31, 37)

The physics-bearing causes feed the pinned DOE factor set verbatim:
- FM-01, FM-02 → spindle speed, feed rate (wear and stability lobes).
- FM-03, FM-08, FM-11 → coolant concentration.
- FM-05 → tool coating (coated/uncoated).
- Responses: bore-diameter deviation (um), Ra (um) — the same responses
  RUNNING-CASE pins. Non-physics modes (FM-04, FM-06, FM-12) are
  error-proofing actions — deliberately OUTSIDE the DOE; a DOE cannot
  optimize a dropdown menu.

## 8. Court

`python3 scripts/derive_keys.py` — re-derives every RPN (109 checks), every
rank (severity-desc, mode_id tiebreak), every AP class, enforces S/O/D ranges
and no-post-worse-than-pre, exits 1 on any drift. Court standing: exit 0,
109 PASS witnessed 2026-11-04.

## 9. Learning objectives

By the end of this module you will be able to:

1. Score severity/occurrence/detection for a boring-operation failure
   mode using ONLY the anchored tables in `scales-anchored.md`, citing
   the anchor text that fixes each rating (no generic-scale drift).
2. Compute RPN = S x O x D and assign the AP class pre- and post-action
   for all 12 worksheet modes, matching `solution-key.md`.
3. Explain the FM-09-vs-FM-05 RPN-vs-AP rank disagreement (224 vs 216)
   and state which ranking the CPPC team acts on and why.
4. Apply the post-action laws: severity never improves without a design
   change, FM-01 (S=10) stays AP High permanently, FM-05 stays AP High
   until D <= 3.
5. Route each recommended action to its DMEDI downstream (module 27
   checklist, DOE factors in modules 29-31/37, PFMEA boundary for
   FM-12).

## 10. Session timing

- Anchored-scale briefing: why generic 1-10 scales fail (rater drift,
  no PPM linkage) (15 min)
- Guided scoring of 3 modes from the worksheet against the anchors (20 min)
- RPN + AP computation across all 12 modes, instructor arithmetic
  visible against `solution-key.md` (25 min)
- RPN-vs-AP disagreement debate (FM-09/FM-05) and action routing (15 min)
- Post-action rescoring exercise, each learner re-scores 2 modes with
  the laws applied (15 min)

## 11. Tools

DFMEA has no Minitab dialog — the tool surface is the worksheet plus the
python mirror: `python3 scripts/derive_keys.py` re-derives every RPN,
rank, and AP class from `data/dfmea-worksheet.csv` (exit 0, 109 PASS,
witnessed 2026-11-04); instructors score in the spreadsheet and check
each rating against `scales-anchored.md`, learners verify their RPN/AP
results against the key before the debrief.

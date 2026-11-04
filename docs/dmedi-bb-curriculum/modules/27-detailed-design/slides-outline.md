# Module 27 — Detailed Design: From DFMEA Actions to Design Controls, DFX, and the Tolerance-Capability Link

DMEDI Black Belt curriculum. Running case: CPPC gimbal boring operation.
Upstream: module 26 DFMEA (12 failure modes, actions DC-01..DC-12).
Downstream: DOE (modules 29-31, 37) on spindle speed / feed rate / coolant
concentration / tool coating; pilot (module 42). Court:
`python3 scripts/derive_keys.py` (exit 0 = green; derives the tolerance math
and re-checks the DFMEA-to-checklist linkage against the module 26 worksheet).

## 1. The chain this module teaches

DFMEA action (DC-xx) → design control → verification method + acceptance
criterion → control-plan row (CP-nn) → DFX class. A recommended action that
cannot name its verification method and acceptance criterion is not a design
decision; it is a wish. The checklist
(`data/design-control-checklist.csv`, 18 rows) is the audited artifact.

## 2. Design-control plan table (abridged; CSV is authority)

| CP | Action | Control | Type | DFX | Acceptance (abridged) |
|---|---|---|---|---|---|
| CP-1 | DC-01 | AE monitor + compensated in-process gauge | process control | meas | trip within 3 parts of seeded wear onset |
| CP-2 | DC-02 | adaptive feed + Ra on production gauge | process control | DFT | zero undamped chatter in 30-part run |
| CP-3 | DC-02b | gauge R&R study | measurement | meas | R&R < 10% of tolerance |
| CP-4 | DC-03 | segmented rough/finish + 3-depth traverse | process control | DFM | taper <= 2 um over 12 mm depth |
| CP-5 | DC-04 | offset verify interlock | error-proofing | meas | refuses 10/10 seeded wrong entries |
| CP-6 | DC-04b | first-article layout per shift | process control | meas | within guard band ±0.008 |
| CP-7 | DC-05 | AE monitor + insert schedule | process control | DFM | changes fire before AE degradation |
| CP-8 | DC-06 | poka-yoke fixture + seating sensor | error-proofing | poka | misload refused 30/30 trials |
| CP-9 | DC-07 | fixture PM + sensor | maintenance | DFM | datum wear <= 2 um at PM interval |
| CP-10 | DC-07b | bore entrance chamfer on drawing | design change | DFA | insertion force < 12 N, no skew in 20 trials |
| CP-11 | DC-08 | Ra on production gauge | process control | meas | r >= 0.9 vs lab profilometer |
| CP-12 | DC-09 | edge break + feed-exit geometry | design change | DFM | exit burr <= 50 um across DOE feed levels |
| CP-13 | DC-10 | warmup + thermal offset model | process control | DFT | first-piece deviation <= 3 um |
| CP-14 | DC-10b | gauge 3-depth reach check | measurement | DFT | contacts all 3 depths on 100% of family |
| CP-15 | DC-11 | inline refractometer | process control | meas | alarm within 15 min of seeded drift |
| CP-16 | DC-12 | program-match interlock | error-proofing | poka | wrong program refused 10/10 trials |
| CP-17 | DC-13 | guard-band gauge limits ±0.008 mm | measurement | meas | uncertainty <= 10% of 0.008 mm |
| CP-18 | DC-13b | guard-band rationale doc | documentation | meas | cites the derivation below |

DFX classes: DFM (machinability: toolpath segmentation, insert life, edge
break, fixture PM), DFA (DC-07b entrance chamfer — bearing insertion without
a guide fixture), DFT (testability: chatter trip tests, thermal-model first-
piece checks, gauge 3-depth reach), meas (measurement systems incl. the
mandatory gauge R&R before any in-process gauge is trusted), poka (the two
interlocks; taught as its own class because error-proofing outranks detection).

## 3. Drawing tolerance to process capability — the derivation

Guard-banding: the production drawing carries an INTERNAL control tolerance
of 12.000 mm ± 0.008 mm, deliberately tighter than the customer spec of
12.000 mm ± 0.025 mm (CTQ-1). Why: holding the inside band makes spec escape
require two independent failures (process shift + gauge error), and it gives
the control chart room to detect drift before the customer's limit.

The math (derived, not asserted — the court recomputes it):

1. Required sigma for Cpk >= 1.33 on the guard band:
   sigma_max = 0.008/(3 x 1.33) = **2.01 um**.
2. Baseline capability against the guard band:
   Cpk = 0.008/(3 x 0.00417) = **0.64**.
3. Same baseline against the customer spec at mu = 12.009:
   Cpk = (0.025 - 0.009)/(3 x 0.00417) = **1.28** (the MANIFEST cross-note
   value; the pinned 0.72 constant contradiction is Lane 05's flagged item —
   this module does not silently inherit it).
4. Centered, the spec-level Cpk would be 0.025/(3 x 0.00417) = **2.00** —
   the 1.28 vs 2.00 gap is the off-center mean (mu = 12.009), and closing it
   is a CENTERING action (module 43 control planning), distinct from variation
   reduction.
5. What the DOE must deliver: in the RUNNING-CASE pinned regime (sigma
   4.17 um) sigma must fall 4.17/2.01 = **2.08x** (4.33x variance); in the
   adjudicated spine regime carried by MANIFEST rows 16/21/23 (sigma
   7.407 um) the requirement is 7.407/2.01 = **3.69x** (13.6x variance).
   This number is the Develop-phase requirement handed to the DOE modules:
   if the spindle speed x feed rate x coolant x coating experiment cannot
   demonstrate the required sigma reduction on bore diameter, the guard band
   must be widened back toward the spec band and the DFMEA re-run (FM-01's
   D and the detection controls carry that risk).

Teaching law: **a drawing tolerance is a claim about process capability.
Writing ±0.008 on the drawing without the 2.08x sigma reduction is an
unfunded capability mandate** — the checklist rows CP-17/CP-18 exist so the
claim and its derivation ship together.

## 4. Court

`python3 scripts/derive_keys.py` exit 0: six tolerance-math checks re-derived
from pinned constants, plus the linkage court (12 DFMEA actions all present
in the checklist; 6 documented detailed-design additions DC-02b/04b/07b/10b/
13/13b; 18 unique CP rows CP-1..CP-18; control types and DFX classes
in-domain; all five DFX classes exercised). Witnessed 2026-11-04.

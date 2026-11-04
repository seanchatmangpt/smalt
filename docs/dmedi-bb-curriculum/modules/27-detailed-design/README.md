# Module 27 — Detailed Design: From DFMEA Actions to Design Controls, DFX, and the Tolerance-Capability Link

DMEDI Black Belt curriculum. Running case: CPPC gimbal boring operation.
Upstream: module 26 DFMEA (12 failure modes, actions DC-01..DC-12).
Downstream: DOE (modules 29-31, 37) on spindle speed / feed rate / coolant
concentration / tool coating; pilot (module 42). Court:
`python3 scripts/derive_keys.py` (exit 0 = green; derives the tolerance math
and re-checks the DFMEA-to-checklist linkage against the module 26 worksheet).

## Learning objectives

1. Convert every DFMEA recommended action into a design control with a named
   verification method and a measurable acceptance criterion (measurable: the
   18-row checklist audits 12 DFMEA actions plus 6 documented additions).
2. Derive the internal guard-band tolerance from the capability target:
   sigma_max = guard/(3 x Cpk_target), and state the sigma/variance reduction
   the baseline must deliver (measurable: exercise 1 arithmetic).
3. Verify a design control against its acceptance criterion with real seeded
   data and state PASS/FAIL honestly, including per-piece vs mean-based
   readings of the same criterion (measurable: exercise 3, thermal study).
4. Classify controls across the five DFX classes (DFM/DFA/DFT/meas/poka) and
   name the error-proofing subset (measurable: exercise 4).
5. Trace each control-plan row CP-1..CP-18 to its DFMEA action and its
   downstream owner module (12 -> capability, 43 -> control plan, 42 -> pilot)
   (measurable: exercise 5 table complete).

## 1. The chain this module teaches

DFMEA action (DC-xx) -> design control -> verification method + acceptance
criterion -> control-plan row (CP-nn) -> DFX class. A recommended action that
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
| CP-6 | DC-04b | first-article layout per shift | process control | meas | within guard band +/-0.008 |
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
| CP-17 | DC-13 | guard-band gauge limits +/-0.008 mm | measurement | meas | uncertainty <= 10% of 0.008 mm |
| CP-18 | DC-13b | guard-band rationale doc | documentation | meas | cites the derivation below |

## 3. Worked example 1 — the guard-band derivation (15 min, every step shown)

Why an internal tolerance of +/-0.008 mm inside a customer spec of +/-0.025 mm?

Step 1 — the capability target law: Cpk >= 1.33 on the CONTROL tolerance, not
the customer spec. The largest process sigma that satisfies it inside a
half-width H is sigma_max = H/(3 x 1.33). With the guard band H = 0.008 mm:
sigma_max = 0.008/3.99 = **0.002005 mm = 2.01 um**.

Step 2 — where the baseline stands (adjudicated spine, RUNNING-CASE.md:
mu = 12.009 mm, sigma = 7.407 um): baseline Cpk against the guard band
= 0.008/(3 x 0.007407) = 0.008/0.022221 = **0.36**.

Step 3 — the required reduction: sigma 7.407 -> 2.005 um is a factor
7.407/2.005 = **3.69x in sigma**, which is (3.69)^2 = **13.6x in variance**.
Variance is what additions consume: 3.69x sigma reduction is NOT 3.69
improvements of 3.69/4 each — it is four independent variance cuts of ~2.4x
each, or the DOE (modules 29-31) finding the big terms first.

Step 4 — why guard-band the gauge at all: the customer spec carries incoming
gage error and transport drift the shop does not control. Holding the process
to +/-0.008 keeps escapes impossible even when the measurement system eats
0.017 mm of the customer's 0.025 mm half-width. CP-17 caps gauge uncertainty at
10% of 0.008 mm so the guard band stays honest.

(For reference the same formulas against the customer spec at the OLD sigma
pin 4.17 um give Cpk 1.28 — that comparison lives in `scripts/derive_keys.py`,
which asserts both regimes so the history is checkable rather than argued.)

## 4. Worked example 2 — verifying CP-13 with real data (15 min)

Acceptance criterion (DC-10, CP-13): first-piece deviation <= 3 um with the
thermal model active. Dataset: `data/thermal-warmup-study.csv`, generated by
`scripts/gen_verification_dataset.py` (python3 random, seed 2711; 12 paired
warmup trials, deviation from 12.000 mm nominal in um).

Derivation:

1. No-model arm: mean **9.34 um**, sd **1.57 um**, all 12 trials > 3 um.
2. With-model arm: mean **2.14 um**, sd **1.44 um** — mean reduction 7.20 um,
   a 4.36x improvement; paired d-bar 7.20, sd_d 1.95, t = 12.8.
3. Verdict — read the criterion exactly as written: it is PER-PIECE
   ("first-piece deviation <= 3 um"), so the trial-level breaches (trial 6:
   4.8 um; trials 7 and 12: 3.4 um) make this **FAIL as specified**, even
   though the mean passes. Mean-based PASS would be overclaiming.
4. Lawful follow-up: the model is directionally right but the warmup duration
   before model activation is underspecified — extend warmup or widen the
   criterion with a documented rationale, re-verify. A FAIL with a named next
   action is honest; a PASS on the mean is not.

## 5. DFX coverage (why all five classes must appear)

DFM (segmented toolpaths, insert scheduling, exit geometry), DFA (chamfer so
the bearing inserts without a guide fixture), DFT (adaptive feed, thermal
model, gauge reach), measurement (gauges, R&R, refractometer), poka-yoke
(misload and wrong-program interlocks). The court asserts all five are
exercised; a detailed-design phase that only adds inspection has not designed
anything.

## Timing (90-min session)

- The DFMEA -> control -> CP chain; what makes a criterion measurable (10 min)
- Worked example 1: guard-band derivation (15 min)
- Worked example 2: CP-13 verification with seeded data (15 min)
- Lab: draft 3 new checklist rows for a peer's failure mode, criteria
  measurable and DFX-classified (25 min)
- Exercise set 1-6 (15 min)
- Court run + gate discussion (10 min)

## Tool note

- Minitab: Stat > Basic Statistics > 2-Sample t (or Paired t) for the thermal
  study arms (paired is lawful here — same trials, with/without model);
  Stat > Control Charts or Capability Analysis for the guard-band argument
  (Specs 11.992/12.008, sigma target 2.0 um shows why the DOE is needed).
  Measurement-class rows: Stat > Quality Tools > Gage Study (Module 11).
- python3 mirror: `scripts/derive_keys.py` (court, exit 0 = the tolerance math
  and linkage) and `scripts/gen_verification_dataset.py` + the derivation in
  `keys/solution-key.md` (thermal study).

## Consistency pins consumed

- RUNNING-CASE.md adjudicated spine: spec 12.000 +/- 0.025 mm, mu 12.009,
  sigma 7.407 um, Cpk target 1.33.
- Module 26 DFMEA worksheet (12 modes, actions DC-01..DC-12) — linkage asserted
  by `scripts/derive_keys.py` (not edited by this module).
- Module 43 owns the control plan that operationalizes CP rows at production
  cadence; Module 12 owns the capability study behind Step 3.

## Gate checklist

- [ ] `python3 scripts/derive_keys.py` exits 0 (tolerance math + linkage)
- [ ] sigma_max 2.01 um, guard-band Cpk 0.36, 3.69x sigma / 13.6x variance derived by hand
- [ ] Thermal study verdict stated as FAIL-as-specified with the per-piece reading shown
- [ ] Every drafted checklist row has method + criterion + DFX class
- [ ] All five DFX classes can be named with one CP example each

# Module 14 — TRIZ for Product Processes

# TRIZ for Product Processes (Develop)

Course spine: CPPC. Pinned constants come from `../../RUNNING-CASE.md` and are
never varied here. This module is the reference artifact for the 40 inventive
principles: one product example AND one transactional example per principle
(40 x 2), a contradiction-matrix walkthrough on the CPPC speed-vs-accuracy
contradiction, and two case studies solved end to end.

## Learning objectives

1. State a contradiction in the TRIZ form (improving parameter vs worsening
   parameter) instead of a vague tradeoff.
2. Use the 40-principle index to generate candidates for a contradiction.
3. Walk a contradiction-matrix lookup and re-verify it (courts re-verify every
   lookup in this module).
4. Solve two full cases end to end, with every numeric step numbered and
   re-derivable from `datasets/tool-wear.csv` via `scripts/derive_keys.py`.

## Case study 1 (solved in full): tool wear vs cycle time

### Step 1 — State the contradiction

Increase spindle speed to cut cycle time (CTQ-2 pressure; CTQ-3 cost pressure)
and the cutting edge wears faster, so bore diameter drifts out of the
12.000 +/- 0.025 mm band: **improving parameter = Speed (#9), worsening
parameter = Accuracy of manufacture (#28)**.

### Step 2 — Quantify the wear law

Synthetic wear study, seed 1419 (`datasets/tool-wear.csv`, 40 observations,
parts 100..4000, drift in um, rounded to 0.01):

- Regression: drift = 0.3155 + 0.0079 * parts (um). Slope 0.0079 um/part
  = 0.79 um per 100 parts; residual s = 0.56 um.
- Deterministic drift dominates: at 500 parts the bore has grown 3.94 um from
  nominal just from wear — most of the +/- 25 um tolerance band.

### Step 3 — Matrix lookup

Course-excerpt lookup for improving #9 vs worsening #28: principles
**3, 17, 24, 32**. (This excerpt is pinned for the course; any use of the full
39x39 matrix must be re-verified against a cited printed source — the excerpt
itself is the court's re-verification target.)

- Principle 3 (local quality): make the roughing pass and finishing pass
  locally different — finish pass takes the light cut that defines the
  diameter, so edge wear during roughing never touches the final dimension.
- Principle 17 (another dimension): move the compensation actuator to another
  axis/mode — e.g., axial micro-positioning of the bar rather than radial
  tool-presets.
- Principle 24 (intermediary): insert a carrier between the wear-prone edge
  and the reference — an in-process gauge holds the reference and drives a
  compensation offset, so the wearing edge is decoupled from "what is
  12.000".
- Principle 32 (optical property change): use optical measurement directly —
  an optical bore gauge replaces contact trial-cut reference.

### Step 4 — Work each principle to a concept, then decide

Working all four: 24 gives the concept Module 13 scored first (compensated
in-process gauge, C1); 3 is already portfolio concept C3; 17 and 32 are
enrichments. Chosen concept: **24 + periodic offset update every 100 parts**.

### Step 5 — Compute the contradiction resolution

- Uncompensated lag with 100-part updates: 0.0079 um/part * 100 parts
  = 0.79 um — well inside the remaining tolerance; the wear law is now a
  scheduled correction instead of a drift risk.
- Compensation residual: gauge + machine short-term sigma = 0.65 um (stated
  assumption, to be confirmed by the Module 16 MSA), so short-term error is
  dominated by the 0.56 um regression residual, not by wear.
- Cycle time: baseline 7.5 min/bore at 6000 RPM; at 7200 RPM the same bore
  takes 6.4 min. Output 480/7.5 = 64 bores/shift -> 480/6.4 = 75 bores/shift,
  a gain of 11 bores/shift (+14.7%) with accuracy preserved by compensation
  rather than by slowing down. The contradiction is resolved, not traded.

### Step 6 — Honest boundary

The wear dataset extends to 4000 parts where drift reaches 32.59 um — beyond
the 25 um half-band. Compensation arithmetic keeps the *bore* in tolerance
only while the gauge and actuator hold their own accuracy; edge replacement
still happens on a wear schedule. Compensation changes who is responsible for
the dimension (gauge, not edge); it does not repeal wear.

## Case study 2 (solved in full): lead time vs inspection thoroughness

### Step 1 — State the contradiction

Thorough final inspection protects CTQ-1 escapes but queues every lot behind
100% inspection, inflating CTQ-2 lead time (baseline 18.4 d, target <= 7 d).
**Improving parameter = quantity of substance/inspection coverage; worsening
parameter = time (#25 loss of time)** — here we use the functional statement:
coverage vs queue time.

### Step 2 — Quantify the queue

100% final inspection adds 2.1 days of queue per lot (Measure baseline).

### Step 3 — Matrix lookup and principle choice

Coverage-vs-time is a classic coverage/quantity vs time cell; the excerpt
lookup yields principles including **10 (prior action), 24 (intermediary),
26 (copying), 35 (parameter change)**. Chosen: **10 + 26** — skip-lot
inspection: prove a lot family clean with prior action (10 consecutive
zero-defect lots fully inspected), then inspect subsequent lots by a *copy*
(a sampled audit) instead of 100% contact.

### Step 4 — Compute the skip-lot scheme

- Lot size 200 units, true defect rate p = 0.012.
- Probability a fully inspected lot shows zero defectives:
  (1 - 0.012)^200 = 0.0894. Ten consecutive such lots is a strong prior that
  the family is stable-clean (this is the gate condition; the low per-lot
  probability is exactly why ten consecutive zero lots is real evidence, not
  luck).
- After the gate, inspect 1 of every 3 lots fully; the other 2 skip.
- Expected defectives in a skipped lot at p = 0.012: 200 * 0.012 = 2.4 —
  skipping is NOT free; the scheme must be paired with a triggered full
  reversion: any defect found in a sampled lot reverts the family to 100%.

### Step 5 — Compute the lead-time effect

Queue scales with inspection load: skipping 2 of 3 lots takes queue from
2.1 d to 2.1 * (1/3) = 0.70 d, a saving of 1.40 d per lot. Against the 18.4 d
baseline this is a 7.6% lead-time reduction from this lever alone.

### Step 6 — Risk arithmetic (honest fail mode)

If the defect rate drifts to p = 0.05 while the family still skips, expected
escapes are 10000 * (2/3) * 0.05 = 333 per 10,000 units — catastrophic. The
triggered reversion and a periodic full audit are not decoration; the module's
court question is: does your scheme detect a drift before 333 escapes? (This
risk computation is the bridge to Module 15, where the same tradeoff is solved
on claims audits.)

## Contradiction matrix walkthrough (reference)

Form: pick the parameter you are improving and the one that degrades; the
matrix cell recommends 3-4 principles. Course excerpt (pinned; re-verify
against a cited full matrix before industrial use):

| Improving | Worsening | Principles | CPPC worked meaning |
|---|---|---|---|
| 9 Speed | 28 Accuracy of manufacture | 3, 17, 24, 32 | Case study 1 |
| 9 Speed | 25 Loss of time | 10, 24, 26, 35 | Case study 2 analog |
| 27 Reliability | 24 Loss of information | 10, 24, 26, 35 | in-process data logging |
| 33 Ease of operation | 28 Accuracy of manufacture | 24, 26, 32 | gauge-operated offset |
| 36 Device complexity | 27 Reliability | 3, 10, 24 | gauge adds parts but raises reliability |

Walkthrough discipline: (1) name both parameters in TRIZ numbering; (2) look
up; (3) generate one concept per recommended principle; (4) score; (5) re-verify
the lookup before scoring is admitted.

## The 40 principles: one product + one transactional example each

Product examples lean on the CPPC machining context; transactional examples
lean on claims processing, onboarding, procurement (Module 15's surface).

| # | Principle | Product example | Transactional example |
|---|---|---|---|
| 1 | Segmentation | Divide the rough cut into segmented light passes | Split one monolithic approval form into staged micro-approvals |
| 2 | Taking out | Separate the finishing function onto a dedicated finishing tool | Extract exception-handling from the claims queue into a specialist team |
| 3 | Local quality | Rough vs finish geometry on one tool (C3) | Different audit depth by claim risk band, not uniform audit |
| 4 | Asymmetry | Asymmetric clamp to resist cutting torque | Approval power weighted by dollar value, not flat |
| 5 | Merging | Combine drilling and boring in one setup | Merge intake and eligibility checks into one touchpoint |
| 6 | Universality | One tool holder serves rough and finish inserts | One intake form serves all claim classes |
| 7 | Nesting | Coolant line routed inside the bar bore | Onboarding checklist nested inside the HRIS workflow |
| 8 | Counterweight | Counterbalanced headstock to damp vibration | Workload balancing pool offsets surge claims between teams |
| 9 | Prior counteraction | Pre-load the structure against expected deflection | Pre-audit the highest-risk fields before the claim enters the queue |
| 10 | Prior action | Gate skip-lot qualification with 10 clean lots (case 2) | Pre-verify vendor insurance before contract signature |
| 11 | Beforehand cushioning | Backup boring head staged at the machine | Pre-approved fallback supplier held under contract |
| 12 | Equipotentiality | Machine and gauge share the same reference plane | Both reviewer and preparer work from the same system of record |
| 13 | Inversion | Let the work rotate, tool fixed (turn vs mill) | Instead of pushing claims through review, pull review to claim risk |
| 14 | Spheroidality | Ball-nose corner strategy to spread cutting load | Replace binary approve/reject with graduated risk scoring |
| 15 | Dynamics | Adaptive feed that changes with measured load (C2) | Rotating audit sample re-drawn every cycle instead of fixed list |
| 16 | Partial or over-action | Spring pass: slight over-travel then finish | Over-collect documentation once, then trim to what audits need |
| 17 | Another dimension | Axial micro-positioning for compensation (case 1) | Move compliance check to a parallel lane instead of serial chain |
| 18 | Mechanical vibration | Ultrasonic-assisted machining for hard alloy | Anonymous pre-submission feedback channel to catch errors early |
| 19 | Periodic action | Tool change every N parts on a wear schedule (case 1) | Monthly compliance sweep instead of continuous interrupt-driven review |
| 20 | Continuity | Continuous compensation instead of episodic trial cuts | Continuous sampling audit instead of end-of-quarter review burst |
| 21 | Rushing | Skim-fast, dwell-fine micro-pass | Fast-track small claims through an expedited lane |
| 22 | Convert harm to benefit | Use chip-heat data as the thermal model input (C7) | Turn audit findings into the training curriculum |
| 23 | Feedback | Acoustic emission monitor triggers tool change (C6) | Real-time audit flags during claim entry, not after |
| 24 | Intermediary | In-process gauge mediates reference (case 1, C1) | Independent QA sampler mediates between processor and auditor |
| 25 | Self-service | Machine compensates itself from its own gauge | Claim form validates itself at entry (field-level rules) |
| 26 | Copying | Skip-lot copies clean-family status via samples (case 2) | Audit a sample copy of the file, not every file |
| 27 | Cheap disposables | Disposable wiper seals on the gauge | Disposable sandbox environment for onboarding practice |
| 28 | Mechanics substitution | Optical bore gauge replaces mechanical trial cuts | E-signature replaces wet-ink routing |
| 29 | Pneumatics | Air-gauging the bore for fast measurement | Automated data pull replaces manual document collection |
| 30 | Flexible shells | Thin-wall compliant bushing for thin-wall parts | Flexible checklists that adapt to case complexity |
| 31 | Porous materials | Porous damper insert in the tool holder | Knowledge-base articles embedded where processors work |
| 32 | Optical property change | Optical in-process measurement (case 1) | Visual dashboard flags instead of textual audit notes |
| 33 | Homogeneity | Gauge and machine parts of the same reference standard | Reviewer drawn from the same process family as preparer |
| 34 | Discarding and recovering | Recondition inserts, recycle chips | Auto-expiring temporary access grants at onboarding end |
| 35 | Parameter change | Thermal-error model shifts machine state (C7) | Change audit cadence with measured claim risk |
| 36 | Phase transition | Cryogenic cooling changes the thermal regime (C4, parked) | Case type switches queue behavior at a volume threshold |
| 37 | Thermal expansion | Use controlled thermal growth as a micro-actuator | SLA clock drives automatic escalation, no human timer |
| 38 | Strong oxidants | High-pressure coolant as the active chip-break medium | Escalate stalled claims to a senior reviewer automatically |
| 39 | Inert atmosphere | Cryo/controlled environment spindle (C4) | Immutable audit log — evidence cannot be edited retroactively |
| 40 | Composite materials | Gradient-index boring bar (C8, killed in M13) | Cross-functional review panel (mixed skills, one decision) |

## Files in this bundle

- `workshop.md` — learner exercises.
- `solution-key.md` — numbered case-study steps with the python receipts.
- `datasets/tool-wear.csv` — synthetic wear study, seed 1419.
- `scripts/derive_keys.py` — re-derives every numeric key from the CSV.

## See Also

- `../13-concept-generation/README.md` — portfolio that chose concept C1.
- `../15-triz-transactional/README.md` — the transactional half.
- `../../RUNNING-CASE.md` — pinned constants.

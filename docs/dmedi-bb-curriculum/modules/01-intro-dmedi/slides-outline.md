# Module 01 — Intro to DMEDI (Slides Outline)

**Module**: 01-intro-dmedi
**Learning objectives** — after this module the Black Belt candidate can:
1. State the five DMEDI phases and what artifact each phase must produce to pass its tollgate.
2. Distinguish DMEDI (new design / new process) from DMAIC (existing process) and justify the choice on a real project brief.
3. Explain evidence-based tollgates: a gate passes on receipts (artifacts + measured numbers), never on status narration.
4. Recite the CPPC running-case constants and compute the baseline Cpk from the pinned formula.
5. Apply the "zero artifacts at receipt time" failure case to design gate checks that cannot pass vacuously.

**Timing estimate**: 4.0 h total (slides 1.5 h, lab 1.0 h, exercises 1.0 h, court/self-check 0.5 h).
**Required tools**: python3 (stdlib only: `random`, `statistics`), any spreadsheet or plain-text editor, a terminal. No statistical packages required.

---

## Slide 1 — Why this course exists (10 min)
- Most Six Sigma curricula teach tools; projects still fail at the gates.
- Thesis of this course: a phase is DONE only when its artifacts exist and their numbers re-derive from raw data.
- Course spine: one running case (CPPC drone-gimbal CNC line) carried through all modules.
- Per-slide contract: every worked number in this course is synthetic, seed-stated, and re-derivable from a CSV.

## Slide 2 — The CPPC running case (10 min)
- CascadeProjects Precision Components: 140-person machining shop, new CNC line for the SR-71 drone-gimbal housing (7075 aluminum, 3-axis mill).
- Three CTQs pinned for the whole course:
  - CTQ-1 product: bore diameter 12.000 mm ± 0.025 mm; baseline Cpk 0.72 → target ≥ 1.33 sustained 30 days.
  - CTQ-2 transactional: order-to-ship lead time 18.4 d → ≤ 7 d.
  - CTQ-3 cost: unit cost $41.80 → ceiling $28.50.
- Program shape: 26 weeks, gate reviews at weeks 5/9/15/21/26.

## Slide 3 — DMAIC vs DMEDI (15 min)
- DMAIC: Define-Measure-Analyze-Improve-Control — repairs an EXISTING process.
- DMEDI: Define-Measure-Explore-Develop-Implement — builds a NEW process/product where no stable baseline exists to "improve".
- CPPC framing: the CNC line is NEW equipment, so DMEDI; the order-fulfillment process EXISTS, so a DMAIC-style lens applies inside its Define.
- Decision rule taught as a table: is there a stable existing process with data? yes → DMAIC; no → DMEDI.

## Slide 4 — The five phases and their artifact contracts (15 min)
- Define: charter, MGPP (market/growth/profit/position) business case, risk register, comms plan. Gate: charter signed, baseline pinned.
- Measure: capability study on real data, MSA. Gate: baseline Cpk / sigma level re-derived from raw CSVs.
- Explore: concepts generated and scored against the Measure baseline. Gate: selected concept with falsifiable claims.
- Develop: DOE, detailed design, pilot plan. Gate: DOE response surface + predicted capability.
- Implement: pilot run, control/verification plan, handoff. Gate: sustained target met for the pinned duration (30 days for CTQ-1).

## Slide 5 — Evidence-based tollgates: the failure case (20 min)
- Case study (course honesty precedent): a Black Belt program receipted SUCCESS at its final gate with ZERO `.go` build artifacts on disk at receipt time.
- What actually happened: every intermediate gate was passed by status narration ("Build phase complete") with no artifact check; the final gate inherited the vacuum.
- Cost: the program's verification ladder had no rung that could exit nonzero, so nothing ever failed — a gate that cannot fail is not a gate.
- Lessons encoded into THIS course:
  1. Every module's court (self-check) enumerates every number and re-derives it with python3, exit-checked.
  2. A gate without a falsifiable pass condition is vacuous and must be refused.
  3. SUCCESS is a receipt (subject + measured numbers + replay command), never a narrative.

## Slide 6 — Baseline capability, first derivation (15 min)
- Cpk formula: Cpk = min(USL − μ, μ − LSL) / (3σ).
- CPPC pinned baseline: μ = 12.009 mm, spec 11.975–12.025 mm, Cpk = 0.72.
- Worked derivation on the slide: the mean sits 16 µm from USL and 34 µm from LSL → the USL side governs.
- Note for students: the pinned σ implied by Cpk 0.72 is (12.025 − 12.009)/(3 × 0.72) = 7.407 µm. The ORIGINAL spine listed 4.17 µm, which yields Cpk 1.279 — ADJUDICATED stale 2026-11-04 (see RUNNING-CASE.md); this course teaches the adjudicated formula-consistent pair (0.72, 7.407 µm).

## Slide 7 — What a receipt looks like (10 min)
- Five fields: identity (exact subject), authority (who/what admits), consequence (real output, not stdout-only claim), replay (exact command to re-run), standing (pass/fail/partial as of date).
- Worked mini-example: the Module 01 lab receipt format.
- Anti-pattern: "Cpk improved" with no dataset, no seed, no command.

## Slide 8 — Course logistics and module map (5 min)
- Modules 02–03 complete Define; 04–05 VOC/QFD and Measure; later modules carry Explore/Develop/Implement on the same spine.
- Each module ships: slides outline, lab, exercises, solution key (derivation shown), court (self-check), seeded data.
- Grading principle: solution keys show derivations, so partial credit follows the work, not the answer.

## Slide 9 — Recap and lab handoff (10 min)
- DMEDI = phase-gated design discipline; gates run on receipts.
- Total: 110 min of slide time; the lab now makes you compute the baseline yourself.

## Keyed exercise — derive the baseline from the raw CSV (20 min)

**Task.** From `data/baseline-bore-diameter.csv` (50 production runs), compute n, the
mean, the sample standard deviation, and the baseline Cpk against the spine spec
11.975–12.025 mm. Then reconcile your sample result against the pinned baseline
pair (Cpk 0.72, sigma 7.407 um) and answer: which side of spec governs, and why is
the sample Cpk different from the pinned constant?

**Solution key (derivation shown, every number python3-derived).**

Step 1 — load and count. `python3` reading the CSV: n = 50 rows
(columns: run, date, operator, bore_diameter_mm).

Step 2 — mean. mu = (1/n) * sum(x_i) = 12.00859 mm. The mean sits ABOVE nominal
(12.000 mm) by 8.59 um — the process is off-center high.

Step 3 — sample standard deviation (n-1 denominator): s = 0.00582 mm = 5.82 um.

Step 4 — distance to each spec limit:
- USL side: 12.025 - 12.00859 = 16.41 um.
- LSL side: 12.00859 - 11.975 = 33.59 um.
The USL side is the smaller distance → the USL governs (matches Slide 6's pinned
pattern: the mean sitting high is the binding constraint, not the low tail).

Step 5 — Cpk = min(USL - mu, mu - LSL)/(3 s) = 16.41 um / (3 x 5.82 um) =
16.41/17.46 = **0.94**.

Step 6 — reconciliation against the pinned pair (Cpk 0.72, sigma 7.407 um).
Sample mu (12.00859) agrees with the pinned mu 12.009 mm to 0.01 um. Sample s
(5.82 um) is smaller than the pinned sigma (7.407 um), so the sample Cpk (0.94)
exceeds the pinned baseline (0.72). Both are lawful numbers: the pinned pair is the
course-wide ADJUDICATED baseline constant (see Slide 6 honest-flag note), while the
sample is what this particular 50-run CSV yields. Lesson: a pinned constant is a
contract, not an observation — when you compute from raw data you must state WHICH
you are citing and why they differ, never blend them silently.

Receipt: `python3` over `data/baseline-bore-diameter.csv` →
`n=50 mu=12.00859 s=0.00582 Cpk=0.9401 USL gap=16.41um LSL gap=33.59um`, exit 0.

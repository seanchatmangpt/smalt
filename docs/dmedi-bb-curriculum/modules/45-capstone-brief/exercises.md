# Module 45 Exercises

Every exercise maps a workbook phase to a deliverable graded against the pinned
spine constants (RUNNING-CASE.md: Cpk 0.72 → ≥ 1.33, μ = 12.009 mm,
σ = 7.407 µm, lead 18.4 d → ≤ 7 d, cost $41.80 → $28.50 ceiling). Work in
`capstone-workbook.md`; the derivation discipline each exercise demands is
demonstrated end-to-end in `worked-example-measure.md` (Phase 2). The solution
key re-derives every number from the raw CSVs — `keys/solution-key.md`.

1. **Charter carry (Define — workbook Phase 1).** Draft the five-line charter
   field set (problem statement with baseline numbers, goal with pinned targets,
   scope boundary, named roles, gate-week milestones) on the Module 03 template
   for the CPPC SR-71 gimbal line. Which single charter number, if quoted from a
   remembered lecture instead of RUNNING-CASE.md, poisons Phase 2 entirely, and
   why? (Answer shape: the baseline capability pair — a charter pinning
   σ = 4.17 µm inherits the stale 2026-11-04-adjudicated pair and computes
   Cpk ≈ 1.28, reporting a gap that does not exist; Phase 2's re-derivation then
   "mysteriously" contradicts its own charter. Adjudicated pair: σ = 7.407 µm,
   μ = 12.009 mm, Cpk 0.72.)
2. **The demonstrated Measure gate (Phase 2 — workbook §2.1–2.5).** Re-derive,
   from `data/gage-rr-bore.csv` and `data/cpk072-bore-subgroups.csv` only, the
   %GRR / ndc verdict with bands and the baseline capability pair
   (μ, R̄, σ_within, Cp, Cpk), state the §2.1 adjudication in your own words,
   and give the X̄/R stability verdict. Answer the gate question in one sentence
   and give the verdict vs target: is Cpk 0.72 vs 1.33 a PASS or a lawful NO?
   (This is the worked example's own derivation — your version must arrive at
   the same numbers from the raw CSVs, not by copying them. Cross-check:
   %GRR 13.97 / ndc 9 / Cpk 0.7199.)
3. **Phase handoffs (Analyze/Develop — workbook Phases 3–4).** State, for each
   handoff, what the receiving phase consumes and what would make the handoff
   inadmissible: (a) Measure → Explore: what exactly does Explore consume from
   §2.2, and why does an unstable baseline make every downstream hypothesis test
   inadmissible? (b) Explore → Develop: what artifact names the selected concept
   with checkable weights, and what consistency condition must its AHP weights
   satisfy (CR < 0.10)? (c) Develop → Implement: what does the RSM optimum
   window owe the pilot, and what must the confirmation runs show about
   predicted vs observed?
4. **Control plan (Implement — workbook §5.3).** Draft one control-plan row for
   CTQ-1 (bore diameter, spec 12.000 ± 0.025 mm) given the worked example's
   MSA verdict: %GRR 13.97% (10–30% band, ndc 9). Why can this row NOT simply
   chart the existing gage, and what two lawful resolutions exist? Connect to
   the worked example's documented action (control plan must upgrade the gage to
   %GRR ≤ 10% or use gage-adequate sampling before charting on it).
5. **Sustainment honesty check (30-day gate — workbook §5.4–5.6).** A program
   reports "30/30 sustainment records at/above target, Cpk 1.48, handoff
   accepted." List the four checks that would catch a narrated (rather than
   executed) sustainment claim, each with the artifact that must exist: (a) the
   30 daily subgroup records with a replay command; (b) reaction records for any
   out-of-control day; (c) the handoff acceptance as a signature, not a claim;
   (d) the final receipt's five fields (identity, authority, consequence,
   replay, standing). Which of the four fails first if the Cpk 1.48 number has
   no replay command?

## Timing (per exercise)

(12 min) each for exercises 1–5; total 60 min. Exercise 2 is the demonstrated
one: its full derivation is `worked-example-measure.md`, its independent court
re-derivation is `court.py` (40/40 checks), and the two agree — see
`keys/solution-key.md` for the executed agreement evidence. No new simulation
seed is introduced by this module's exercises (no new statements in MANIFEST).

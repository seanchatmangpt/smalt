# Module 45 Solution Key — Capstone Verification Against the Worked Example

**Method**: the key's numbers are NOT remembered. Each pinned constant is
re-derived two independent ways — (1) the worked example's inline python3
derivation, executed in this session from the raw CSVs, and (2) the module
court (`court.py`), which independently re-derives every documented value and
asserts agreement. The captured outputs below are the receipts; a mismatch
would be a drift finding. No new simulation seed is introduced (no new
statements in `datasets/MANIFEST.md`).

## 0. Agreement evidence (executed 2026-11-04)

Three independent executions, all exit 0:

```
python3 modules/45-capstone-brief/court.py          # RC=0
python3 modules/45-capstone-brief/court.py --mutate # RC=1 (mutation rejected — non-vacuous)
python3 modules/11-msa/keys/gage_rr_key.py          # RC=0
```

Court tail (40/40):

```
Module 45 court: ALL 40 CHECKS PASS (%GRR 13.97 / ndc 9 re-derived; mu 12.0090 /
sigma 7.407 um / Cpk 0.72 re-derived; mutation rejected; stale 4.17 um sweep clean)
```

`--mutate` output (the gate flips — the check is not tautological):

```
MUTATION DETECTED: pctGRR pinned 14.97 vs re-derived 13.97 -> the
documented-value comparison rejects it; court exits nonzero
```

### Cross-check 1 — MSA: module-11 key vs court vs worked example

Executed `python3 modules/11-msa/keys/gage_rr_key.py` (RC=0):

```
GAGE-RR KEY (re-derived from data/gage-rr-bore.csv, seed 411)
  grand_mean_mm = 11.9993
  MS_part = 0.0023436
  MS_appr = 2.94e-05
  MS_int = 3.3e-06
  MS_e = 4.3e-06
  F_part = 717.64
  F_appr = 9.01
  EV_um = 10.684
  AV_um = 4.81
  GRR_um = 11.717
  PV_um = 83.047
  TV_um = 83.87
  pctEV = 12.74
  pctAV = 5.73
  pctGRR = 13.97
  pctPV = 99.02
  ndc = 9
  sigma_repeat_mm = 0.00207
  sigma_reprod_mm = 0.00093
  sigma_grr_mm = 0.00228
  sigma_part_mm = 0.01613
  sigma_total_mm = 0.01629
  verdict = %GRR in 10-30%%: acceptable for process analysis,
             not acceptable for SPC on a 50 um tolerance; ndc >= 5.
RC=0
```

**Agreement asserted**: pctGRR 13.97 (not 14.97, not the >30% band), ndc 9,
pctAV 5.73, and the sigma set (0.00207 / 0.00093 / 0.00228) match the court's
re-derivation and the worked example's §1 receipt field-for-field — three
independent executions (module-11 key, court, worked example) agree on every
documented value.

### Cross-check 2 — baseline capability: inline python3 (worked-example heredoc) vs court

Executed inline python3 (the worked example §2 heredoc, verbatim completed):

```
subgroups=25 n/subgroup=4  grand_mean=12.0090 mm  Rbar=0.01525 mm
sigma_within = Rbar/d2 = 0.01525/2.059 = 0.007407 mm = 7.407 um
Cp = 0.050/(6*0.007407) = 1.12
Cpk = min(12.025-12.0090, 12.0090-11.975)/(3*0.007407) = 0.7199
Cpk exact-pins check: (12.025-12.009)/(3*0.007407) = 0.7200
Cpk rounded = 0.72  target 1.33 -> NO — gate fails
stability: UCL_xbar=12.0201 LCL_xbar=11.9979 (A2=0.729, n=4)
out-of-control subgroups (Xbar/R limits): none -> baseline stable, capability admissible
```

**Agreement asserted**: μ 12.0090 / R̄ 0.01525 / σ_within 7.407 µm / Cp 1.12 /
Cpk 0.7199 — byte-identical to the worked example's captured receipt and to the
court's PASS lines (`sigma_within 0.007407 mm == 7.407 um (adjudicated spine)`,
`Cpk 0.7199 == documented 0.7199`). The stale counterfactual is refused by the
court itself: σ 4.17 µm would give Cpk 1.28, not 0.72.

**Verdict**: Cpk 0.72 < 1.33 → lawful NO (gate passes on evidence discipline;
program continues to Develop with baseline certified).

## 1–5 answers

1. **Charter carry (Define).** The killer number is the baseline capability
   pair. A charter pinning σ = 4.17 µm computes Cpk ≈ 1.28 and reports a gap
   that does not exist; Phase 2's raw re-derivation lands on the adjudicated
   pair (σ 7.407 µm, μ 12.009 mm, Cpk 0.7199) and the charter then contradicts
   its own Measure phase. Every charter number must match RUNNING-CASE.md or
   carry a §2.1 discrepancy note.
2. **Measure gate (the demonstrated one).** From `data/gage-rr-bore.csv`:
   %GRR = 13.97%, 10–30% band → conditionally acceptable (adequate for process
   analysis, NOT for SPC on the 50 µm tolerance), ndc 9 ≥ 5. From
   `data/cpk072-bore-subgroups.csv`: μ = 12.0090 mm, R̄ = 0.01525 mm,
   σ_within = 7.407 µm, Cp = 1.12, Cpk = 0.7199 ≈ 0.72; X̄ limits
   12.0201/11.9979, zero out-of-control subgroups → stable → admissible.
   Adjudication: the σ 4.17 µm pair computed Cpk ≈ 1.28 and was ruled stale
   2026-11-04; the raw re-derivation independently confirms the adjudicated
   pair. Gate question answered: numbers trustworthy (conditionally — the
   10–30% band), numbers are the numbers (raw-CSV re-derivation). Verdict:
   0.72 < 1.33 → lawful NO; program proceeds to Develop with the baseline
   certified. Both derivations replay: exercise 2's answer IS the §0 agreement
   evidence.
3. **Phase handoffs.** (a) Measure → Explore consumes a STABLE, MSA-cleared
   baseline (§2.2's capability pair + the stability verdict); a baseline from
   an unstable process is inadmissible — hypothesis tests would test noise
   shifts, not the improvement. (b) Explore → Develop consumes the Pugh + AHP
   verdict naming the selected concept with checkable weights; admissibility
   requires CR < 0.10 and re-derivable Pugh totals. (c) Develop → Implement
   consumes the RSM optimum window with confirmation runs; admissibility
   requires predicted-vs-observed within the stated CI.
4. **Control plan.** The row cannot chart the existing gage because the MSA
   verdict is conditional: %GRR 13.97% sits in the 10–30% band — adequate for
   the baseline study, NOT for SPC on a 50 µm tolerance. Two lawful
   resolutions (the worked example's documented action): upgrade the gage to
   %GRR ≤ 10% of tolerance, or use gage-adequate sampling before charting.
   Either way the control-plan row carries the documented action, the reaction
   rule, and the named owner — no CTQ row without a reaction rule (workbook
   §5.3).
5. **Sustainment honesty check.** The four checks and their artifacts:
   (a) 30 daily subgroup records, replay command exits 0; (b) reaction records
   for any OOC day (30/30 with zero reactions is itself suspicious — a real
   line has days); (c) handoff acceptance as signature, not claim; (d) final
   receipt with identity/authority/consequence/replay/standing. (d) fails
   first if Cpk 1.48 has no replay command — a receipt number that does not
   replay is not a receipt number; the whole receipt is SUSPECT until every
   number names its script.

## Receipt

- Files authored: `modules/45-capstone-brief/exercises.md` (5 graded exercises
  mapped to workbook phases), `modules/45-capstone-brief/keys/solution-key.md`
  (this file), `modules/45-capstone-brief/court.py` (--mutate CLI mode added,
  mirroring module 12; default run unchanged, 40/40).
- Gates: court exit 0 (40/40), `--mutate` exit 1 (MUTATION DETECTED),
  `datasets/manifest_verify.py` exit 0 (61 PASS).
- Seed statement: none new — this module adds no simulation (no new MANIFEST
  statements).
- Agreement: worked-example inline derivation == court re-derivation ==
  module-11 key replay on %GRR 13.97 / ndc 9 / μ 12.0090 / σ 7.407 µm /
  Cpk 0.7199, captured outputs above.

# Module 16 — Court Record

Lane 07, module 16-concept-selection-pugh-ahp. Adjudicated spine honored:
baseline sigma 7.407 um (the pre-adjudication 4.17 um pair is stale; the
dataset was REGENERATED this session — see receipt below).

## Commands and exits

```
cd /Users/sac/smalt/docs/dmedi-bb-curriculum/modules/16-concept-selection-pugh-ahp
python3 scripts/gen_trials.py         # exit 0, wrote data/concept_trials.csv
python3 scripts/gen_trials.py && shasum -a 256 data/concept_trials.csv
# -> 8888e52f... (rerun byte-identical)
python3 scripts/derive_selection.py > data/court-run.txt; echo $?       # exit 0
grep -c "^\[PASS\]" data/court-run.txt  # 20
grep FAIL data/court-run.txt         # (no output)
```

Captured court output: `data/court-run.txt` (20 PASS checks, 0 FAIL, exit 0).

## Court checks asserted (all PASS)

1. A pilot Cpk within 0.10 of pinned 0.72 (actual 0.72).
2. A pilot s within 15% of adjudicated 7.407 um (actual 7.51 um).
3. Pugh datum row all 0.
4. Pugh iteration-1 net leader is B (the designed divergence, asserted so
   docs cannot silently claim iteration-1 agreement).
5. Consolidation strictly improves net over D (+3 vs +1).
6. D2 ties B on net (+3 = +3) — tie must be escalated, not voted.
7. D2 beats B on CTQ-1 pilot data (Cpk 1.84 vs 1.55; Ra 0.94 vs 1.33).
8. Criteria matrix CR < 0.10 (0.0246).
9. Criteria weights sum to 1.
10. Inconsistent teaching matrix CR >= 0.10 as designed (0.5840).
11. Inconsistent lambda_max appreciably > n (7.6162 - 5 = 2.616).
12-16. All five concept matrices CR < 0.10 (max 0.0225; C5 exactly 0.0).
17. AHP winner is D (0.2736).
18. Post-consolidation Pugh selection == AHP winner (D lineage).
19. AHP runner-up is the iteration-1 Pugh leader B (0.2575).
20. Iteration-1 winner differs from AHP winner (divergence witnessed).

(Count law: `ALL CHECKS PASSED` contains "PASS" too — count with
`grep -c "^\[PASS\]"`, which is 20, never the bare `grep -c PASS`.)

## Both rankings printed by the court run

- Pugh iteration 1 (unweighted): B > C = D > A (net +3 / +1 / +1 / 0)
- Pugh post-consolidation: D2 ties B at +3; tie escalated to data + AHP.
- AHP (weighted): D (0.2736) > B (0.2575) > C (0.2425) > A (0.2263).
- Final: D2 carried to module 27; B runner-up; C killed; A datum/fallback.

## Data provenance

- Seed 1607 stated in `scripts/gen_trials.py`; CSV byte-reproducible
  (sha256 `8888e52fb8a3fc3a4199275bc9cc60c066c50d10f58fea94ef0660db8cc7c210`
  across two regenerations).
- Prior CSV (built on stale sigma 4.17 um) replaced; generator docstring
  records the adjudication.

## Honesty notes

- The consolidation D2 does NOT dominate B cellwise (B keeps a C5 + while
  D2 shows +); the first draft asserted dominance, the court run exposed
  it, and the check was rewritten to the lawful form: tie + data
  escalation. The refusal of the dominance claim is itself receipted here.
- E4's "repair with one judgment" is deliberately shown to be INSUFFICIENT
  (CR 0.3468 one-judgment, 0.2110 triad) — the solution key refuses the
  premise that spot-edits fix consistency.
- Exercise E6's concept E is synthetic and lives only in the solution key
  computation; the registered CSV is NOT overwritten (students write
  `data/concept_trials_plus_e.csv` themselves).

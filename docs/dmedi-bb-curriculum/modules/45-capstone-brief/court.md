# Court Receipt — Lane 17, module 45-capstone-brief

Standing: ALIVE (authored + court-checked this session, 2026-11-04, repo /Users/sac/smalt)

## Delivered
- `capstone-brief.md` — full capstone project brief: CPPC case, five-phase scope, pinned
  constants with the CLD-01 discrepancy law (§2.1), program falsifiers, deliverable set,
  45/45-module traceability table.
- `capstone-workbook.md` — student fill-in skeleton: per-section required contents + gate
  question + acceptance conditions; zero pre-filled content, zero placeholders.
- `phase-gate-checklist.md` — five gate checklists with gate questions and reject conditions.
- `scoring-rubric.md` — weighted rubric (20/25/30/15/10) with weight justification, band
  tables, floors (Implement ≥ 9, no-zero rule), scoring procedure.
- MANIFEST.md rows appended (capstone section: consumes/owns + CLD-01 note).

## Court commands + actual output

```
$ python3 (weights-sum + traceability court, run in modules/45-capstone-brief/)
weights sum: 100
traceability rows: 45 missing: []
ALL COURTS PASS
```

Rubric band values re-checked against weights dict (each weight literal present in rubric);
workbook phase headers 1–5 asserted present. Exit 0.

## Consequence
- Rubric weights python3-verified to sum to 100.
- Traceability table covers modules 1–45 with no gaps (regex over row-leading module ids).
- Known-open course defect CLD-01 (Cpk 0.72 vs σ 4.17 µm inconsistency) — RESOLVED:
  adjudicated 2026-11-04 (RUNNING-CASE.md), adjudicated pair is σ = 7.407 µm. Brief §2.1 pins
  the adjudicated pair and makes silent inheritance of the stale σ = 4.17 µm a Measure-gate
  reject condition.

## Replay
```
cd /Users/sac/smalt/docs/dmedi-bb-curriculum/modules/45-capstone-brief && python3 - <<'EOF'
import re
weights = {"measure":20,"explore":25,"develop":30,"implement":15,"documentation":10}
assert sum(weights.values()) == 100
brief = open("capstone-brief.md").read()
nums = sorted(set(int(r) for r in re.findall(r"^\| (\d+) \|", brief, re.M)))
assert nums == list(range(1,46))
print("replay OK")
EOF
```

## Honest limits
- Module titles for 06–27 / 31–44 in the traceability table are the course catalog titles as
  reconstructed by this lane from the DMEDI BB sequence; those modules are owned by other
  lanes and not yet all present on disk (landed: 01–05, 08–10, 28–30). A landed module whose
  actual title/numbering diverges supersedes this table — coherence court (Lane 19) owns the
  reconciliation.
- Gate-week mapping of specific tools to module numbers follows the same reconstruction and
  is subject to the same Lane 19 adjudication.

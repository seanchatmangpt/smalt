# i29 docs spot-audit 3 — azsim-burn + checkpoint5 conventions

- Date: 2026-10-19
- Subject: /Users/sac/smalt (working tree; read-only audit)
- Context: solo(spot-audit; 4 files + gate run; no source mutations)
- Standing: PASS (0 mechanical fixes required; 1 structural finding reported)

## Scope

- `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md`
- `docs/jira/v26.10.18/azsim-burn/AZB24-BUMP-PLAN.md`
- `docs/jira/v26.10.18/azsim-burn/G1-QUEUE-STORAGE-SCOPING.md`
- `docs/jira/v26.10.18/receipts/i29-checkpoint5.md`

## Checks (real output)

Language-tagged fences — every opening fence tagged, none bare:

```
$ grep -n '^```' azsim-burn/AZB24-BUMP-PLAN.md
22:```diff
27:```
31:```diff
36:```
40:```bash
42:```
55:```markdown
79:```
96:```bash
108:```
```

(AZB23/G1/checkpoint5 contain zero fenced blocks; verified by grep — no `^```` hits.)

Trailing whitespace — zero hits across all 4 files:

```
$ grep -n ' $' <4 files>   →  (no output)
```

## Structural findings (reported, not fixed)

- **Line length >100 outside tables** (rule: ≤100 prose chars). AZB23-PREFLIGHT:
  lines 7 (101), 77 (102), 78 (137). AZB24-BUMP-PLAN: line 62 (102).
  G1-QUEUE-STORAGE-SCOPING: lines 5, 8, 13, 15, 19, 23-26, 32 (138-381 chars,
  dense single-paragraph technical prose). i29-checkpoint5: lines 3, 6, 97
  (101-156); table lines 80-83 are exempt. All table-row overages are exempt
  by rule. No content altered — wrapping prose lines in receipts re-wraps
  embedded evidence context; left to owner discretion.
- H1/filename correspondence, H2 structure, and See Also absence (these are
  milestone work docs, not rules-directory files): all conform to the
  exemplar pattern.

## docs-dod-check

```
$ just docs-dod-check  …  OK README.md
EXIT=0
```

Full run: 66 paths checked, 0 MISS, exit 0 (2026-10-19, HEAD-adjacent tree).
None of the 4 audited files is individually pinned in the gate's check list;
the gate constrains user-facing docs' receipt citations, and its scope is
green with these files on disk.

## Verdict

PASS — no in-place mechanical fixes required (0 untagged fences, 0 trailing
whitespace); structural line-length overages reported above.

# BK-34 — KD Register Structure Repair

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-21
**Lane**: register-structure repair (from BK-30 census, `receipts/bk30-kd-coherence-census.md`)
**Owns**: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (structure only — no status flips), `docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` (pointer doc). Not FINAL-RELEASE.

## What was done

1. **Cell-escape repairs (3 rows)** — escaped unescaped `|` inside cell content:
   - **KD-16** (line 32): `` `POST /keys/{name}/{version}/encrypt|decrypt` `` → `` `...\|decrypt` ``
   - **KD-56** (line 239): `` `POST /subscriptions/{sub}/providers/{ns}/register|unregister` `` → `` `...\|unregister` ``
   - **KD-85** (line 269): `with |skew| sane` → `with \|skew\| sane`
2. **Pointer doc range statement** (`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`): updated from stale "rows KD-01..KD-157 / Mint from KD-143" to the measured values — **rows KD-01..KD-160, 157 rows (ids non-contiguous)**, next mint **KD-161**.

## Before / after census (escape-aware pipe count, `(?<!\\)\|` → 7 pipes = 6 cells)

Before: 157 rows, **3 malformed** (KD-16: 7 cells, KD-56: 7 cells, KD-85: 8 cells) — exactly the 3 regressions BK-30 named.
After: 157 rows, **0 malformed**.

Note: a plain `awk -F'|'` over-counts rows using escaped `\|` (flags e.g. KD-23 at 14 cells). The escape-aware count is the correct census method; KD-23's escapes (BK-11 repair) are proper.

## kd_flip.py parse proof

`python3 scripts/kd_flip.py` (read-only) after the edit, exit 0:

```
KD-85: [CLOSED-SIMULATED] lib/smalt/messaging/amqp/delivery_encoder.ex
```

- zero `[skew]` lines in full output (grep -i skew: no matches)
- FLIP-ELIGIBLE: 3 (KD-10/75/86 — owning lanes' flips, untouched here)

## Diff summary

`git diff` vs HEAD shows 4 changed KD rows in the register — 3 are this lane (KD-16/56/85, char-located: only `\` inserted before pipes). The **KD-79 row change is a pre-existing in-flight BK-29 working-tree edit** (closure note appended to its status cell), present before this lane started; not attributable here.

Pointer doc: 1 line block rewritten (range + mint pointer). No other edits. No commits made.

## Carried (not this lane)

- **FINAL-RELEASE.md drift**: BK-30's stale open-row finding against FINAL-RELEASE remains carried by the wrap lane; untouched here.
- Status flips for KD-10/75/86/92 etc. remain with owning BK lanes; `kd_flip.py` currently reports KD-10/75/86 FLIP-ELIGIBLE (witness postdates shim) — flips not applied by this lane.

# Receipt — R3 (KD census prose single-sourced)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** ALIVE
- **Date:** 2026-10-15 (counts re-witnessed by W1 wave-2 docs lane)

## Subject files

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical KD register)
- `docs/jira/v26.10.16/KNOWN_DIVERGENCES.md` (pointer stub for the active window)

## Defect

The KD census prose restated open/closed counts as hand-written literals, which
could drift from the register table (the declared ground truth).

## Fix

Prose now single-sources the counts from the table; the v26.10.16 window
carries only a pointer stub naming the canonical register and the next id
(KD-76), so no second literal count exists to drift.

## Verification (re-run 2026-10-16 by DoD repair lane, unedited output)

```
$ grep -cE '^\| KD-[0-9]+.*\| OPEN \|$' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
62
exit 0
$ grep -cE '^\| KD-[0-9]+.*(CLOSED)' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
13
exit 0
$ grep -cE '^\| KD-[0-9]+' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
75
exit 0
```

OPEN (62) + closed (13) = total (75) = KD-01..KD-75, matching the register's
declared span. (Counts moved from 64/11 on 2026-10-15: two rows flipped
OPEN->CLOSED since the last witness; the total is unchanged and the sum still
reconciles.) The prose carries no competing count. Table is ground truth.

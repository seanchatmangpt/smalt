# BK-STAND6 — Final standing-line sweep (v26.10.22)

- **Standing**: PARTIAL_ALIVE (NO-STANDING residue 0; 396-row typed STALE residue remains, owned by witness-all rerunnable-command coverage, not this lane)
- **Context**: solo
- **Date**: 2026-10-22
- **Subject**: /Users/sac/smalt (tree read-only except the two receipt edits + this receipt)

## What ran (embedded)

Census via the canonical contract (`scripts/receipt_index.py` STANDING_LINE_RE +
STANDING_TOKENS), not ad hoc grep — NO-STANDING set before:

```
$ python3 - <<census over docs/jira/v26.10.22/receipts/*.md via receipt_index>
2
bkgwsp-poll.md
bkqmon-window.md
```

Exactly the 2 residual rows named by BK-WIT4F. New-receipt sweep (mtime ≤ 2h,
same contract):

```
new-in-2h-missing-standing: NONE
```

No receipt landed in the last 2h lacks a canonical standing line.

## Treatment

Both residuals are poll/census lanes; standing derived only from their embedded
output (poll-lane rule: PARTIAL_ALIVE with the census typed):

- `bkgwsp-poll.md` → `**Standing**: PARTIAL_ALIVE (census receipt — embedded
  output complete and typed: freeze age 62 min, 0 build-root writes in 25 min,
  2 orphaned --hang stub beams, 0 gwsskep receipts; lane verdict FROZEN is a
  lifecycle disposition...; superseded by GWSSKEP2 relaunch)`. FROZEN and SUSPECT
  are not in STANDING_TOKENS — that was the only defect.
- `bkqmon-window.md` → `**Standing**: PARTIAL_ALIVE (census receipt — embedded
  output complete and typed: 1-min load 85–99 / 16 cores, 0.17% idle, 3 orphan
  duckdb recursions ~750% CPU, 4/5 BQUIET remeasures, b4 stalled; verdict
  BENCH-WINDOW-BLOCKED is a window disposition...)`.

No receipt's meaning was changed; each gained a token-bearing standing line
whose value cites only its own embedded counts.

## Post-fix dry-run

```
$ python3 scripts/witness_all.py --dry-run
[WITNESS-SUMMARY] total=600 witnessed-green=0 stale-typed=396 failed=0 (DRY-RUN)
```

NO-STANDING (failed) set: **0** (was 2). Typed residue = 396 STALE rows —
receipts with standing but no rerunnable command in a safe class (audit/census
lanes); standing-contract work is done, rerunnable-command coverage is a
separate lane.

## Falsifier

A new receipt landing without a standing token, or any v26.10.22 receipt
re-reading NO-STANDING in `witness_all.py --dry-run`, inverts this receipt.

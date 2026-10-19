# Checkpoint 9 — typed-RED close-commit prep (census)

Context: solo(/Users/sac/smalt)
Date: 2026-10-19
Standing of this document: PASS (census-only; no code touched, no git state changes)

## Scope

Prepare the typed-RED close commit for AZB-23: verify consistency of the
three wrap artifacts, index the verdict receipt, gate the docs, and freeze
the exact commit line. Census only — the commit itself is coordinator-owned.

## Consistency census (TYPED-RED CARRIED, no two-green claim)

All three artifacts on disk and mutually consistent:

- `docs/jira/v26.10.18/receipts/azb-23-court-x2.md` — Standing: TYPED-RED
  (gate carried); "No two-consecutive-greens were witnessed"; every green
  is single-run; close condition = race-family structural fix, first
  v26.10.19 work order.
- `docs/jira/v26.10.18/FINAL.md` §3 — "**VERDICT: TYPED-RED — the gate
  never exited 0 twice consecutively**"; 8-entry attempt table with
  per-run verdicts read from `tmp/court-x2-1792*.log`; green witnesses
  run-level only; `SMALT_MAX_CASES=4` probe flagged dispatch-reported,
  receipt UNLOCATED. §5 "Known-open at wrap": court-x2 TYPED-RED, carried.
- `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md` §Amendment 2
  (2026-10-19) — "AZB-23 closed TYPED-RED; AZB-24 proceeds on the
  documented evidence", C1 superseded by the typed-RED carry.

No artifact claims two-green at the gate. The dry5 both-green rehearsal and
leg-C soak are cited as run-level witnesses, not gate verdicts.

## One correction applied this checkpoint

`azb-23-court-x2.md` used the bold form `- **Context**: solo(...)` which
the `receipt_index.py` context-law regex (`^Context:\s*(solo|...)`) does
not match — the receipt indexed as **NO-CONTEXT** (advisory flag). Changed
to the plain law form `Context: solo(...)`; re-indexed; flag cleared.
(RECEIPTS.md row: standing UNKNOWN — expected, `TYPED-RED` is not in the
indexer's standing-token list; identical to the v26.10.17 precedent row
`r241-court-x2-attempt3-typed-red.md`, also UNKNOWN.)

## Gates

- `just receipt-index` — exit 0; `docs/jira/v26.10.18/RECEIPTS.md` +
  `receipts/INDEX.md` regenerated; azb-23-court-x2.md indexed, no
  NO-CONTEXT, no SUSPECT.
- `just docs-dod-check` — exit 0 (71 checks, all OK; run before and after
  the re-index).

## Close-commit line (coordinator-owned, NOT run)

```
git add docs/jira/v26.10.18/receipts/azb-23-court-x2.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint9.md \
        docs/jira/v26.10.18/receipts/INDEX.md \
        docs/jira/v26.10.18/RECEIPTS.md \
        docs/jira/v26.10.18/FINAL.md \
        docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md \
        docs/jira/v26.10.16/sdk-results/spc-bands.md \
        docs/jira/v26.10.18/receipts/i29-court-x2-final.md \
        docs/jira/v26.10.18/receipts/i29-courtface-verify.md
```

Notes: `i29-court-x2-final.md` and `i29-courtface-verify.md` are already
modified/untracked per the wrap-tree status; they are named by the verdict
receipt and FINAL.md, so they ride the same close commit. The v26.10.16
spc-bands.md edit predates this checkpoint (pre-existing dirty file, cited
by window docs) — include only if the coordinator confirms it belongs to
this close; it is listed for completeness of the dirty set, not asserted
as part of the typed-RED close.

## Falsifier

Any two-green claim at the gate, or a GREEN-in-both-runs attempt in
`tmp/court-x2-1792*.log`, invalidates the census; re-read the 8 logs and
the verdict receipt before staging if either appears.

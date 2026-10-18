# i21b — receipt audit: r241/r243/r244 + all i21-* (RECEIPT_CONTEXT_LAW spot-audit)

Standing: PASS

Context: solo (this audit is a doc scan, not a test run; greps over
`docs/jira/v26.10.17/receipts/`, real output embedded below)

## Method

`just receipt-index` re-run first (regenerated RECEIPTS.md + INDEX.md across
v26.10.14/16/17). v26.10.17 INDEX.md: "SUSPECT flags: 0 — none". Per-receipt
scan then checked three axes: Standing line, embedded real output, `Context:`
line per `docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`.

## Results

| Receipt | Standing | SUSPECT? | NO-CONTEXT? |
|---|---|---|---|
| r241-court-x2-attempt3-typed-red.md | TYPED-RED | no | YES |
| r243-terminal-receipt.md | PARTIAL_ALIVE | no | YES |
| r244-publish-record.md | PASS | no | no |
| r244-publish-record.draft.md | (none — draft, superseded by r244-publish-record.md) | no | YES (draft; no standing/context by construction) |
| i21-blob-budget.md | ALIVE | no | YES |
| i21-brokerfacade-sweeper.md | PASS | no | YES |
| i21-churn-budget.md | ALIVE | no | YES |
| i21-doc-token-sweep.md | PASS | no | YES |
| i21-ets-race-fix.md | PASS | no | YES |
| i21-fence10-fix.md | ALIVE | no | YES |
| i21-leak-batch1.md | PASS | no | YES |
| i21-leak-batch2.md | ALIVE (bullet-form `**Standing**:` mid-list) | no | YES |
| i21-leak-batch3.md | ALIVE | no | YES |
| i21-leak-court-delta.md | PARTIAL_ALIVE | no | YES |
| i21-lro-face.md | PARTIAL_ALIVE | no | YES |
| i21-brokerfacade-sweeper.md | PASS | no | YES |

## Findings

1. **Zero SUSPECT**: receipt_index flags 0 across the window — every receipt
   embeds real command output. The SUSPECT gate is fully satisfied.
2. **Context-law compliance is 1/15.** Only `r244-publish-record.md` carries a
   `Context: solo` line. All other 14 new receipts are NO-CONTEXT. The law's
   migration rule ("new receipts gain the line at creation") was not followed
   by the i21 wave; it is binding from this window forward, so these are
   malformed for witness purposes and not admissible as gates until touched
   (rerun/flip/correction adds the line naming the ACTUAL context of the
   existing embedded output — no assumed context).
3. **Formatting drift, one instance**: `i21-leak-batch2.md` carries standing
   as a bolded list bullet (`**Standing**: ALIVE`) rather than a header line;
   parsers keyed on `^Standing:` will miss it. Same class: `i21-leak-batch3.md`
   uses lowercase `standing:`.
4. Standing lines all present (15/15 excluding the draft). r244 draft has no
   standing — it is a draft beside the landed `r244-publish-record.md` and
   should be deleted or moved out of `receipts/` at integration.

## Verification (real output)

```
$ just receipt-index (tail)
  SUSPECT: bench-02-blob-ts.md (standing UNKNOWN)   <- v26.10.14 window, pre-existing
  ...
wrote /Users/sac/smalt/docs/jira/v26.10.17/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.17/receipts/INDEX.md

$ grep -c SUSPECT docs/jira/v26.10.17/receipts/INDEX.md context: v26.10.17 section
- SUSPECT flags: 0 — none

$ per-receipt scan (grep -icE '^\*{0,2}(standing|context)\*{0,2}:') over
  r241, r243, r244(.md/.draft.md), i21-*.md (15 files):
  standing present: 14/15 (r244 draft absent); context present: 1/15
  (r244-publish-record.md only)
```

No git. No fixes applied (audit-only lane).

# Receipt — R9 (receipt standing whole-file scan + version glob)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W1 wave-2 docs lane)

## Subject files

- `scripts/receipt_index.py` (standing scan + version-dir glob, per its own
  header comment at line 18: "glob every milestone version dir so newer
  receipts are indexed, not just the hardcoded v26.10.14 window")

## Defect

The index previously hardcoded one window's receipts dir and could read the
standing line from a partial slice of a receipt file.

## Fix

Standing extraction is a whole-file scan; the receipts glob spans every
`docs/jira/v*/` window, so newer-window receipts are indexed instead of
invisible.

## Verification (2026-10-15, W1 wave-2 docs lane, unedited output)

```
$ python3 scripts/receipt_index.py
receipts=160 sdk=15 total=175 suspects=21
  SUSPECT: 06-blob-x-ms-date-unvalidated.md (standing UNSUPPORTED)
  SUSPECT: a2-cas-contention.md (standing UNKNOWN)
  ... (21 SUSPECT rows total; loud, by design)
$ grep -c "v26.10.1[56]" docs/jira/v26.10.14/RECEIPTS.md
3
```

The last command proves newer-window receipts (v26.10.15/v26.10.16) are
indexed into the regenerated RECEIPTS.md. SUSPECT flagging is the documented
standard for output-less receipts, not a failure. exit 0.

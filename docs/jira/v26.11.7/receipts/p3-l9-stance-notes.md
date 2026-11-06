# P3-L9: emulation-stance evidence-note additions

Standing: PASS

## What was added and why

Two evidence-note bullets appended to
`docs/explanation/emulation-stance.md` under a new
`## Evidence notes (post-dating the stance text)` section (the 80/20
stance prose itself was NOT rewritten):

1. **Arcus co-pin**: the Azure dialect face is now co-pinned in arcus
   (`internal/dialect/azure/`, ~70 files) per KD-212 and the
   v26.11.6 arcus register — the stance now governs both checkouts,
   with the KD register remaining the honesty mechanism on both
   sides. Added because the stance text predates the co-pin and a
   reader of smalt alone would miss the second substrate.
2. **kv7 core-residency**: kv7 is core-resident per the v26.10.31
   decision and is never deleted with an ARM strip. Added because the
   doc discusses dialects as if all live in posh; this bullet pins
   the exception so an ARM-strip cleanup cannot misread the doc.

## Gate evidence

Original-prose-untouched gate: `diff /tmp/p3l9-orig.md <edited>` shows
a single append hunk `64a65,74` — 10 added lines, zero changed or
removed lines. Line-length check (`awk length>100`) over the edited
file: no output (all lines ≤100 chars). Original snapshot taken before
the edit via `cp` to /tmp.

## Scope

No git operations. Owned files only:
`docs/explanation/emulation-stance.md` (append-only),
`docs/jira/v26.11.7/receipts/p3-l9-stance-notes.md` (this receipt).

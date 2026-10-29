# BK-84 — SPOF-B record-coherence correction (SPOF-3.1 wedge premise)

**Standing:** **ALIVE** (correction landed; supersession verified on disk)
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main, dirty shared checkout)
Authority: `docs/jira/v26.10.22/receipts/spof3-affidavit-fixes.md` (SPOF-3
Falsifier section — pre-fix probe refutes the wedge on the pinned artifact).

## Correction

`docs/jira/v26.10.22/receipts/spofb-boundary-audit.md` — dated addendum
appended ("ADDENDUM 2026-10-21 — SPOF-3.1 premise corrected"); original
audit text preserved unchanged. Content:

- **SPOF-3.1 reclassified**: the 256MiB input-alloc leak wedge premise is
  REFUTED on the pinned affidavit artifact (80×16MiB = 1.31 GiB driven
  pre-fix, 80/80 non-empty responses, 1KiB admits, seals deterministic).
  The 255–256MiB budget figure was GWS-11's graphlaw `gl_alloc` measurement,
  not the affidavit `af_alloc`. Wedge classification and wedge-point
  projections withdrawn.
- **Stands as code-truth**: the missing-free observation (input ptr +
  `delta_ptr` leak) — fixes landed as defense-in-depth, court-pinned
  (`test/internal/spof3_affidavit_engine_court_test.exs`).
- **SPOF-3.2 stands**: busy/down typing real; `:engine_busy` fix landed.

## Sweep

`grep -rn "256" docs/jira/v26.10.22/ --include="*.md"` (Mib/wedge/leak/alloc
filter): wedge claim appears ONLY in `spofb-boundary-audit.md` (original,
now superseded by its addendum) and in `spof3-affidavit-fixes.md` (already
carries the correction). No other receipt/doc repeats the wedge claim —
zero further edits required.

## Verification

- Addendum re-read on disk post-edit, confirmed appended with authority
  citation to the SPOF-3 receipt; original text byte-preserved.
- `just docs-dod-check` (run below): exit 0.

```
$ just docs-dod-check
OK    docs/jira/v26.10.14/receipts/ws-12-e2e.md
OK    docs/jira/v26.10.14/receipts/cli-08-gates.md
OK    docs/jira/v26.10.14/receipts/08-servicebus-census.md
... (63 checks, every path OK — no MISS lines)
OK    README.md
EXIT=0
```

# BK-88 — SPOF-3 receipt standing flip PARTIAL_ALIVE → ALIVE

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main, dirty shared checkout)
Authority: `docs/jira/v26.10.22/receipts/bk84-spofb-correction.md` (BK-84
record correction, itself ALIVE) backed by the SPOF-3 falsifier court
(`test/internal/spof3_affidavit_engine_court_test.exs`, 6 passed).

## Change

`docs/jira/v26.10.22/receipts/spof3-affidavit-fixes.md` — standing line
flipped PARTIAL_ALIVE → ALIVE, plus a one-line closing note citing the
BK-84 addendum in `spofb-boundary-audit.md` (ADDENDUM 2026-10-21 —
SPOF-3.1 premise corrected; wedge classification withdrawn, SPOF-3.2
stands) as the closing authority. No other content touched.

## Basis

The PARTIAL was pending BK-84's record correction. Re-read on disk
confirms: (1) both SPOF-3.1/3.2 fixes landed and verified post-fix on the
real wasm artifact (court `Result: 6 passed`, exit 0); (2) the BK-84
addendum is appended to `spofb-boundary-audit.md` with the original text
byte-preserved; (3) BK-84's sweep found no other doc repeating the wedge
claim. Nothing remains open on SPOF-3.1/3.2.

## Verification

- BK-84 receipt re-read on disk: Standing ALIVE, correction landed.
- `just witness-all-dry`: exit 0, no flag. The gate's walk is hardcoded
  to `docs/jira/v26.10.21/receipts/`, so v26.10.22 receipts (including
  this flip's subject) are out of its scope — same before and after.
- Direct classifier invocation (same module, v26.10.22 path): standing
  reads `ALIVE`; disposition "no command in a safe class" (receipt uses
  `asdf exec mix`, not bare `mix`) — identical before and after the edit,
  i.e. pre-existing, not introduced by this change.

```
$ just witness-all-dry   # filtered
[WITNESS-SUMMARY] total=205 witnessed-green=0 stale-typed=127 failed=2 (DRY-RUN)
EXIT=0
```

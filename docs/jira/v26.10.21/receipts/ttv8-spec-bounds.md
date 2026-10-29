# TTV-8: Specification bounds cleanup (release charter + WASM §1 note)

**Standing:** **ALIVE** · Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt

## Diff summary

1. **`docs/jira/v26.10.21/DIRECTIVES.md`** — appended
   "Release & upgrade charter (TTV-8, operator directive, 2026-10-21)":
   hot-code upgrade typed **Explicitly Unsupported**, crash-only
   stop→rebuild→restart named as the preferred path (evidence:
   `receipts/ja14-release-handling.md` — zero `.appup`/`.relup`/
   `code_change` ×34; `receipts/ja12-hot-reload-court.md` — mechanism
   proven, not committed as a supported path). ML-KEM preference
   durability noted with `receipts/imp14-mlkem-flip.md`
   (PARTIAL_ALIVE). Cold-boot budget line NOT included: TTV-6 is still
   QUEUED in the TTV ledger, no DIRECTIVES section landed to append
   after. No existing text edited (append-only; TTV ledger table
   untouched).
2. **`docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md` §1** — added one
   5-line note under the topology diagram: the 64 MiB ceiling is an
   enforced HOST-layer boundary (`wasmtime --max-memory` in the smalt
   worker), not a WASM-module-internal limit; the raw WASI imported
   memory declares no maximum. Cross-refs §3b / GWS-11; no duplication
   of the §3b amendment text.

FINAL-RELEASE / VALIDATION not touched (cited here per dispatch).

## Verification

```
$ just docs-dod-check
...60 rows, all OK...
exit=0
```

All receipt paths named above exist on disk (checked before writing:
ja14-release-handling.md, ja12-hot-reload-court.md,
imp14-mlkem-flip.md). Not committed, per dispatch.

## Gate re-embed (BK-60, 2026-10-21)

Context: solo

SUSPECT was a format artifact: the original verification block wrote `exit=0`,
which the index evidence regex (`\bexit (code|status)?\s*[:=]?\s*\d`) does not
match (it needs a space after "exit"). Fresh full-gate run, 2026-10-21:

```
$ just docs-dod-check
OK    docs/jira/v26.10.16/FINAL.md
OK    docs/jira/v26.10.16/RECEIPTS.md
OK    docs/jira/v26.10.16/WRAP_LEDGER.md
OK    docs/jira/v26.10.16/PUBLISH_RECORD.md
OK    docs/jira/v26.10.16/KNOWN_DIVERGENCES.md
OK    docs/RELEASE_NOTES_v26.10.16.md
OK    docs/jira/v26.10.18/FINAL.md
OK    docs/jira/v26.10.18/RECEIPTS.md
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    docs/jira/v26.10.17/RECEIPTS.md
OK    README.md
docs-dod-check exit 0
```

(`tail -4` shown; 63 OK rows, 0 MISS — full output `/tmp/bk60_dod.out`.)
Standing ALIVE unchanged.

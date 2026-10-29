# BK-115b — private-trip regression fix: sync-e2e-court.mjs absolute paths

**Standing**: ALIVE — both gates green on the exact subject
(`/Users/sac/smalt/workspace/scripts/sync-e2e-court.mjs`, working tree, branch main, uncommitted).
**Context**: solo

## Defect

BK-114 re-witnessed: `workspace/scripts/sync-e2e-court.mjs` (committed at adec7cd)
carries 5 absolute `/Users/sac/smalt/...` literals (lines 10, 12, 108, 109, 234),
failing the `just private-trip` private-path gate. Fixed per BK-54 Class A pattern:
`import.meta.url`-derived ROOT.

## Diff (1 file, +8/−6)

- `workspace/scripts/sync-e2e-court.mjs`:
  - adds `node:path` / `node:url` imports;
  - `const ROOT = path.resolve(fileURLToPath(import.meta.url), "../../..")`;
  - `installIdbShim` now via top-level `await import(new URL("../../tmp/witness/bk83/idb-shim.mjs", import.meta.url).href)` (static `from <expression>` is invalid ESM);
  - lines 108/109 jpath/rpath → `path.join(ROOT, ...)` (rpath reused for the leg-6b receipt import, replacing the 5th literal).

## Verification outputs

```
$ grep -n "/Users/sac" workspace/scripts/sync-e2e-court.mjs   → exit 1 (zero matches)
$ just private-trip
PRIVATE-TRIP PASS: clean (920 source files scanned)
exit 0
```

```
$ node workspace/scripts/sync-e2e-court.mjs
BOOT_OK :: BK83_BOOT_OK enforce sync=:18543 sts=:18581
[PASS] auth.tokenless-401-challenge
[PASS] auth.sts-mint
[PASS] auth.tokenless-flushSync-refused
[PASS] sync.flush-5-200-verified (bytes=320 verified=true)
[PASS] sync.cursor-advanced
[PASS] sync.corruption-typed-refusal
[PASS] sync.snapback-purge-to-head
[PASS] sync.clean-resync (bytes=320 p12-verified=true, KD-165 fix)
[PASS] sync.cumulative-receipt-vs-full-ledger (verified=true root=32aaab1dd19ad798)
SUMMARY: 9/9 PASS, 0 FAIL
exit 0
```

## Same-class straggler sweep

`grep -rn "/Users/sac" workspace/scripts/` → zero matches (exit 1) after the fix;
no other absolute-path stragglers exist under the gate's surface. Gate rechecked
post-sweep: `just private-trip` exit 0.

Not committed, per dispatch.

# BK-102 — BK-92-F1 sync e2e harness fix (idb-shim Tx lifecycle + court determinism)

**Standing:** **ALIVE** (sync-e2e-court 5/5 consecutive exit 0, 9/9 legs each; ws-lint + ws-build green)
Context: solo

Subjects:

- `workspace/scripts/sync-e2e-court.mjs` (BK-83's harness)
- `tmp/witness/bk83/idb-shim.mjs` (BK-83's in-memory IndexedDB shim)

## 1. Root cause (typed)

**Shim Tx completion raced multi-op transactions.** The old Tx completed the
first time its `pending` counter hit 0. journal-sync's transactions issue a
request, `await` its result, THEN schedule the next op on the same tx (e.g.
`_appendLocal`: `openCursor` → `await req(...)` → `put` → `await txDone(tx)`).
Between the two ops `pending` is transiently 0, so `maybeComplete` latched
`completed = true` and fired `oncomplete` early; the second op's completion
could never re-fire it, and `await txDone(tx)` never settled — the exit-13
"unsettled top-level await" hang at leg 5 (4/6 BK-92 runs). The
`onupgradeneeded` crash class (2/6) was the same accounting defect observed at
open time.

## 2. Fix

`tmp/witness/bk83/idb-shim.mjs` — deterministic completion accounting:

- `Tx.pending` = scheduled-minus-settled op count; `schedule()` on every store
  op, `settle()` on request success.
- Completion fires exactly once, from a MACROTASK (`setTimeout 0`) check armed
  when `pending` last hits 0. Every microtask continuation (the awaited-request
  resumptions that schedule the tx's remaining ops) drains before the check
  runs, so a tx never completes while a chained op is unscheduled.
- Error propagation: a failed request sets `tx.error`, fires `onabort`/`onerror`
  (`txDone` rejects) instead of `oncomplete`; `objectStore` on a finished tx
  refuses typed. `open()` upgrade-handler throw is caught → `onerror`.

Plus two harness determinism fixes in the court (both witnessed as real
failures during this fix's own 5× qualification, pre-guard):

1. **Stale-runtime port guard**: run 2 of the first 5× attempt failed leg 4
   because the previous run's beam still held :18543 — the court talked to a
   stale server with leftover per-client journal state (server head ≠ 0 →
   leg-4 refusal). The court now waits for :18543/:18581 to be FREE before
   booting (30s budget, typed exit 1 `port still occupied`), and awaits the
   runtime's exit (SIGKILL fallback 10s) after SIGTERM so the next run never
   boots into a live beam.
2. **STS readiness poll**: run 1 of the second 5× attempt crashed at leg 2
   (undici `UND_ERR_SOCKET` "other side closed" at :18581 — boot marker
   printed before the STS listener accepted application traffic). `stsMint`
   is now a bounded 60s poll on the real observable (an actual token mint);
   network errors / non-200 retry after 500ms. No fixed sleeps; a single
   bounded poll, deadline-checked.

## 3. Qualification record (5× consecutive, 2026-10-10.21)

| Run | Exit | Summary |
|---|---|---|
| 1 | 0 | 9/9 PASS |
| 2 | 0 | 9/9 PASS |
| 3 | 0 | 9/9 PASS |
| 4 | 0 | 9/9 PASS |
| 5 | 0 | 9/9 PASS |

Command (repo root): `node workspace/scripts/sync-e2e-court.mjs`
Per-run logs: `/tmp/bk102-run1.log` .. `/tmp/bk102-run5.log`

Representative run (run 1):

```
[PASS] auth.tokenless-401-challenge :: status=401 www-authenticate=Bearer ... MissingBearerToken
[PASS] auth.sts-mint :: expires_in=3600 jws-segments=3
[PASS] auth.tokenless-flushSync-refused :: ok=false code=SYNC_HTTP status=401
[PASS] sync.flush-5-200-verified :: ok=true lastSeq=5 verified=true bytes=320 leaves=5 markedTo=5
[PASS] sync.cursor-advanced :: cursor=5
[PASS] sync.corruption-typed-refusal :: code=SYNC_REFUSED_BY_SERVER detail=BAD_CRC32 serverHeadSeq=5 purged=2
[PASS] sync.snapback-purge-to-head :: cursor=5 unsynced=0 currentSeq=5
[PASS] sync.clean-resync :: ok=true lastSeq=6 bytes=320 p12-verified=false (false = P12 divergence, KD-candidate)
[PASS] sync.cumulative-receipt-vs-full-ledger :: verified=true leafCount=6 localFrames=6 root=0e3a2bd7e6ff6558
SUMMARY: 9/9 PASS, 0 FAIL
```

Pre-fix record: 0/6 (BK-92 audit). Post-fix: 5/5 exit 0.

## 4. Gates

```
just ws-lint   → exit 0 (0 errors; 45 pre-existing warnings, unchanged class)
just ws-build  → exit 0 (Next.js 16.4.2 build, 60/60 static pages)
```

No leftover listeners on :18543/:18581 after the 5× (`lsof -ti :18543 :18581` → empty).

## 5. Notes

- Leg-5 `hydrate()` no longer hangs: the hang was the shim Tx race, not a
  journal-sync hydrate defect. No timeout masking used.
- The court file was concurrently refined while this lane worked (asdf exec
  PATH pin in `bootRuntime`, leg-6/6b cumulative-receipt rework) — this fix
  was applied on top of that content; no conflicts.
- `p12-verified=false` on flush-after-first is a pre-existing KD-candidate
  finding (server seals the CUMULATIVE per-client chain), asserted honestly by
  the court and covered by leg 6b; not a regression of this fix.
- Not committed (per dispatch).

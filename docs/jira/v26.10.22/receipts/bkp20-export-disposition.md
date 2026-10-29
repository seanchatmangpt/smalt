# BK-P20 — Frozen Console static-export disposition

**Standing:** UNSUPPORTED (static export) — the static-export claim is falsified by build failure; the served console (COOP/COEP) is the witnessed, landed truth.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main, shared tree — coordinator owns git)
Lane: BK-P20
Owns: `workspace/next.config.mjs` (shim only, reverted byte-exact, net-zero → not committed) + P20 cell in `docs/jira/v26.10.22/patterns/PATTERN-LANGUAGE.md` + this receipt.

## Question

PATTERN-LANGUAGE.md P20 "Frozen Console" claimed `output: 'export'` producing an
`out/` standalone static artifact. Landed tree has no such config — BK-PATDRIFT
typed the cell DRIFTED. This lane resolved the disposition honestly: can the
console actually export statically?

## Falsifier: export build FAILS (embedded output)

Shim: added `output: 'export'` to `workspace/next.config.mjs` (marker
`SHIM-COURT BK-P20`), ran `npx next build`:

```
✓ Compiled successfully in 1932ms
  Running TypeScript ...
  Finished TypeScript in 1592ms ...
  Collecting page data using 15 workers ...
Error: export const dynamic = "force-dynamic" on page "/api/v1/stream" cannot
be used with "output: export".
    at Object.<anonymous> (.next/server/app/api/v1/stream/route.js:6:3)

> Build error occurred
Error: Failed to collect page data for /api/v1/stream
```

(Also warned: `Specified "headers" will not automatically work with "output:
export"` — the COOP/COEP header config alone rules out export semantics.)

Mechanism: `workspace/app/api/v1/stream/route.ts` (and the other BFF route
handlers: `app/api/sync/state`, `app/process/api`, `app/bench/metrics`,
`app/api/v1/ingest`, `app/api/bench/isr-*`) are `force-dynamic` route handlers;
static export cannot serve them, and the `headers()` COOP/COEP block is a
server face. The static-export claim is not just unwitnessed — it is
structurally impossible on this tree without deleting the BFF layer.

## Witnessed alternative: the served console

Normal build (no shim) + `next start -p 47183`:

```
$ curl -sI http://127.0.0.1:47183/console
HTTP/1.1 200 OK
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
$ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:47183/terminal
200
```

/terminal serves 200. Header block is the landed `next.config.mjs headers()`
W3C-E row-10 origin-isolation posture (shared face with P6, zero-copy
UI<->worker transfer).

## Cleanup

- Shim reverted via snapshot restore; sha256 of restored
  `workspace/next.config.mjs` =
  `61d434edabd47dcf9e2bef6ba4c3955231efacbc3e8130c5e6bc040c03daa1fb` —
  byte-identical to pre-shim snapshot. `git status` on the file: clean.
- `out/` and `.next/` build artifacts removed; `next start` killed (pgrep: none).
- No speculative capability built.

## Falsifier for the cell itself

Re-flip P20 to any static-export standing only after the BFF route handlers
are removed or made statically exportable — the current build failure is the
gate.

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ shasum -a 256 workspace/next.config.mjs
61d434edabd47dcf9e2bef6ba4c3955231efacbc3e8130c5e6bc040c03daa1fb  workspace/next.config.mjs
shasum exit 0
```

Re-check verdict: PASS — the restored `next.config.mjs` sha256 still equals
the receipt-recorded `61d434ed…` byte-for-byte (shim stays reverted,
UNSUPPORTED disposition for static export stands).

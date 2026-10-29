# BK-66 — P12 Constant Seal live DOM wiring (renderReceiptFields residue retired)

**Standing**: ALIVE (static + browser tiers; live receipt-over-wire leg stays typed SKIP pending SYNC-1)
**Context**: solo
**Date**: 2026-10-21
**Lane**: PAT-E residue close (P12)

## Diff summary

- `workspace/lib/engine/useJournal.ts` — `JournalSnapshot` gains
  `receiptBytes: number` + `receiptVerified: boolean` (initial `0`/`false`).
  `sync()` success patches them from `flushSync`'s `SyncReceipt`
  (`receiptBytes`, `verified` — computed there by the landed PAT-B API:
  `parseReceiptToken` + `verifyReceipt` over exactly the synced frames).
  Refusal path patches `receiptVerified: false` honestly (a refused sync never
  claims a verified seal).
- `workspace/lib/engine/useSovereignTerminal.ts` — passes the two new fields
  through to the terminal surface.
- `workspace/app/terminal/page.tsx` — `mainRef` + `useEffect` keyed on
  `[t.receipt, t.receiptVerified]` driving `renderReceiptFields(mainRef.current,
  t.receipt, t.receiptVerified)` on the live `<main>` element: emits
  `[data-receipt-bytes="320"]` + `[data-receipt-verified="true"|"false"]`.
  Malformed/absent token renders `0`/`false` (parse alone never verifies).
  `renderReceiptFields` now has a live caller — the zero-caller residue named
  by PAT-E is retired.

Domain blindness preserved: the page moves opaque tokens and booleans only;
no receipt-layout semantics left the engine layer.

## Court outputs

- `just ws-lint` — exit 0 (0 errors; 38 pre-existing warnings, none introduced).
- `just ws-build` — exit 0 (next build, 60/60 pages).
- `just patterns-court` — exit 0: **13 PASS / 3 SKIP / 0 FAIL**.
  P12 Constant Seal (dom-lint) PASS: "emission surface (14 files via import
  closure) emits all contract selectors" — the residue-note failure mode is
  gone (emitter reachable from page.tsx via the real import graph, not an
  orphan). Browser tier P1/P2/P3/P6 PASS on system Chrome over `next start`
  (incl. 50-burst strictly monotonic seq 3..52). P4/P5/P9 remain typed SKIP
  (SYNC-1 / browsers), loudly.
- `node scripts/receipt-court.mjs` (workspace) — exit 0: 21/21 assertions,
  incl. "renderReceiptFields sets 320/true on a verified token" and
  "renderReceiptFields sets 0/false on a malformed token".

## Falsifier status

Live receipt-over-wire emission (real server receiptToken → bytes=320 on the
DOM after a real sync) still requires SYNC-1; the browser P12 check stays
typed SKIP until then. Static lint + logic courts are the executed evidence
here.

## Exit codes

| gate | exit |
|---|---|
| just ws-lint | 0 |
| just ws-build | 0 |
| just patterns-court | 0 |
| node scripts/receipt-court.mjs | 0 |

Not committed (per lane instruction).

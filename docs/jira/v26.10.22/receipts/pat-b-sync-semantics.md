# Receipt — PAT-B sync semantics (patterns 8, 10, 12)

**Standing:** ALIVE (node courts exit 0; ws-lint/ws-build exit 0)
Date: 2026-10-21
Lane: PAT-B · Repo: /Users/sac/smalt (canonical checkout, main)

## Delivered

- `workspace/lib/engine/snapback.ts` (NEW) — P10 Elastic Snapback.
  - `planSnapback(unackedSegments, serverHeadSeq)` pure; `snapbackWithStore(ops, serverHeadSeq)`
    drives a `SnapbackStoreOps` interface. Pure/IO separated so node courts run it against an
    in-memory store; the browser path wires the same ops to real IndexedDB.
- `workspace/lib/engine/receipt.ts` (NEW) — P12 Constant Seal.
  - 320-byte receipt parse (hex preferred, base64 accepted), byte-length exposed, typed refusals
    (NOT_STRING / BAD_ENCODING / BAD_LENGTH / BAD_MAGIC / BAD_VERSION), `verifyReceipt` recomputes
    the local sha256-chain leaf root (merkle.ts Accumulator) and compares to the receipt root,
    `renderReceiptFields` drives `data-receipt-bytes` / `data-receipt-verified`.
- `workspace/lib/engine/journal-sync.ts` (EDITED, additive) — P8/P10/P12 wiring:
  - new error variant `{ code: "SYNC_REFUSED_BY_SERVER"; detail; serverHeadSeq; purged }`
  - `snapbackStoreOps()` + `applySnapback(serverHeadSeq)` wire SnapbackStoreOps to real IndexedDB
    (purge un-acked segments + `markSynced(serverHeadSeq)`)
  - `flushSync()` non-2xx branch: body `{refusal, serverHeadSeq}` → snapback, typed refusal out;
    success branch: `verifyReceipt(parts, token)` → returns
    `{ lastSeq, receiptToken, markedTo, syncedSeq, receiptBytes, verified }`
  - `SyncReceipt` extended with `syncedSeq` / `receiptBytes` / `verified` (P8 fields).
- `workspace/scripts/snapback-court.mjs` (NEW) — 10 assertions, exit 0.
- `workspace/scripts/receipt-court.mjs` (NEW) — 20 assertions, exit 0.
  (Courts live in `workspace/scripts/` next to `codec-court.mjs` — the repo's plain-mjs court
  home — not repo-root `scripts/`; location disclosed for PAT-C.)

## Court runs (real, final)

```
$ node scripts/snapback-court.mjs   → snapback-court: all assertions passed (exit 0)
$ node scripts/receipt-court.mjs    → receipt-court: all assertions passed (exit 0)
$ just ws-lint                      → exit 0 (0 errors, 35 pre-existing warnings)
$ just ws-build                     → exit 0
```

snapback-court: pure plan shape (purge ascending, cursor = serverHeadSeq, ordered transitions);
refusal at head 2 over 6 segments purges exactly 3..6 (asserted on real fake-store state), purged
count 4; empty un-acked still resets the cursor; unsorted input sorts.

receipt-court: 320-byte invariant at n=1 and n=100 (640-hex tokens, O(1) seal size); verify true
path at n=100 over real WebCrypto leaf chains; false paths (root-byte flip, wrong leafCount,
non-zero reserved byte, frames not under the receipt); typed parse refusals; base64/hex parity;
DOM field driver (320/true, 0/false on malformed).

## Disclosures

1. **Naming divergence**: the pattern text says "delete records with synced===0"; the journal
   stores ack standing as boolean `acked`. Snapback purges `acked === false` records
   (`seqId > cursor ∧ ¬acked` via `unacked()`).
2. **Receipt encoding is PAT-B-defined, NOT yet coordinated with SYNC-1** (its server code has
   not landed). Proposal: lowercase hex, 640 chars = 320 bytes, big-endian: magic `0x534D4C54`
   (bytes 0..3), version 1 (4..7), leafCount uint64 (8..15), sha256-chain root (16..47),
   reserved zero (48..319). Base64 of the same bytes also parses. `mintReceiptToken()` in
   receipt.ts is the reference minter SYNC-1 should mirror.
3. **Compile-freeze unblock (cross-lane, disclosed per SLA)**: `law-worker-bridge.ts` (another
   lane's in-flight file) failed the shared `just ws-build` type check
   (`cap.reason` on a union without `.reason`). Minimal fix applied:
   `andonRule(cap) ?? "ALLOC_CAP_EXCEEDED"`, with a comment naming the unblock. The owning lane
   should reconcile or keep it.
4. PAT-A landed edits to `journal-sync.ts` mid-task (appendLocal turnstile); my edits are
   additive on the post-turnstile file, re-read before each edit. No conflicts.
5. `flushSync` returns `syncedSeq/receiptBytes/verified`; it does not itself touch the DOM —
   `renderReceiptFields(el, token, verified)` is the DOM driver for the terminal page (PAT-C
   selectors `[data-receipt-bytes="320"]`, `[data-receipt-verified="true"]`).

## Server contract for SYNC-1 (relay to coordinator)

- Refusal: **non-2xx** status, JSON body exactly `{ refusal: string, serverHeadSeq: number }`
  where `serverHeadSeq` is the canonical server journal head at refusal time. The client snaps
  its cursor to that head and purges everything un-acked.
- Success: `200` `{ lastSeq: number, receiptToken: string }` — `receiptToken` = **hex** of the
  320-byte layout in disclosure 2 (`mintReceiptToken()` is the reference implementation to
  mirror). Root must be the sha256-chain accumulator over the batch's frames in order
  (leaf = full frame bytes, `H(H(leaf)‖prev)`), same algebra as `workspace/lib/engine/merkle.ts`.

## Not done (honest boundary)

- No commit (per orders). Terminal page not touched (PAT-A owns it); the page's existing
  sync handler still reads `res.value.lastSeq` — it will typecheck (field kept) but should be
  updated to surface `receiptBytes/verified` via `renderReceiptFields`.
- `verifyReceipt` compares the receipt root to the client's own recomputation; cross-context
  (pattern 9) and Playwright verification are PAT-C.

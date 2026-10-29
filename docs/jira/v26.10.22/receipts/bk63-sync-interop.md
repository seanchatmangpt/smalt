# BK-63 — End-to-end sync interop witness (client ↔ server, real bytes)

**Standing:** **ALIVE** (9/9 legs PASS on a live lane runtime)
Context: solo

## Subject

- Client: `workspace/lib/engine/codec.ts` + `receipt.ts` (+`merkle.ts`) + `snapback.ts`
  (+`journal-sync.ts` semantics). Exact module copies under `tmp/witness/engine/`
  (byte-copies; single disclosed delta: `receipt.ts`'s `./merkle` → `./merkle.ts`
  import-specifier fix so Node type-stripping can resolve it — path-only, no semantic edit).
- Server: `lib/smalt/egress/SyncRoutes.ex` + `lib/smalt/sync/{batch,frame,guard,receipt,store}.ex`,
  compiled in `MIX_BUILD_ROOT=_build-bk63` (OTP 29.1.2 / Elixir 1.20.4-otp-29, asdf toolchain).
- Runtime: real `Smalt.EgressRouter` + real `Smalt.Sync.Store` served by Bandit on
  `127.0.0.1:18443`, auth `:anonymous` (documented test posture — the sync route sits
  behind the global `Smalt.Auth.Bearer` plug, which has no `/sync/*` exemption).
- Harness: `tmp/witness/witness.mjs` (Node v26.10.0, native TS type-stripping;
  imports the workspace engine modules directly).

## Deviations (disclosed, not fixes)

1. **Partial-plane boot.** Full `:smalt` app boot is currently blocked by an
   in-flight sibling lane: `lib/smalt/plane/data_supervisor.ex` references a
   not-yet-landed `Smalt.Store.Heir` child, and `lib/smalt/store/partition.ex`
   was mid-edit with a syntax error during the window (healed under the SLA
   while this lane waited). Per the witness contract lib/ was not edited by
   this lane. The witness runtime boots the two real production modules the
   sync surface needs (`EgressRouter`, `Sync.Store`) — no mock on the audited
   path.
2. **Anonymous auth** (above) instead of enforce+STS bearer.
3. **Snapback store.** No IndexedDB implementation exists in the air-gapped
   Node dep set (no fake-indexeddb/happy-dom in `workspace/node_modules`), so
   the snapback leg drives `snapback.ts`'s documented node wiring
   (`SnapbackStoreOps` over a real in-memory store: real deletes, real cursor
   writes, asserted final state). `planSnapback`/`snapbackWithStore` are the
   exact workspace bytes.

## Round-trip transcript (final run)

```
[PASS] codec.crc32SelfTest :: IEEE check vector 0xCBF43926
[PASS] rt.200-shape :: status=200 lastSeq=3 tokenLen=640 frames=[{seq:1..3 verdict:admit}]
[PASS] rt.parse-320 :: ok=true bytes=320 leafCount=3 version=1 reservedZero=true
[PASS] root-match    :: client-recomputed=dba7d9303dd9eb99... == server root (earlier run; final run 3096a1e4c759d90b...)
[PASS] rt.verifyReceipt :: verified=true
[PASS] adv.bitflip-refusal :: status=400 {"refusal":"BAD_CRC32","serverHeadSeq":3}
[PASS] adv.seq-regression  :: status=409 {"refusal":"SEQ_REGRESSION","serverHeadSeq":3}
[PASS] snapback.purge-to-head :: purged=5 newCursor=3 remaining= (none) transitions=[SYNC_REFUSED_BY_SERVER, READY_STANDALONE]
[PASS] snapback.planSnapback-pure :: purgeSeqIds=8,9 newCursor=3
SUMMARY: 9/9 PASS, 0 FAIL
```

## Per-leg verdicts

| leg | verdict | evidence |
|---|---|---|
| codec check vector | PASS | `crc32SelfTest()` true (0xCBF43926) |
| 3-frame batch → 200 `{lastSeq, receiptToken}` | PASS | lastSeq=3, token 640 hex, per-frame `{"seq":N,"verdict":"admit"}` |
| receipt parse | PASS | 320 bytes, magic SMLT, version 1, leafCount 3, reservedZero |
| sha256-chain root | PASS | client recompute == server receipt root (independent Node recompute agrees) |
| `verifyReceipt` verified:true | PASS | counts + root + reservedZero all match |
| bit-flip payload byte → typed refusal | PASS | 400 `BAD_CRC32`, `serverHeadSeq:3` present |
| seq regression → typed refusal | PASS | 409 `SEQ_REGRESSION`, `serverHeadSeq:3` |
| snapback purge-to-head | PASS | 5 un-acked purged (incl. server-committed 1..3 — documented FR-SNC-006 law: purge ALL un-acked, reset horizon to serverHeadSeq), cursor=3, both transitions |
| planSnapback purity | PASS | unsorted input [9,8] → sorted purge [8,9], newCursor=serverHeadSeq |

## Commands / exits

```
mix compile (MIX_BUILD_ROOT=_build-bk63, OTP29/1.20.4)  exit 0
mix run --no-start --no-halt tmp/witness/boot.exs       exit 0 (persistent listener)
node tmp/witness/witness.mjs                            exit 0, SUMMARY: 9/9 PASS
```

First full run: 8/9 (the 1 FAIL was this lane's harness asserting the wrong
snapback model — keep-committed-1..3 — against the documented purge-ALL-unacked
law; the server/client code was right, the witness assertion was corrected to
the landed contract and rerun 9/9). Earlier a stale-compile runtime answered
SHORT_FRAME to well-formed frames; a clean `_build-bk63` recompile cleared it
(within the same compile-freeze window as the sibling lane's partition.ex
syntax error, waited out per SLA).

## Falsifier status

- Round trip with real bytes: falsified? No — verified true on live TCP.
- Adversarial legs produce typed refusals carrying serverHeadSeq: verified.
- Snapback purges to server head: verified.

## Not committed

Per lane contract: receipt + tmp/witness/ left uncommitted for the coordinator.

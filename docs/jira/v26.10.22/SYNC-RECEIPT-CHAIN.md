# Sync-Receipt-Chain

Standing: PARTIAL_ALIVE (canonical record of the end-to-end chain; every
surface below is court-witnessed except the typed UNANCHORED claims in
section 7, which cite `ARCH-SYNC-MEMO.md` section 4)
Context: solo

Canonical record of the sync receipt chain end-to-end: client WAL frame →
journal sink → server receipt minter → browser parse/verify → VC 2.0
export face. Every number cites a receipt or measured output; nothing here
is operator-asserted.

## 1. Client WAL frame — `workspace/lib/engine/codec.ts` (ATH-2)

Wire frame, all big-endian (`codec.ts` header comment; `ath2-nextjs-client.md`):

```
offset  size  field
0       4     magic   = 0x534D4C54 ("SMLT")
4       4     len     = payload byte length
8       8     clientId (u64)
16      8     seqId    (u64, monotone per clientId)
24      8     ts       (u64, producer epoch millis)
32      4     crc32    (IEEE, table-driven, poly 0xEDB88320, payload only)
36      1     op       (integer opcode)
37      4     reserved (zero pad; header is 41 bytes total)
41      len   payload
```

- The 4 `reserved` bytes pad the enumerated fields to the pinned 41-byte
  header; both lanes must count 41 (`ath2-nextjs-client.md`, deviation 4;
  mirrored by ATH-1, `ath1-batch-frame-receiver.md`).
- CRC32 self-check vector: `crc32(utf8("123456789")) == 0xCBF43926`
  (`codec.ts` `crc32SelfTest/0`; witnessed in `codec-court.mjs` per
  `ath2-nextjs-client.md`).
- Typed decode refusals, never throws: `BAD_MAGIC` / `SHORT_FRAME` /
  `BAD_LEN` / `BAD_CRC32` / `SEQ_REGRESSION` (`codec.ts` `CodecError`).
- Court: SYNC-2 codec court 11/0 (cited in `ARCH-SYNC-MEMO.md` section 2,
  "Wire protocol" row).

Server mirror: `lib/smalt/sync/frame.ex` + `lib/smalt/sync/batch.ex`
decode the same 41-byte layout with per-client seq monotonicity against
the committed head; batch-fatal header class vs per-frame
`BAD_CRC32`/`SEQ_REGRESSION` classification (`ath1-batch-frame-receiver.md`).

## 2. Journal sink — `lib/smalt/storage/journal_sink.ex` (SJ-1 / BK-135r)

Segment frame layout (module header, `journal_sink.ex:10-17`):

```
FrameLen(4) + SeqID(8) + TsMs(8) + EventType(4) + TableID(4)
+ KeyLen(4) + Key + PayloadLen(4) + Payload + CRC32(4)
```

- CRC32 over SeqID..Payload (everything between FrameLen and CRC);
  `:erlang.crc32` at `journal_sink.ex:179`; read-side mismatch →
  `{:error, :crc_mismatch}` (`journal_sink.ex:211-214`).
- Store-owned event codes ride the journal: put 0x0A01 / delete
  tombstone 0x0A02 / sync frames 0x0A03, table_id 0
  (`ttv4-journal-boot-replay.md`, `ath1-batch-frame-receiver.md`).
- TTV-4 wires sealed-segment boot replay into `Smalt.Store.init/1`:
  replay-then-listen, halting at the first typed refusal; 1-bit manifest
  flip → `{:manifest_mismatch, ...}`; truncated tail →
  `{:truncated_tail, [offset: 0, have: 5]}` — boot-refuse, never a
  silent skip (`ttv4-journal-boot-replay.md`, legs 3-4, `Result: 4
  passed`, EXIT=0).
- Matter scoping (BK-135r, PARTIAL_ALIVE,
  `bk135r-matter-journal.md`): `append_frame/6` gains `:matter_scope`;
  scoped frames live entirely under `<dir>/matter_<scope>/segments/`
  via the ONE scope-naming law `matter_root/2`; `validate_scope/1`
  (`^[A-Za-z0-9][A-Za-z0-9._-]*$`) typed-refuses `../escape` and `a/b`
  with zero filesystem effect; per-scope seals, SeqIDs, SPOF-A1
  recovery and SPOF-A3 quarantine. Court 3/3 + regressions SJ-1/TTV-4
  7 passed + SJ-4 PASS; shim court non-vacuity: shimmed `matter_root/2`
  turns leg (a) red, byte-exact restore verified.

## 3. Server receipt minter — `lib/smalt/sync/receipt.ex` (BK-92)

`Smalt.Sync.Receipt` — 320 bytes = 40 x 8-byte words, big-endian
(`receipt.ex` moduledoc):

```
bytes  0..3   magic 0x534D4C54
bytes  4..7   version 1
bytes  8..15  leafCount uint64 BE (frames sealed)
bytes 16..47  sha256-chain root (32 bytes)
bytes 48..319 reserved, all zero
```

- Chain law (identical algebra both sides): first leaf
  `h = sha256(sha256(frame_bytes))`; later leaves
  `h = sha256(prev_root <> sha256(frame_bytes))`
  (`receipt.ex` moduledoc; mirrored in `merkle.ts` `Accumulator`).
- Token = lowercase hex, 640 chars (`receipt.ex` `mint/1`).
- O(1) size: the 320 B figure is layout-pinned by the term grammar above
  (court-witnessed: BK-63 `rt.parse-320`, BK-92 cross-mint) — 320 B at
  every n by construction. NOTE (BK-RSIZE): the PB-4 bench
  (`surface: "pplan.receipt_engine.seal"`) measures a DIFFERENT object —
  the `Smalt.PPlan.ReceiptEngine.seal_receipt/3` receipt map term — not
  this token. That term is now 48 heap words (384 B) at every n
  (post-GAP-6a agent chain; was 40 words pre-GAP-6a) per PB4-R
  (`receipts/pb4r-identity-court.md`) and the BK-RSIZE re-measurement
  (`receipts/bkrsize-receipt-truth.md`).
- BK-92 differential cross-mint (real execution, both toolchains,
  `bk92-receipt-sot.md` section 2): count=42, root =
  sha256(sha256("probe")) → Elixir `mix run` and node TS minter both
  emit the same 640-char token; `cmp` BYTE-IDENTICAL. Verdict
  (`bk92-receipt-sot.md` section 4): "NO DIVERGENCE. The two minters
  are byte-identical functions of (leafCount, root)."

## 4. Browser parse/verify — `workspace/lib/engine/receipt.ts` (P12 / KD-165)

- `parseReceiptToken/1`: hex preferred, base64 also accepted at parse
  (a parse-side superset per `bk92-receipt-sot.md` section 1, encoding
  row); typed refusals `NOT_STRING` / `BAD_ENCODING` / `BAD_LENGTH` /
  `BAD_MAGIC` / `BAD_VERSION`; never throws (`receipt.ts:84-119`).
- Nonzero reserved bytes do not refuse at parse — they set
  `reservedZero=false`, which feeds `verified:false` in
  `verifyReceipt/2` (`receipt.ts:100-106,154`; refusal-semantics note
  in `bk92-receipt-sot.md` section 1, reserved row).
- `verifyReceipt/2` re-appends every synced frame into a fresh
  `Accumulator` and requires count match AND root match AND
  reservedZero (`receipt.ts:139-157`).
- KD-165 (CLOSED-WITH-EVIDENCE, `bk109-kd165-pointer.md`): the client
  originally verified only the flushed part against the server's
  cumulative per-client chain, giving `verified:false` on any flush
  after the first; fixed by client-side full-ledger cumulative verify
  (`bk106-sync-engine-fixes.md`).
- BK-63 interop witness on a live runtime: server mint → wire → client
  parse + chain recompute, `SUMMARY: 9/9 PASS, 0 FAIL`, including
  `rt.parse-320` leafCount=3 and `verifyReceipt verified=true`
  (`bk92-receipt-sot.md` section 3, last row).

## 5. VC 2.0 export face — `lib/smalt/receipt/vc_export.ex` (W3C-B)

- `Smalt.Receipt.VcExport.to_vc/2` reads the SAME term grammar:
  `<<0x534D_4C54::32, 1::32, leaf_count::64, root::binary-size(32),
  0::(272*8)>>` (`vc_export.ex:107`); other versions raise; bad magic
  raises; nonzero reserved raises (`vc_export.ex:110-115`).
- Term-own fields win: `frameCount`/`merkleRoot` are read from the
  term; an override that disagrees is refused, never shadowed
  (`vc_export.ex:198-214`).
- Proof: `DataIntegrityProof`, cryptosuite `smalt-rs256-jws`, RS256
  detached-JWS via `Smalt.Security.ReceiptSigner` over the
  canonicalized subject (`vc_export.ex:174-182`).
- Typed UNSUPPORTED gap (`vc_export.ex` moduledoc "Honest gap"): the
  proof is NOT a registered W3C Data-Integrity cryptosuite; falsifier —
  a stock W3C Data-Integrity verifier fails on `to_vc/2` output. Court:
  w3cb VC court green (co-run with ath1, 20 tests total,
  `bk92-receipt-sot.md` section 3).

## 6. End-to-end receipt inventory

| Hop | Surface | Court / receipt |
|---|---|---|
| frame encode/decode | `workspace/lib/engine/codec.ts` | SYNC-2 codec court 11/0 (ARCH-SYNC-MEMO) |
| server batch decode | `lib/smalt/sync/frame.ex`, `batch.ex` | ath1 court 11/11 (ath1 receipt) |
| journal append/seal/replay | `lib/smalt/storage/journal_sink.ex` | SJ-1 + TTV-4, SJ-4 (bk135r) |
| scope partitioning | `journal_sink.ex` `matter_root/2` | bk135r court 3/3 + shim court PASS |
| receipt mint (server) | `lib/smalt/sync/receipt.ex` | BK-92 cross-mint byte-identical |
| receipt mint (client) | `receipt.ts` `mintReceiptToken` | same BK-92 differential |
| parse/verify | `receipt.ts` `verifyReceipt` | BK-63 witness 9/9 (`bk92-receipt-sot.md`) |
| VC 2.0 export | `lib/smalt/receipt/vc_export.ex` | w3cb court (co-run 20 tests) |

## 7. Known UNANCHORED claims (per the number law)

Carried honestly from `ARCH-SYNC-MEMO.md` section 4 (ledger of record):

- Operational commit <=5.0us / WAL append <=5.0us — UNANCHORED
  (structural courts only; SJ-1 courts seal protocol, not us). Path to
  anchor: extend the SJ-1 bench with per-append wall-clock.
- Merkle verify <0.2ms — UNANCHORED as stated (ladder shows 0.024ms at
  10 leaves — matches at small n only; seal ladder 0.024-656.1 ms
  measured). Path: scope the claim to <=10^3 leaves or bench verify at
  10^5.
- Local write p99 <=10us — GATE, not measured (SYNC-2 gate; browser
  measurement court, warmed per TTV-7 standard).
- Join omega semantics — UNBUILT (FR-SNC-006 WO).

Everything else in this record is receipt-anchored via the courts named
in section 6.

## See Also

- `ARCH-SYNC-MEMO.md` (memo of record; section 4 = number-law ledger)
- `SYNC-CHARTER.md`
- `receipts/bk92-receipt-sot.md`
- `receipts/bk135r-matter-journal.md`
- `receipts/ath1-batch-frame-receiver.md`
- `receipts/ath2-nextjs-client.md`
- `receipts/bk106-sync-engine-fixes.md` (KD-165 fix)
- `../v26.10.21/receipts/ttv4-journal-boot-replay.md`

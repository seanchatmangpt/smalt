# BK-92 — Receipt single-source-of-truth audit

**Standing:** **ALIVE** (no mint/parse divergence; cross-mint byte-identical; all layout courts green)
Context: solo

Subjects:

- `lib/smalt/sync/receipt.ex` (`Smalt.Sync.Receipt` — BK-79/ATH-1 server mirror)
- `workspace/lib/engine/receipt.ts` (`mintReceiptToken`/`parseReceiptToken`/`verifyReceipt` — PAT-B)
- `workspace/lib/engine/merkle.ts` (`Accumulator`, kind `sha256-chain`)
- `lib/smalt/receipt/vc_export.ex` (`Smalt.Receipt.VcExport` — W3C-B, term reader)

## 1. Field-by-field diff

| Field | bytes | `receipt.ex` (mint) | `receipt.ts` (mint/parse) | `vc_export.ex` (read) | verdict |
|---|---|---|---|---|---|
|---|---|---|---|---|---|
| magic | 0..3 | `0x534D4C54` `<<@magic::32>>` | `0x534d4c54`, `getUint32(0,false)`/`setUint32(0,false)` | `0x534D_4C54::32` literal | MATCH |
| version | 4..7 | `<<1::32>>` | `RECEIPT_VERSION=1`, `getUint32(4,false)` | `1::32` literal; other versions raise | MATCH |
| leafCount | 8..15 | `<<count::64>>` (Elixir integer BE) | `setBigUint64(8,false)`/`getBigUint64(8,false)` | `_::64` skipped, surfaced via `frameCount` from term | MATCH |
| root | 16..47 | `Base.decode16!(hex,:lower)` raw 32 bytes | rootHex slice `subarray(16,48)` lowercase hex | `root::binary-size(32)`, hex-lower in `merkleRoot` | MATCH |
| reserved | 48..319 | `0::(272*8)` all-zero | reservedZero scan 48..319 (report only) | `0::(272*8)` — nonzero reserved REFUSES | MATCH (refusal semantics differ: vc_export raises, ts flags `reservedZero=false` feeding `verified:false` — both non-accepting) |
| encoding | token | lowercase hex 640 chars | hex preferred; base64 also accepted at parse | 320-byte binary or 640-char lower hex only | MATCH (ts is a superset at parse: hex ∪ base64; mint face hex-only both sides) |
| size | total | 320 | 320 | 320 | MATCH |
| endianness | all words | big-endian | big-endian (`false` on every view op) | big-endian | MATCH |
| chain algebra | — | first leaf `sha256(sha256(f))`; later `sha256(prev_root <> sha256(f))` | `Accumulator.append`: identical (`digest(leaf)`; empty→`digest(leaf)`, else `digest(root<>leaf)`) | n/a (reads term) | MATCH |
| empty-root mint | — | `root nil` → `<<0::256>>` | mintReceiptToken requires rootHex (n=0 not minted client-side) | would accept 32 zero bytes (32 zero bytes are a valid term) | MATCH, note: n=0 mint is server-side-only face |

No offset, endianness, root-computation, or zero-region divergence exists. The two minters are
byte-identical functions of (leafCount, root).

## 2. Differential cross-mint (real execution, both toolchains)

Input: `count=42`, `root = sha256(sha256("probe"))` = `000ba57a…5e16a`.

- Elixir: `MIX_BUILD_ROOT=_build-lane92 asdf exec mix run -e 'IO.puts(Smalt.Sync.Receipt.mint(%{root: :crypto.hash(:sha256, :crypto.hash(:sha256, "probe")), count: 42}))'` → exit 0
- TS: `node --experimental-strip-types` importing the BK-83 witness copy of `receipt.ts`
  (import-extension-only delta vs `workspace/lib/engine/receipt.ts`, verified by diff) → exit 0
- `cmp`: **BYTE-IDENTICAL** (640-char token, both below)

```
534d4c5400000001000000000000002a000ba57a29e8d7bf55592779cc077500c666634b485138c14f940155fd75e16a
0000...(272 zero bytes, hex)
```

## 3. Court runs (this audit, 2026-10-21)

| Court | Command (cwd) | Exit | Result |
|---|---|---|---|
| ath1 receiver court | `MIX_BUILD_ROOT=_build-lane92 asdf exec mix test test/internal/ath1_batch_frame_receiver_court_test.exs test/internal/w3cb_vc_export_court_test.exs` (repo root) | 0 | 20 passed (ath1 + w3cb together) |
| w3cb VC court | same run | 0 | included above |
| P12 receipt-court | `node scripts/receipt-court.mjs` (workspace/) | 0 | "all assertions passed" |
| snapback-court | `node scripts/snapback-court.mjs` (workspace/) | 0 | "all assertions passed" |
| BK-63 interop witness (arbiter) | `node tmp/witness/witness.mjs` (repo root) against freshly booted `mix run --no-start --no-halt tmp/witness/boot.exs` (:18443, MIX_BUILD_ROOT=_build-bk63) | 0 | `SUMMARY: 9/9 PASS, 0 FAIL` (incl. rt.parse-320 leafCount=3, verifyReceipt verified=true) |

## 4. Divergence verdict

**NO DIVERGENCE.** The BK-63 interop witness (server mint → wire → client parse +
chain recompute) is green on a live runtime, the differential cross-mint is
byte-identical, and `vc_export.ex` reads the same term grammar. The BK-79 and
PAT-B layout claims are the same layout; single source of truth is adequately
pinned by the ath1 docstring + w3cb term law, and both name the same 320-byte
grammar.

### Typed findings for owner dispatch (not edited by this lane)

1. **BK-92-F1 — `workspace/scripts/sync-e2e-court.mjs` is not a reliable exit-0
   gate.** 6/6 runs failed to complete in this session: 2 runs crashed in the
   BK-83 idb-shim `onupgradeneeded` path (`TypeError: Cannot read properties of
   undefined (reading 'objectStoreNames')`, `tmp/witness/bk83/idb-shim.mjs:135`),
   4 runs hung with "unsettled top-level await" at leg 5 (`hydrate()` after
   corrupt-append; exit 13) — the shim's `queueMicrotask` Tx `pending`/
   `maybeComplete` accounting races real multi-op transactions. The receipt legs
   themselves PASS whenever reached (`sync.flush-5-200-verified`: 320 bytes,
   verified=true, leaves=5, markedTo=5). Harness-class defect (shim race), NOT a
   receipt divergence — the arbiter witness is 9/9. Close: fix shim Tx
   completion accounting or run leg 5 against a real sqlite/file-backed store.
2. **BK-92-F2 — asdf-exec class gap (confirms queued BK-90).** Bare `mix test`
   in a non-interactive shell resolves homebrew Elixir 1.19.5/OTP28 and refuses
   boot (`supports only Elixir ~> 1.20`); every gate invocation must go through
   `asdf exec`. Witnessed here on the ath1/w3cb court run and on `mix run`.
3. Note — the BK-63 witness substrate (:18443) was not running at audit start;
   this audit rebooted it (`tmp/witness/bk63-reboot.log`, boot marker
   `BK63_WITNESS_BOOT_OK`, ~5 min cold dep compile in `_build-bk63`) and killed
   it afterward. `scripts/sync-e2e-court.mjs` boots its own runtime (18543) but
   still needs the shim fix (F1).

### Coordinator cleanup (permission-denied to this lane, pending)

- `_build-lane92` lane build root still on disk — delete at integration.
- The bk63 witness beam (port 18443) was sent SIGTERM; verify no listener
  remains (`lsof -ti :18443`).

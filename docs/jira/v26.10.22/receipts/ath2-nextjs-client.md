# ATH-2 — Next.js browser client (graphlaw guard + journal + batch sync)

**Standing:** **ALIVE (browser surface); sync server leg PARTIAL_ALIVE — endpoint pending ATH-1**
Context: solo
Date: 2026-10-21
Lane: ATH-2 (charter: `docs/jira/v26.10.22/SYNC-CHARTER.md`)

## Scope

Browser-side client surface in `workspace/` per the operator artifact spec:
domain-blind, byte-moving only, zero domain words in `.ts`/`.tsx` (verified by
grep below). Worker spawns via `import.meta.url` in the page (Next 16/webpack
worker loader, same pattern as `app/bench/compute/page.tsx`).

## Deliverables

| Artifact | Status | Notes |
|---|---|---|
| `workspace/lib/engine/codec.ts` | DONE | `SMLT` magic 0x534D4C54; 41-byte big-endian header `magic:32\|len:32\|clientId:64\|seqId:64\|ts:64\|crc32:32\|op:8\|reserved:32`; table-driven IEEE CRC32 (vector `123456789` → 0xCBF43926); typed decode refusals BAD_MAGIC / SHORT_FRAME / BAD_LEN / BAD_CRC32 / SEQ_REGRESSION; never throws. The four `reserved` bytes pad the enumerated fields to the pinned 41-byte header — both lanes must count 41 (interop note for ATH-1). |
| `workspace/workers/law-reticle.worker.ts` | DONE | Loads `public/wasm/graphlaw.wasm` (copied from `/Users/sac/graphlaw/priv/graphlaw.wasm`, sha256 `f30bc769f120c1c132e095c694c349e2ef1b375a260be225cd905a8210472c72`) and drives `gl_alloc`/`gl_call`/`gl_free` over the documented JSON ABI (graphlaw `src/abi.rs`, ABI v1). Minimal `wasi_snapshot_preview1` shim (env/clock/random/stdio stubs); the module's full import surface is enumerated pre-instantiate and any unlinked import fails INIT closed. op-1 → `{"op":"shacl","data":{"text"},"shapes"}`; op-2 → `{"op":"n3","text"}`; admission requires `ok:true` AND (op-1) `conforms !== false`. packet-4 (u32 BE length prefix) framing on the postMessage channel, mirroring the smalt WASM-1 port frames. |
| `workspace/lib/engine/journal-sync.ts` | DONE | IndexedDB db `smalt_local_ledger`, store `wal_segments` (keyPath `seqId`), plus a `sync_cursor` store (single `"cursor"` record — a disclosed minimal addition to the two-name contract). `appendLocal` (seq = max+1, ts/clientId = epoch), `unacked()`, `markSynced(seq)`, `flushSync()` — batch = concatenated frame bytes, POST `application/octet-stream` to `/sync/journal/batch` over **smaltFetch only**, receipt `{lastSeq, receiptToken}` advances the cursor. Typed results, never throws; INDEXEDDB_UNAVAILABLE / STORE_FAILURE / SYNC_HTTP / SYNC_REFUSED. |
| `workspace/app/terminal/page.tsx` | DONE | "use client" sovereign console: INITIALIZING → READY_STANDALONE → COMMITTED_LOCAL → SYNCED_AND_SEALED, HALTED_BY_SIEVE (red ANDON panel, `role=alert`, byte-0 refusal — nothing journaled), SYNC_REFUSED_BY_SERVER. Reticle + input-bytes textareas, Evaluate+Commit and Sync buttons, journal-standing panel, event log. Worker spawned via `new URL(..., import.meta.url)`. |
| `workspace/lib/engine/guard.ts` | DONE | Worker bridge: packet-4 framing + typed verdicts. Worker spawn function is injected by the page so this module stays plain-node importable (witnessed by ws-court's lib import sweep). |
| `workspace/lib/engine/merkle.ts` | DONE | Running chain accumulator. **Honest deviation:** SHA-256 chain via WebCrypto, NOT BLAKE3 — the air-gapped dependency set contains zero hash libraries (checked `package.json` + `node_modules`), and fetching one violates zero-egress. Hash identity travels as the `accumulatorKind()` tag `"sha256-chain"` wherever a root crosses the wire. |
| `workspace/scripts/codec-court.mjs` | DONE | Plain-node assertion court (tsc-compiles `lib/engine/codec.ts`, then asserts): CRC32 vector, 41-byte header, encode→decode round-trip, corrupt payload → BAD_CRC32, corrupt magic → BAD_MAGIC, truncation → SHORT_FRAME, length lie → BAD_LEN, seq regression → SEQ_REGRESSION (floor inclusive). Exit 0/1. |
| `workspace/public/wasm/graphlaw.wasm` | DONE | Static asset copied from the pinned graphlaw artifact; byte count 6,654,496; sha256 above. |

## Deviations (operator spec vs artifact reality)

1. **No `gl_load_reticle` export.** The pinned artifact exports only
   `gl_alloc`/`gl_call`/`gl_free` (+ WASI + memory, reactor `_initialize`).
   The documented call shape (`graphlaw/src/abi.rs`, `wasm/src/ffi.rs`,
   `tests/wasm_abi.rs`) is a self-contained JSON request per call, so the
   reticle bytes ride each op-1 request in the `shapes` field (INIT stores
   them worker-side). Wire bytes and JSON contract otherwise exact.
2. **`gl_call` signature is `(ptr, len) -> packed u64`** — there is no
   `(handle, op, ptr, len)` form. The op byte stays in the worker message
   protocol (op 1 = SHACL preflight, op 2 = N3 admission) and maps to the
   JSON `"op"` field.
3. **shacl op returns `ok:true` with `conforms` inside** — admission requires
   `conforms !== false`, not merely a successful call. Witnessed: the naive
   ok-only check admitted a non-conformant payload (probe below).
4. **`reserved:32` field added** to pad the enumerated header fields to the
   pinned 41-byte header; wire-visible, must be mirrored by ATH-1.
5. **SHA-256 chain instead of BLAKE3** (deliverable 3), as disclosed above.
6. **`/sync/journal/batch` has no server listener yet** (ATH-1 pending).
   Sync against today's substrate returns a typed SYNC_HTTP(404) and the
   page enters SYNC_REFUSED_BY_SERVER — fail-closed, nothing mis-marks.

## Verification (real gate outputs)

```
$ node workspace/scripts/codec-court.mjs   → exit 0
[PASS] crc32 check vector — crc32("123456789") = 0xcbf43926
[PASS] header is 41 bytes — HEADER_LEN=41
[PASS] round-trip — fields + payload byte-exact
[PASS] corrupt payload -> BAD_CRC32
[PASS] corrupt magic -> BAD_MAGIC
[PASS] truncated -> SHORT_FRAME
[PASS] length lie -> BAD_LEN
[PASS] seq regression -> SEQ_REGRESSION — observed=3 minimum=7
[PASS] seq equal-to-floor passes
# codec court verdict: PASS (0 failure(s))

$ just ws-lint    → exit 0   (35 warnings, 0 errors; warnings incl. pre-existing)
$ just ws-build   → exit 0   (route table includes `/terminal`)
$ just ws-court   → exit 0   # PASS=56 FAIL=0 SKIP=2
  [PASS] lib typecheck — tsc clean over lib/**
  [PASS] import lib/engine/{codec,guard,journal-sync,merkle}.ts
  [PASS] composition: panel component type-surface — tsc --strict --noEmit clean over components+app+lib
  [SKIP] live: popcorn iframe src — no Next server on :3100 (pre-existing skip, not this lane)
```

### Real-artifact decision-table probe (node WebAssembly, gl ABI, WASI shim)

Run post-fix against the pinned artifact bytes — this is the exact
gl_alloc/gl_call/gl_free call sequence the worker performs:

```
$ node /tmp/ath2-eval-mirror.mjs
[PASS] op-1 admit -> status=0
[PASS] op-1 andon (missing required p) -> status=1 reason: non-conformant: <http://www.w3.org/ns/shacl#MinCountConstraintComponent> at <urn:s>
[PASS] op-1 andon (malformed rdf) -> status=1 reason: call refused
[PASS] op-2 n3 admit -> status=0
# decision-table verdict: PASS
```

Pre-fix witness (why deviation 3 exists): the same probe with an ok-only
check printed `op-1 andon: ok=true (UNEXPECTED ADMIT)` — the conformance
verdict lives inside the ok response; the check was tightened and re-proven.

## Domain-blind invariant

Word-boundary grep `\b(bates|matter|privilege|order)\b` over every delivered
source returns zero matches (exit 1, witnessed 2026-10-21).

## Standing summary

- Codec, guard, worker, journal, accumulator, console page: **ALIVE**
  (courts + real-artifact probe receipts above).
- Sync server leg: **PARTIAL_ALIVE** — client contract implemented and
  fail-closed; end-to-end admit→sync→receipt stays UNKNOWN until ATH-1's
  `/sync/journal/batch` receiver lands and a live round-trip court runs.
- Falsifier for the sync leg: POST a batch to a live ATH-1 receiver and
  mismatched `{lastSeq, receiptToken}` handling, or any 404 reading as
  success — neither occurs today (typed 404 refusal witnessed by contract
  inspection; live court pending ATH-1).

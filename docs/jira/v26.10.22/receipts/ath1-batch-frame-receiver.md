# ATH-1 — Server batch-frame receiver (v26.10.22)

**Standing:** ALIVE — 11/11 court gates green, two seeds, real HTTP over the real router.
Context: solo

## Subject

- `lib/smalt/sync/frame.ex` — `Smalt.Sync.Frame` codec: 41-byte header
  (magic 0x534D4C54 / len / client_id / seq / ts_ms / CRC-32 / op /
  4-byte reserved pad), IEEE CRC-32 over payload only, big-endian; typed decode
  errors (`SHORT_FRAME` / `BAD_MAGIC` / `BAD_LEN`) matching the ATH-2 client
  codec discriminants (`workspace/lib/engine/codec.ts`); a boundary-well-formed
  frame with a failed CRC still decodes with `crc_ok == false` (per-frame
  refusal face).
- `lib/smalt/sync/batch.ex` — batch decode: concatenation of frames, strict
  per-client seq monotonicity (baseline = committed head), batch-fatal
  corrupt-header class (`EMPTY`/`SHORT_FRAME`/`BAD_MAGIC`/`BAD_LEN`) vs
  per-frame `BAD_CRC32`/`SEQ_REGRESSION` classification.
- `lib/smalt/sync/guard.ex` — governance seam: nil guard admits (same nil arm
  as `Powl2.Executor.run_guard/4`); `{:fun, law}` configured REAL law function;
  `:wasm` → existing `Smalt.Wasm.Bridge` path (stub-runner face when
  `wasm_binary_path` unset) with verdicts mapped to the operator byte contract
  (`<<0:8>>` admit / `<<1:8, len::16, reason>>` ANDON).
- `lib/smalt/sync/store.ex` — namespaced generic table `:smalt_sync_frames`
  with Store-identical serialized CAS (last-seq check + insert in ONE
  handle_call) + JournalSink append (sync event code 0x0A03, table_id 0) when
  `:journal_sink_dir` is configured. UNLINKED lazy singleton (see deviations).
- `lib/smalt/sync/receipt.ex` — 320-byte seal, the server mirror of the landed
  client minter (`workspace/lib/engine/receipt.ts` `mintReceiptToken` +
  `merkle.ts` "sha256-chain" Accumulator): magic 0x534D4C54 / version 1 /
  leafCount u64 / 32-byte root / zero reserved, 640-hex token. Server chain
  law: first leaf sha256(sha256(w)); later leaves sha256(root <> sha256(w)).
- `lib/smalt/egress/SyncRoutes.ex` — POST /sync/journal/batch wire face,
  registered as the LAST w6R fallthrough subrouter (one registration edit in
  `lib/smalt/egress_router.ex`).
- Court: `test/internal/ath1_batch_frame_receiver_court_test.exs`, 11 tests.

## Wire contract (pinned)

- Frame: `<<magic::32=0x534D4C54, len::32, clientId::64, seq::64, ts::64,
  crc32::32, op::8, pad::32=0, payload>>` — header 41 bytes incl. pad;
  CRC over payload only; big-endian; identical to the landed ATH-2 codec
  (`workspace/lib/engine/codec.ts`, HEADER_LEN=41).
- Success `200` `{lastSeq, receiptToken (640 hex), frames[]}` — receipt =
  sha256-chain seal over admitted frame wires, byte-identical to the client
  `mintReceiptToken` (courts recompute the root independently and compare).
- Refusal `400/409/413/422`: `{refusal: code, serverHeadSeq: head}` —
  processing stops at the first refusal; commits already fired stand; head is
  the canonical snapback point. Codes: `EMPTY` / `SHORT_FRAME` / `BAD_MAGIC` /
  `BAD_LEN` (batch-fatal, + `connection: close`), `BAD_CRC32` (400),
  `SEQ_REGRESSION` (409), ANDON reasons (422), `TOO_LARGE` (413).
- Per-client seq monotonicity enforced twice: at decode (baseline = committed
  head) and inside the CAS commit (racing batches cannot both admit the same
  seq — one handle_call).

## Court gates (test/internal/ath1_batch_frame_receiver_court_test.exs)

| Gate | Claim | Verdict |
|---|---|---|
| a | valid 3-frame batch → 3 admits + receipt round-trip (root recomputed independently over the exact sent wires, compared to the seal) | PASS |
| b | bad CRC → 400 BAD_CRC32 + serverHeadSeq=1; prior admits stand (baseline 1) | PASS |
| c | corrupt header → 400 BAD_MAGIC + serverHeadSeq=0 + connection close; Store row count unchanged; baseline stays 0 | PASS |
| d | ANDON via configured REAL law fn → 422 "andon-court", zero store mutation (row count unchanged, baseline 0) | PASS |
| d2 | guard `{:fun, law}` config-scoped (put_env/delete_env in try/after) | PASS |
| e | seq regression → 409 SEQ_REGRESSION (within-batch head 4 and cross-batch old-seq both refused; head stays 4) | PASS |
| persistence | second batch continues chain + head; t1 ≠ t2; both seals recompute | PASS |
| pure codec | 41-byte header + zero pad; round-trip; SHORT_FRAME/BAD_MAGIC/BAD_LEN; CRC vector 0xCBF43926 | PASS |
| pure receipt | 320-byte layout (magic/version/leafCount/root/zero-reserved); independent chain recompute; order-sensitivity; empty-chain seal | PASS |

Run output (two seeds):

```
$ MIX_BUILD_ROOT=_build-ath1 mix test test/internal/ath1_batch_frame_receiver_court_test.exs
Finished in 0.5 seconds (0.00s async, 0.5s sync)
Result: 11 passed            # seed 625191-class default
$ MIX_BUILD_ROOT=_build-ath1 mix test ... --seed 12345
Result: 11 passed            # seed 12345
```

Compile clean: zero warnings from lib/smalt/sync/* and SyncRoutes
(grep over the compile log: 0 hits for sync-module warnings).

## Documented deviations (honest-face notes)

- Kill-on-corrupt: a hard connection-process kill is not reachable from
  plug-land (Bandit owns the conn process; aborting it would abort the typed
  refusal frame), so the batch-fatal class answers the typed refusal frame +
  `connection: close`. Pinned by gate c.
- BLAKE3 is not in `:crypto` (OTP 29); the seal uses the sha256-chain the
  client (`merkle.ts`) already standardized with its "sha256-chain" kind tag —
  the client's `verifyReceipt` recomputes and compares the root, so the hash
  identity is pinned by the client court, not by prose.
- The sync table lives under the sync subsystem (not inside `Smalt.Store`'s
  GenServer) because `store_tables.ex` is a ggen-projected registry
  (hand-editing banned). CAS law is Store-identical (serialized CAS in one
  handle_call + JournalSink best-effort append, fail-safe log-drop).
- `Smalt.Sync.Store` is an UNLINKED lazy singleton, not a supervision-tree
  child: the first caller is a short-lived Bandit request process, and a
  `start_link` there would kill the store (and its ETS) when that process
  exits — witnessed live (refusal responses reported head 1 while a fresh
  baseline read 0). Not tree-mounted due to shared-lane contention on
  application.ex; a crash loses the table and the next ensure/0 restarts it
  empty.
- Guard seam: unset guard = admit (Powl2.Executor.run_guard nil-arm shape);
  courts exercise a configured REAL law function. The Bridge `:wasm` face is
  wired but not courted here — in stub mode the stub runner returns the 429
  envelope for every payload, so the stub face refuses every frame; that face
  belongs to the real-artifact court, not this one.
- Wire-contract alignment history (operator pins mid-flight): the receiver
  was re-pinned twice (37→41-byte header with reserved pad; refusal bodies
  gained `serverHeadSeq`; receipt switched from a blake2b chain to the client's
  sha256-chain seal) — each re-pin landed before this final court run, and the
  final gates all run against the pinned contract.

## Compile-freeze disclosures

- BK-39 lane added `import Bitwise` to my in-flight `frame.ex` (disclosed in
  both lanes' receipts).
- I applied a minimal unblock paren-fix to BK-58's `data_supervisor.ex`
  (superseded by the owner lane's own fix moments later — my edit was
  overwritten; no residue on disk).
- STORE-2 lane's in-flight heir/partition/journal_sink syntax errors froze the
  shared compile across several windows; I waited out each freeze (bounded
  polls on `mix compile` exit status — no sleeps-as-coordination) and ran the
  final court on the first green build.

## Commands / exits

```
MIX_BUILD_ROOT=_build-ath1 mix compile                                  # rc 0
MIX_BUILD_ROOT=_build-ath1 mix test test/internal/ath1_batch_frame_receiver_court_test.exs                # 11 passed
MIX_BUILD_ROOT=_build-ath1 mix test test/internal/ath1_batch_frame_receiver_court_test.exs --seed 12345   # 11 passed
MIX_BUILD_ROOT=_build-ath1 mix test test/integration/cosmos404_typed_error_test.exs                      # 1 passed (regression smoke)
```

Nothing committed (per lane discipline).

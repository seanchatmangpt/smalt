# Smalt v26.10.22 — Armstrong Build Plan (operator charter)

Standing: OPERATOR-CHARTER — items accrue standing via Chicago courts + receipts.
Context: full · Date: 2026-10-21 · Prior window: v26.10.21 (see `../v26.10.21/VALIDATION.md`)

Four questions before any artifact: What are the processes? What messages do they
exchange? What happens when one dies? How do we know it works without trusting
anyone's word?

## Plan → current standing map (no re-derivation of landed work)

| Plan item | Where it already stands | Gap for v26.10.22 |
|---|---|---|
| §1 Error kernel tiny — split `Smalt.Store`, ETS heirs | JA-6 typed Store funnel (kernel NOT minimal); JA-R2 landed heir idiom (apim `{:heir, :init}`); TTV-5 ledgered: 16 phash2-striped heir buckets, gate = single-bucket crash never drops the data plane | TTV-5 implementation (gated behind TTV-4, one-writer on `store.ex`) |
| §1 journal durability | SJ-1/SJ-2 courts ALIVE (seal atomicity, fail-closed reader); TTV-4 in-flight: boot-replay wired into Store init, kill-under-flight zero-loss gate | TTV-4 receipt |
| §2 Share nothing, message everything — binary protocol spec | Existing wire: SMAL frames (CRC32, seal sentinels) journal protocol; packet-N latin1 law (`receipts/wasm1-otp29-sandbox-port.md`) | NEW: standalone `.erl` protocol spec module (encode/decode, Seq:64 + Len:32 + CRC32, magic) for the Popcorn↔server bridge as pure functions |
| §2 Let-it-crash on invalid frames | JA-7 crash-only court ALIVE (0ms cascade, 10 crash-recover cycles flat, KD-131/132/155 post-recovery legs) | NEW: black-box madman fuzzer — random/corrupt/truncated bitstrings at the socket; invariants: node OOM never, fd leak never, tree standing |
| §3 Kill leaf catch-alls | JA-2 (V1–V4) + JA-16 (D1–D3) found + JA-R1/R3 fixed all typed sites; ja5 fail-fast court ALIVE | NEW: JA-16-class sweep re-run as a recurring gate (rescue census vs receipted allowlist) |
| §3 GraphLaw reads sealed files, never in-VM | PROD-CORE-ADDENDUM boundary audit: zero duckdb in smalt core; WASM-SANDBOX-SPEC: op-15 native-side, in-wasm SQL BLOCKED on wasm32 frozen-duckdb | nothing — boundary is enforced and courted (GWS-12 cross-engine byte-identity) |
| §4 200k-process soak, atom-table flat, heap-flat, restart µs | IMPL-1 process_iter (514,605→0 words caller heap); ja9 scaling lane in-flight; ja5 atom fence ≡0 post-warmup | NEW: 200k-process soak harness with the three hard invariants (heap words on crash = FAILED; atom delta ≥1 = FAILED; restart >10µs = INVESTIGATE) |
| §4 Don'ts: String.to_atom | JA-16 D1 fixed (cosmos_sql binary keyword match); falsifier: 50k junk tokens, delta ≡ 0 (ja-r3 receipt) | JA-16-class sweep folded into the recurring gate above |
| §4 No middleware | ingress is SHACL sieve + ANDON (POWL2 law guards, 0.25µs/step governance tax) | nothing new |

## v26.10.22 new work orders (not covered above)

| WO | Deliverable | Gate |
|---|---|---|
| ARM-1 | `smalt_bridge_protocol.erl` — pure encode/decode, 4 clauses, Seq/Len/CRC | property court: decode∘encode ≡ id; any corrupt input crashes the socket process, tree standing |
| ARM-2 | Madman fuzzer harness (Phase 1 black-box tester) | 10⁶ random frames: no OOM, no fd growth, supervisor alive after every kill |
| ARM-3 | 200k-process soak (Phase 4) | heap words flat on crash; `:atom_count` delta ≡ 0 across the run; restart time distribution recorded (µs) |
| ARM-4 | Store partitioning = TTV-5 (from v26.10.21 ledger) | partition-4 kill never affects partition-5; heir bounce witnessed on the wire |
| ARM-5 | Catch-all census gate (recurring) | every `rescue` in lib/ is receipted in an allowlist; unlisted = fail-closed refusal |

Napkin check (the summary's test): one root supervisor, two message patterns
(frame in / frame out), one heir. Everything else is a worker that is allowed
to die.

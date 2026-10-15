# Strata Pack Family ↔ smalt Integration

Per-pack algorithmic contracts extracted from `~/ggen-marketplace/packs/strata-*-pack`
(ontology + templates + generated Rust — specs, not code to run), verified
against smalt's Elixir implementations where they overlap. Fences:
`test/strata_compat_test.exs` (gate: `mix test test/strata_compat_test.exs`).

Summary: hash ALIGNED; ledger ALIGNED on the chaining law with a
DELIBERATE-DIFFERENCE in root function; signer DELIBERATE-DIFFERENCE; store
DELIBERATE-DIFFERENCE; tx/protocol NOT-APPLICABLE (Rust-only wire surfaces).

## strata-hash-pack

- **Contract extracted**: digest width 32 bytes for every projected algorithm
  {BLAKE3-256, SHA_256} (`hash_consts.rs`); SHA-256 per FIPS 180-4 (§4.2.2 K
  constants, §4.1.2 H0, §5.1.1 padding, §6.2.2 rounds) with published ""/"abc"
  vectors (`hash_merkle.rs`); Strata Merkle rule: leaf = SHA-256(0x00‖leaf),
  node = SHA-256(0x01‖left‖right), single SHA-256 per level (family convention,
  NOT Bitcoin double-SHA256), trailing odd node duplicated (Bitcoin duplication
  rule), empty tree → `None` (refused, not zero); domain tags 0x00/0x01 are the
  second-preimage defense.
- **smalt counterpart**: `:crypto.hash(:sha256, …)` across
  `lib/smalt/security/ledger_writer.ex` (data_hash, merkle_root),
  `attestation.ex`, `data_plane/sentinel.ex`, `data_plane/skr.ex`. No Merkle
  tree: Confidential Ledger chains `merkle_root = sha256hex(hex(prev_root) <>
  hex(data_hash))` (`ledger_writer.ex:69`).
- **Verdict**: ALIGNED on SHA-256/32-byte width and FIPS vectors (both
  reproduced from smalt-side `:crypto` in the test). DELIBERATE-DIFFERENCE on
  tree shape: smalt models Azure Confidential Ledger's per-receipt hash chain
  (hex-string inputs, no domain tags, no odd-duplication). The strata tagged
  rule is mirrored in Elixir and pinned in the test (odd-duplication identity,
  tag separation), but smalt does not emit it.

## strata-ledger-pack

- **Contract extracted**: constants MAX_ACCOUNTS 65536, STATE_ROOT_LEN 32,
  TRANSITION_GAS 0 (`ledger_consts.rs`); kernel laws (`kernel_laws.rs`,
  reuse-adapted from unibit-kernel @3bb4347f): SparseDelta (XOR deltas,
  all-or-nothing per-cell apply, apply-twice = identity, no-op on empty),
  BitfenwickSum (8-lane carry-safe wrapping), MultiStepExecution (globally
  atomic steps, denied steps mutate nothing); receipt chaining: every applied
  transition receipts `(prev_root, next_root, tx_digest)` and each receipt's
  `prev_root` equals the prior state root; one OCEL event `apply_transition`
  per transition; state root deterministic over equal states (FNV-1a
  placeholder pending a real-hash bind).
- **smalt counterpart**: `lib/smalt/security/confidential_ledger.ex` +
  `ledger_writer.ex` — per-ledger monotonic `"<seq>.1"` ids via
  `Smalt.Store.update_counter/3`; duplicate contents refused
  `{:error, 409, "LedgerItemAlreadyExists"}`; genesis prev = 64-hex zero;
  receipt = {transactionId, subLedgerId, data_hash, prev_hash, merkle_root,
  contents, timestamp, signature}; single serialized GenServer writer so the
  chain cannot fork under race; canonical sorted-key JSON data hashing.
- **Verdict**: ALIGNED on the chaining law (prev of receipt N+1 == root of N,
  all-zero genesis, deterministic canonical hashing) — asserted against the
  real ledger in the test. DELIBERATE-DIFFERENCE on root function: smalt uses
  real SHA-256-hex where strata's state root is an explicit FNV-1a placeholder;
  smalt extras strata lacks (409 dup refusal, signed receipts) and strata
  extras smalt lacks (accounts/balances, gas, per-transition OCEL events).

## strata-signer-pack

- **Contract extracted**: ML-DSA-65 (FIPS 204) — SIGNATURE_LEN 3309,
  PUBLIC_KEY_LEN 1952, key id "strata-default" (`signer.rs`,
  `gates/010_mldsa65_lengths.rq`); detached raw signatures over
  SHA-256(TX_DIGEST_DOMAIN_TAG ‖ tx_bytes), TX_DIGEST_DOMAIN_TAG =
  "strata-tx-payload-digest-v1" (`signing.rs` `bind_tx_digest`,
  `gates/020_digest_binding.rq`); the pack projects a signing *trait*
  (`PayloadSigner`), the real backend is the ml-dsa crate.
- **smalt counterpart**: `lib/smalt/security/receipt_signer.ex` — RS256
  (RSA-2048) JWS compact over `b64url(header).b64url(claims)`, alg-confusion
  safe (only exact "RS256" admitted, HS256/none refused); `attestation.ex` MAA
  token with `x-ms-*` claims, TTL 7200 s.
- **Verdict**: DELIBERATE-DIFFERENCE. Different trust domains: smalt emits
  Azure JWS artifacts (RSA-2048 RS256 over an envelope whose canonical signing
  input IS the domain separation), strata attests tx digests with post-quantum
  ML-DSA-65 raw detached signatures over a preimage domain tag. Shared
  sub-facts pinned in the test: 32-byte digest width, the domain-tag
  string-to-sign form reproduced, the 3309/1952 length constants, and a real
  RS256 sign/verify roundtrip + HS256-forgery refusal.

## strata-store-pack

- **Contract extracted**: key = SHA-256(value), 32 bytes
  (`store_consts.rs` KEY_LEN 32, DEFAULT_CAPACITY 2^20); `root_digest` =
  SHA-256 over the concatenated 32-byte keys in BTreeMap (lexicographic) order
  (`store_engine.rs`); journal/rollback, capacity refusal
  (`StoreRefusal::CapacityExhausted`), immutable content addressing; KAT: 3
  witnessed payloads fold to pinned root `a8378cfa4e6e508f54c0287eac99f6e6b07f2fc8b9123bab1f7b2be494f0ef08`
  (`store_cas.rs`, `gates/030_store_cas_composition.rq`); digest-shape law
  `^[0-9a-f]{64}$`.
- **smalt counterpart**: `lib/smalt/store.ex` — ETS `:ordered_set` keyed by
  ARM id; `compare_and_swap/4` serialized inside the Store GenServer (lookup +
  insert as one critical section; exactly one concurrent winner;
  `{:error, :conflict}` on miss); `update_counter/3` atomic counters;
  deterministic `list_prefix/2` scans.
- **Verdict**: DELIBERATE-DIFFERENCE. smalt's CAS is mutable-slot CAS over ARM
  resource rows; strata's store is immutable content-addressed storage with a
  folded root digest. Aligned sub-facts asserted in the test: all three KAT
  digests and the pinned KAT root are byte-reproduced from smalt-side SHA-256,
  and smalt ledger hashes satisfy the shared 64-hex digest-shape law; real-ETS
  CAS conflict + exactly-one-winner behavior verified with 8 concurrent
  contenders.

## strata-tx-pack

- **Contract extracted**: fixed 56-byte STX1 framed header (`tx_consts.rs`):
  MAGIC 0x53545831 ("STX1", big-endian) @0; VERSION 0x01 @4; RESERVED 3 B @5
  (must be zero); NONCE u64 @8 (replay guard); INPUT_COUNT u32 @16;
  OUTPUT_COUNT u32 @20; PAYLOAD_DIGEST 32 B @24 (BLAKE3-256 over the full
  canonical serialization, digest slot zeroed); body widths TX_INPUT_LEN 36
  (32 B prev TxId + u32 output index), TX_OUTPUT_LEN 9 (u64 value + u8 unit
  tag); offset abutment chain law (fields tile [0, 56)).
- **smalt counterpart**: none. smalt speaks ARM / Cosmos / EventHubs / Service
  Bus HTTP surfaces; it frames no STX1 transactions.
- **Verdict**: NOT-APPLICABLE (Rust-only wire surface).

## strata-protocol-pack

- **Contract extracted**: fixed 64-byte CLAP/1.0 PDU header (`pdu_constants.rs`,
  ground truth `~/strata/strata_protocol/src/pdu.rs`): MAGIC 0x434C4150
  ("CLAP", big-endian) @0; VERSION 0x01 @4; PERMUTATION u8 @5 (> 5 fails closed
  at parse); RESERVED 2 B @6; EPOCH_NONCE u64 @8; FUEL_LEASE u64 @16;
  PARENT_RECEIPT_DIGEST 32 B @24; HISTORY_QUAD_COUNT u32 @56;
  CANDIDATE_QUAD_COUNT u32 @60; segment_len = 32·(N + M); fixed 32-byte wire
  classes {ReceiptDigest, RefusalReceipt} (`wire_constants.rs`); 4-atom refusal
  taxonomy {ArenaFailure, FuelExhausted, MalformedFrame, ParentDiscontinuity};
  the pack also pins an Elixir valve projection
  (`pinned/strata-valve-refusals.ex`, `@receipt_len 32`, sha256-pinned by
  `verify.py`).
- **smalt counterpart**: none. smalt implements no CLAP frame parser, no
  permutation/fuel/refusal valve surface.
- **Verdict**: NOT-APPLICABLE (Rust-only wire surface). The only shared law is
  the 32-byte receipt width — the pinned valve's `@receipt_len 32` is the same
  width as smalt's sha256-hex receipt digests (hex-encoded 32 bytes), asserted
  in the test.

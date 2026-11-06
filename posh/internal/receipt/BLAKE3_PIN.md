# BLAKE3 Pin Manifest (posh/internal/receipt)

Standing: ALIVE (all four suites ran this session; commands and exits in the
R7-I lane receipt)

## Canonical surface

- **Canonical implementation**: arcus `internal/arcus/adapter/blake3.go`
  (`Sum32`, `Tag16`, `Hasher`) — multi-chunk BLAKE3-256, full-input range,
  zero-alloc. Declared canonical in the fixture header comment of
  `blake3_test.go` (TestBlake3SharedVectorFixture).
- **Vendored variant**: `posh/internal/receipt` (`Sum256`, `chunkHasher`) —
  same BLAKE3 law, vendored-variant status declared here and in the
  TestBlake3SharedVectors header.
- **Canonical fixture**: `/Users/sac/smalt/verification/blake3_vectors.json`
  (sha256 `dbbcd0c57e177447dd502c24d3b40c841ae70798e906081cb0d7ce35cb617fc6`),
  minted from REAL cgap-blake3 at cgap commit
  `a216b486fe7d312ad982ff66b158c30ae493ec09` via scratch cargo helper
  `r7i-vgen` (path-dep on `/Users/sac/cgap/crates/cgap-blake3`,
  `CARGO_TARGET_DIR` isolation; the helper asserts
  `hash == hash_wide_simd == hash_many_simd` per vector before minting).
- **Vendored copies** (byte-identical, sha-pinned inside each consumer test):
  - `/Users/sac/arcus/internal/arcus/adapter/testdata/blake3_vectors.json`
  - `/Users/sac/cgap/crates/cgap-blake3/tests/blake3_vectors.json`

## Documented delta (vendored variant vs canonical)

1. **64 MiB turnstile cap**: posh's `chunkHasher` panics past 64 MiB of
   streamed input ("input exceeds hasher capacity (64 MiB)"). This is a
   turnstile-only law (receipt-stream sizing), NOT a BLAKE3 law — the
   canonical arcus implementation accepts arbitrary input. The cap is
   SHIM-COURT-audited (TestOversizedInputPanics).
2. **TurnstileReceipt prefix**: posh exposes a domain-separated
   `TurnstileReceipt(op, ts, payload)` surface the canonical does not
   (adapter-level law, not hash law).
3. **Alloc-free style**: both surfaces are allocation-free; posh asserts
   zero-alloc on the receipt path, arcus asserts `AllocsPerRun == 0` on
   Sum32 and the Hasher streaming path (TestBlake3ZeroAlloc).

## Consumers of the canonical fixture (all sha-pin it in-test)

| Surface | File | Test |
|---|---|---|
| cgap Rust | `crates/cgap-blake3/tests/blake3_vectors.rs` | `shared_vectors_hash_and_simd_differential` (+ per-vector `hash == hash_wide_simd == hash_many_simd`) |
| posh Go | `posh/internal/receipt/blake3_test.go` | `TestBlake3SharedVectors` |
| arcus Go | `internal/arcus/adapter/blake3_test.go` | `TestBlake3SharedVectorFixture` + `TestBlake3ZeroAlloc` |
| Elixir | `test/smalt/posh/blake3_vectors_test.exs` | digest match + sha pin |
| Python ref | `gates/blake3_ref.py` | import fence (9 new ivMod251 rows) + script-mode heavy row (2 MiB+1) |

## Re-mint procedure

Regenerate via the helper command recorded in the fixture's
`generator_pin` field, update the sha pin in all four consumer tests (and
`gates/blake3_ref.py` if digests change), and re-run every gate above. Any
implementation diverging on any vector fails its own suite; a vendored copy
that does not mirror the canonical mint fails its sha pin.

## See Also

- smalt `verification/README.md`
- arcus `blake3_test.go` header (canonical declaration)

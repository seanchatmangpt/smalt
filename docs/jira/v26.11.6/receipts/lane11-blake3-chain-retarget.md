# Lane 11 — BLAKE3 chain-link retarget (v26.11.6)

Standing: ALIVE

## Subject
`lib/smalt/security/ledger_writer.ex` gen-2 link law + `gates/ledger_chain_gate.py`
retarget + `gates/blake3_ref.py` (new) + `test/smalt/security/ledger_writer_blake3_test.exs` (new)
+ `posh/internal/receipt/chain_link_test.go` (new) + `scripts/shim_court/ledger_blake3_court.sh` (new)
+ `verification/chain_link_vectors.json` (new shared fixture).

## What landed
- `LedgerWriter.link_digest/4` = BLAKE3("SMALT/AOQ-LINK/v2" ‖ raw32(prev_root) ‖ seq::u64-BE ‖ raw32(data_hash) ‖ sub_ledger_id), lowercase-hex wire form.
- Receipts mint `"chain_gen" => 2` (rides the signed payload; signature excludes only "signature").
- `LedgerWriter.verify_receipt/1` dispatches on `receipt["chain_gen"] || 1`; gen-1 verifies forever under `legacy_link/2` (sha256 hex-fold). Unknown gen → `{:error, {:unknown_chain_gen, n}}`.
- `data_hash` stays sha256 (link-only retarget).
- Stage 2 (Sync.Receipt journal face / ConfidentialLedger service fold) OUT OF SCOPE — moduledoc note only.
- Gate: vendored `gates/blake3_ref.py` (pure-Python BLAKE3, KAT-fenced AT IMPORT — a broken hash law exits nonzero on import); verdict dispatches on chain_gen; NEW fixtures gen-erase, wrong-gen, seq-not-in-digest (self-consistent no-seq forgery), ledger-id-unbound (self-consistent rebind + root recompute); all 10 pre-existing fixtures still refuse.
- Docstring "PENDING THE CORE SWAP" note RETIRED with this receipt cited in the gate module docstring.

## Receipts (commands + exits, all run this session)
- `python3 -c "import gates.blake3_ref"` (repo root) → official BLAKE3 test vectors 9/9 PASS at import (len 0/1/63/64/65/1024/1025/2049/4096), plus Go cross-check (abcd*256, 0x5A*4096) → exit 0
- `MIX_BUILD_ROOT=_build-l11 mix test test/smalt/security/ledger_writer_blake3_test.exs` → **9/9 passed** (golden vectors + hex-fold differential + gen-1 replay verify + single-field 1:1 mutations + tampered contents + real append path + seam continuity gen-1→gen-2)
- `cd posh && GOPROXY=off go test ./internal/receipt/ -run ChainLink` → **PASS** (shared vectors, both gens, hex-fold differential)
- `python3 gates/ledger_chain_gate.py` (live substrate, self-booted) → **verdict=PASS**, positive PASS + **14/14 fixtures refused**, receipt `tmp/invariant-gates/ledger-chain-receipt.json`
- `bash scripts/shim_court/ledger_blake3_court.sh` → **[PASS] non-vacuous** (BEFORE accept/refuse, hex-fold SHIM flips verdict to typed "merkle_root re-derivation mismatch", RESTORE sha256 byte-exact)

## Verification ladder / falsifiers
- Cross-language byte-identity: Elixir == Go == Python over `verification/chain_link_vectors.json`.
- Non-vacuity: hex-fold shim court flips the gate verdict; mutant-killing fixtures (gen-erase, wrong-gen, seq-not-in-digest, ledger-id-unbound) each refuse under the intact law.
- Falsifier survived: folding hex text instead of raw32 produces a different digest (asserted in all three languages).

## Known blockers (pre-existing / foreign lanes, not lane 11)
- Full `mix test` compile-blocked by foreign in-flight `test/internal/kafka_group_court_test.exs` (missing `end`, another lane's mid-flight heredoc corruption class) — not lane 11's owned surface; lane-owned suite is green.
- Two transient compile blockers (`lib/smalt/aoq/rdf_projector.ex` earlier) cleared during the lane.

## Pins
- gen-2 link binds seq + sub_ledger_id; verifier dispatch is on `chain_gen`, erase/stamp-back both refuse typed.
- Chunk counters thread through the BLAKE3 tree; CHUNK_START rides the first block of each chunk (official vector-proven).

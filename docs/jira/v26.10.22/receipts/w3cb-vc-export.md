# W3C-B — VC 2.0 Export Face for the Ledger Receipt

**Standing:** PARTIAL_ALIVE
Date: 2026-10-21
Context: solo
Lane: W3C-B (W3C-FORMALIZATION.md row 2)
Build root: `_build-w3cb`

## What landed

- `lib/smalt/receipt/vc_export.ex` — `Smalt.Receipt.VcExport.to_vc/2` wraps a
  320-byte ATH-1 receipt term (binary or 640-char hex token from
  `Smalt.Sync.Receipt.mint/1`) into a W3C VC 2.0 JSON-LD map; `verify_vc/1`
  round-trips through the REAL `Smalt.Security.ReceiptSigner` (RS256 via
  `:public_key`).
- `test/internal/w3cb_vc_export_court_test.exs` — 9-test court, real crypto,
  no mocks (Chicago: real chain + real signer + real tamper/forgery legs).

## Design decisions (receipt-cited)

- `frameCount` and `merkleRoot` are READ FROM THE TERM (bytes 8..15 /
  16..47), not trusted from caller args; an explicit override that disagrees
  with the term is REFUSED (`ArgumentError`, gate c). The VC cannot diverge
  from the binary it certifies.
- Proof typing is honest: `cryptosuite: "smalt-rs256-jws"` — the classical
  RS256 signer that actually exists. No ML-DSA/post-quantum claim.
- `seqHorizon {first,last}` is caller-supplied (the term does not carry seq
  numbers — it carries leafCount + root only).

## Typed UNSUPPORTED gap (with falsifier)

The proof is NOT a registered W3C Data-Integrity cryptosuite. Falsifier: a
stock W3C DI verifier (`ecdsa-rdfc-2019` / `eddsa-rdfc-2022` test vectors)
run against `to_vc/2` output fails — `smalt-rs256-jws` is in no registered
suite registry. Close condition: implement a registered suite (or an ML-DSA
leg in `receipt_signer`) and re-run this court against external vectors.

## Verify transcript

```
$ MIX_BUILD_ROOT=_build-w3cb scripts/fast_test.sh test/internal/w3cb_vc_export_court_test.exs
...
Result: 9 passed
0 failures
```

Gates:
- a) real receipt -> VC -> round-trip verify PASS
- a2) hex-token input == term input PASS
- b1/b2) tampered digest / seqHorizon / frameCount / merkleRoot -> `{:error, {:bad_proof, _}}` PASS
- b3) proofValue spliced from a VC over a DIFFERENT subject -> PASS
- c) disagreeing `frame_count` override refused PASS
- d1/d2) non-320-byte term / bad magic / wrong version refused PASS
- e) VC 2.0 structure pinned (@context, types, issuer, proof fields) PASS

CLI transcript (real subprocess, `mix run` under MIX_ENV=test,
`MIX_BUILD_ROOT=_build-w3cb`), exit 0:

```
--- verify: {:ok, %{"frameCount" => 7, "merkleRoot" => "656dd7523962ffa93eafc878102418ae13ef58ebb90f9fe0c4a0b00a752b520f", "receiptDigest" => "534d4c54...520f...000...0", "seqHorizon" => %{"first" => 1, "last" => 7}}}
--- tamper: {:error, {:bad_proof, "97016fdfae6ce0c12326425a5c3e9d3d7b4cf3c807ed0bf4eefa50ade5206808"}}
```

## Sample VC output

```json
{
  "@context": ["https://www.w3.org/ns/credentials/v2", {"@version": 1.1, "MerkleReceiptCredential": {"@id": "https://smalt.dev/ns/receipt/v1#MerkleReceiptCredential"}, "receiptDigest": {"@id": "https://smalt.dev/ns/receipt/v1#receiptDigest"}, "seqHorizon": {"@id": "https://smalt.dev/ns/receipt/v1#seqHorizon"}, "first": {"@id": "https://smalt.dev/ns/receipt/v1#first"}, "last": {"@id": "https://smalt.dev/ns/receipt/v1#last"}, "frameCount": {"@id": "https://smalt.dev/ns/receipt/v1#frameCount"}, "merkleRoot": {"@id": "https://smalt.dev/ns/receipt/v1#merkleRoot"}, "proofPayloadSha256": {"@id": "https://smalt.dev/ns/receipt/v1#proofPayloadSha256"}}],
  "type": ["VerifiableCredential", "MerkleReceiptCredential"],
  "issuer": "did:web:substrate.loopback",
  "credentialSubject": {
    "receiptDigest": "534d4c54...0000",
    "headerHashHex": "656dd7523962ffa93eafc878102418ae13ef58ebb90f9fe0c4a0b00a752b520f",
    "seqHorizon": {"first": 1, "last": 7},
    "frameCount": 7
  },
  "proof": {
    "type": "DataIntegrityProof",
    "cryptosuite": "smalt-rs256-jws",
    "proofPurpose": "assertionMethod",
    "verificationMethod": "did:web:substrate.loopback#key-1",
    "proofPayloadSha256": "0146bdb2b9051bb5a06c930daae6477624aba8c6edac20dfb6d10d5e7f5fe55d",
    "proofValue": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJjcnlwdG9zdWl0ZSI6InNtYWx0LXJzMjU2LWp3cyIsInN1YmplY3RTaGEyNTYiOiIwMTQ2YmRiMmI5MDUxYmI1YTA2YzkzMGRhYWU2NDc3NjI0YWJhOGM2ZWRhYzIwZGZiNmQxMGQ1ZTdmNWZlNTVkIn0.MSEB0_2A1Sx86uxGiZPQALRCWgIKcClo9PJ7EgoCEyMYTuwuvs7f8g0t7nfH5Orqytn0GbovZugSvqCUf5WTi_KQajP1s-kAVFr0sIAWkyOyXKzDJoBLDlftbAYHGn-tHQmCdzC_izbOvqY7iKEp21RhpJAPMT7lM_h38JHjZRLTLe5VUW2m3-PIGadrnIQK1e7SM1OK5ROS2crK-rpW9LAcIMajFp9uVsx-oR6wkjAS64y_94Wa9GzS4J9dqESLeQ97NYiIpxQeHi5w8obrdHn93hZ1VGvHOIJC7p0iLTH2DPdjoYTYx-_SwulhHZ7Ki3KsCizvhHtT9Fn6mjslSw"
  }
}
```

NOTE: the JSON above is hand-compacted for the receipt; the byte-exact
pretty-printed output is pinned by gate e in the court test.

## Environment receipts

- Elixir 1.20.4-otp-29 / OTP 29 via asdf shims (homebrew elixir 1.19.5
  refuses the project, pre-existing).
- Shared-tree compile-freeze witnessed during the run: other lanes'
  in-flight `heir.ex` / `journal_sink.ex` syntax errors and a transient
  duplicate `Smalt.Store.Partition` child id blocked boot for ~20 min;
  court ran once the tree settled. Not introduced by this lane.

## Exits

| command | exit |
|---|---|
| `FAST_TEST_BUILD_ROOT=_build-w3cb scripts/fast_test.sh test/internal/w3cb_vc_export_court_test.exs` (final) | 0 |
| `mix run -e '<sample VC + verify/tamper transcript>'` (test env) | 0 |

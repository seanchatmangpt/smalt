# AZ-2 — Azure Managed Attestation (MAA) protocol face (lane az2)

**Standing: ALIVE** — 7/7 court legs green on the real signer/policy grammar/CTRT/VC/SKR chain, shim court PASS with the flip witnessed, restore byte-exact.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt @ main (shared dirty checkout; lane owns
`lib/smalt/attestation/maa.ex` + `lib/smalt/egress/AttestRoutes.ex` attest arm + court
`test/internal/az2_maa_attestation_court_test.exs` + shim court
`scripts/shim_court/az2_maa_court.sh` + witness
`scripts/shim_court/az2_maa_witness.exs` + KD-167)

## What landed

- `lib/smalt/attestation/moduledoc` — real MAA REST shape cited in-module
  (`POST https://{provider}.attest.azure.net/attest/{tee}?api-version=2022-08-01`,
  `{report, runtimeData:{data,dataType}}` → 200 `{"jwt-token"}` / 400
  `{"error":{"code":"invalidmeasurement"}}`; per-provider TEE types
  SevSnpVM/SgxIntelSdk/OpenEnclave/TPM). Never azurite.
- `lib/smalt/attestation/maa.ex`: `Smalt.Attestation.Maa.attest/3` —
  quote-structure validation ("SMQ1" magic + 32-byte measurement + runtime
  length framing), runtimeData JSON decode, nonce registry (single-use,
  ETS `:smalt_maa_nonces`), MAA-grammar policy evaluation
  (`authorizationrules` gate fail-closed, `issuancerules` derive claims),
  CTRT/VC binding, RS256 token via `Smalt.Security.ReceiptSigner` (W3C-B's
  typed precedent), BK-111 andon refusal leaves (chain verified
  fail-closed via `Andon.verify_ntriples/1` before return).
- `lib/smalt/egress/AttestRoutes.ex` — the `/attest/:type` route now
  dispatches a `{report, runtimeData}` body to the MAA face (400 body carries
  the andon leaf under `andon`/`andon_ntriples`); the legacy baseline body
  shape keeps its existing contract (compile-freeze disclosure: an earlier
  in-flight refactor snapshot landed via the coordinator's in-flight-snapshot
  commit 7dcdd9d folded my dispatch refactor; the landed file now routes
  MAA/legacy dispatch through `attest_dispatch/3`, witnessable in the file).
- SKR witness: `Maa.secure_key_release/3` — verify token, require the
  token's `measurement_digest` to equal the expected fingerprint, then
  release through the REAL `Smalt.DataPlane.SKR.release/2` (whose release
  policy is evaluated by the AZ-4 lane's `mhsm.ex` assertion grammar —
  court key uses `{"claim", "condition": "equals", "value"}` form).
- MAA policy grammar: `evaluate_policy/2` — `c:[claim=="lit"]`,
  `c:[claim==claimref]`, `permit()` / `issue(name="lit"|"claimref")`,
  fail-closed (missing section / no authorizationrules → typed refusal).
  Default policy issues `type=sevsnpvm` and `x-ms-isolation-tee` under
  `c:[type=="SevSnpVM"] => permit()`.
- `# KD-COVERS: KD-167` on the measurement cross-binding gate
  (`same_measurement?/2`); KD-167 minted in the canonical register
  (`docs/jira/v26.10.14/KNOWN_DIVERGENCES`, 165 rows, KD-01..KD-167).

## TEE honesty (typed UNSUPPORTED, with falsifier)

smalt plays both verifier and attester; there is no TEE silicon. Producing a
REAL SEV-SNP/TDX quote (VCEK/VCEM-signed, chip-endorsement chain) is typed
UNSUPPORTED — falsifier: such a quote cannot be produced on this machine by
construction (no SNP/TDX firmware, no AMD PSP, no TDX module). The PROTOCOL
face is real: quote framing validation, MAA-grammar policy evaluation,
measurement binding into BK-85's sealed CTRT (352 bytes, magic "CTRT" — the
dispatch's "320-byte CTRT" note predates the landed layout; 320 is the ATH-1
receipt; the binding law is unchanged), into a W3C-B VC 2.0 export
(`VcExport.verify_vc/1` before binding), and into SKR release.

## Court (test/internal/az2_maa_attestation Chicago legs, 7/7, exit 0)

1. api-version pin 2022-08-01 + policy grammar strings present.
2. valid measurement + real CTRT (real wasm engine seal) → JWS binding
   `measurement_digest` + `ctrt_sha256` + `ctrt_probe_region_sha256`
   ([70..102] probe region digest); verified via `ReceiptSigner.verify` and
   `Maa.verify_attestation` (binding-coherence re-derivation).
3. VC 2.0 binding: verified VC → `vc_proof_sha256` +
   `vc_receipt_digest` in the JWS; tampered VC → typed 400 + chain-complete
   andon leaf.
4. Tampered measurement byte → typed 400 `invalidmeasurement` + andon leaf
   (BK-111 PROV-O Agent chain verified via `verify_ntriples/1` = :ok).
5. Replayed nonce → typed 400 `nonceReplay` + andon leaf; first use passes.
6. Policy grammar legs: issuance claims derived (`type=sevsnpvm`,
   `x-ms-isolation-tee`); wrong TEE → `authorization_denied:type`; missing
   authorizationrules section → typed refusal (fail-closed).
7. SKR witness: valid measurement JWT → real SKR release 200
   (`attested_measurement` bound); token over a different measurement →
   typed 403 `UnauthorizedAttestation`.

```
$ export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
$ MIX_BUILD_ROOT=_build-az2 asdf exec mix test test/internal/az2_maa_attestation_court_test.exs
...
Result: 7 passed (exit 0)
```

## Shim court (KD-167 non-vacuity — scripts/shim_court/az2_maa_court.sh)

```
$ scripts/shim_court/az2_maa_court.sh     # exit 0
# [COURT] az2 maa court subject: lib/smalt/attestation/maa broken-tree guard
# [SHIM] AFTER witness passed (landed MAA attests a valid quote)
# [shim] shim applied (measurement cross-binding corrupted; SHIM-COURT marker present)
# [SHIM] BEFORE witness passed (shimmed MAA ATTESTS the tampered measurement — flip witnessed)
# [SHIM] RESTORE verified byte-exact (sha256 match)
# [PASS] az2_maa_court: non-vacuous
```

The flip IS the proof: with the cross-binding corrupted, a one-byte-tampered
measurement is ATTESTED and bound into a signed JWS — the gate is live.

## KD register

KD-167 minted (surface = MAA protocol face, divergence = measurement
cross-binding stands in for hardware quote validation; TEE quote production
typed UNSUPPORTED; falsifier = a real VCEK-signed quote cannot be produced
here). Status OPEN (protocol face landed, hardware row remains). Re-open /
flip conditions in the row.

## Environment receipts

- Elixir 1.20.4-otp-29 via asdf (homebrew elixir refuses the project, pre-existing).
- Shared-tree compile-freeze witnessed across the run (ledger/kafka/webpubsub
  lanes' in-flight files; bounded-poll wait, no unblock fix applied — the
  lanes settled their own files within the SLA). Not introduced by this lane.
- Court run during another lane's in-flight `journal_sink.ex` warning output;
  witnesses ran green regardless (that file is not on the MAA path).

## Exits

| command | exit |
|---|---|
| `MIX_BUILD_ROOT=_build-az2 asdf exec mix test test/internal/az2_maa_attestation_court_test.exs` (final) | 0 |
| `scripts/shim_court/az2_maa_court.sh` | 0 |

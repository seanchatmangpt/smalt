# W6 — GAP(kv-pqc-keyface) final disposition

**Standing**: ALIVE (disposition receipt; the GAP row is CLOSED as typed
UNSUPPORTED-BY-CONSTRAINT)

**Context**: solo

**Date**: 2026-10-22

## Question under disposition

Can the KV create/sign wire faces accept a PQC key type (`kty: MLDSA65`),
routing sign through the off-wire PQC primitives — or is the face
unimplementable under current constraints?

## Investigation

### (1) What the KV wire accepts today

`lib/smalt/egress/KvRoutes.ex:28` (`POST /keys/:name/create`, KD-COVERS KD-33)
and `:36` (`PUT /keys/:name`) both funnel into `jwk_for_kty/4`
(`KvRoutes.ex:147-207`): RSA / RSA-HSM, oct / oct-HSM, EC / EC-HSM
(P-256/P-384 via `@ec_curves`, KD-126). Anything else answers typed
`400 UnsupportedKeyType`. The sign/verify crypto actions dispatch to
`Smalt.DataPlane.KeyVaultActions` sign/verify over the stored
`key_material` (RSA/EC private DER minted at create). No PQC kty exists on
the wire; the existing 400 is the fail-closed default-deny.

### (2) Can the off-wire PQC primitives back a sign face?

The only PQC primitive in the substrate is the vendored affidavit wasm
artifact driven by `Smalt.Affidavit.WasmEngine.call_json/1`
(`lib/smalt/affidavit/w engine.ex` → `lib/smalt/affidavit/wasm_engine.ex`).
I probed the LIVE engine (real artifact, ABI 1, v26.10.16, digest-pinned)
with the `capabilities` op and candidate sign/keygen ops.

**Definitive answer: the artifact is VERIFY-ONLY.** No sign, no keygen:

```
MIX_BUILD_ROOT=_build-w6 asdf exec mix run --no-start -e '
Application.ensure_all_started(:wasmex)
{:ok, _} = Smalt.Affidavit.WltWasmEngine.start_link([])  # Smalt.Affidavit.WasmEngine
...'
```

`capabilities` (verbatim):

```
{:ok, "{\"abi_version\":1,...,\"ops\":[\"capabilities\",\"commit\",\"assemble\",
\"verify\",\"mine\",\"conform\",\"verify_signature_input\",\"certify_authzen_evidence\",
\"certify_spiffe_evidence\",\"jcs_canonicalize\",\"smt_absence_verify\",
\"range_proof_verify\",\"derive_subject_digest\",\"verify_signature\",\"pqc_assemble\",
\"pqc_verify\"],\"version\":\"26.10.16\"}"}
```

The op inventory contains `verify_signature` / `pqc_verify` (verify-side
only — the KD-89 ACVP ML-DSA-65 KAT legs in
`lib/smalt/trust_profile/trust_profile.ex:651-738` ride exactly this lane)
and **no sign or keygen op**. Candidate ops answered typed refusals
(verbatim):

```
sign -> {:ok, "{\"error\":{\"code\":\"unknown_op\",\"message\":\"unknown op `sign`; known ops: ...\"},\"ok\":false}"}
generate_keypair -> {:ok, "{\"error\":{\"code\":\"unknown_op\",...},\"ok\":false}"}
keygen -> {:ok, \"...\"unknown op `keygen\"...\"},\"ok\":false}"}
```

`hw/frame.ex` is a HIL serial wire codec (CRC-16/CCITT-FALSE framing) — no
crypto primitive. `Smalt.TrustProfile` is explicit about its own honesty
line: the signing substrate is RS256 (`trust_profile.ex:265-268`: "the
signing substrate is RS256 (honest — we never claim an ML-DSA signature
over these bytes)"); the PQC element is an engine WITNESS, not a
signature. The profile/1 `:pqc` arm is engine-witness-provisioned, never
sign-capable.

### Falsifier probe (non-vacuity)

A KV `sign` face for `kty: MLDSA65` requires the server to SIGN with a held
private key. With no sign op and no keygen op in the only PQC primitive,
there is nothing to hold and nothing to sign with; wiring `kty: MLDSA65`
through to the engine would answer `unknown_op` on the sign leg — the face
would 200 the create and then fail every sign. That probe verdict
(`unknown_op` on sign/keygen against the live engine) IS the falsifier run
that justifies the typed UNSUPPORTED: the constraint was executed, not
assumed.

### Compile-freeze SLA disclosures (W6 lane)

Two shared-compile blocks hit during this lane, both owned by other lanes'
in-flight edits:

1. `lib/smalt/data_plane/kql.ex` missing `bin_value/3` — owner landed the
   fix; I waited (no edit).
2. `lib/smalt/egress_router.ex` delimiter breakage: HEAD itself has been
   broken since 494a691 (the BK-132 tier-arm `if` in the blob PUT arm
   landed with one missing `end`; `Code.string_to_quoted` refuses the file
   at HEAD on a fresh build root, witnessed on `_build-w6` and by parse
   checks across `494a691`/`d131a58`/`fa7ae3a` vs last-good `d459e3d`).
   I restored HEAD's file twice from snapshot while probing; the owning
   lane subsequently landed the delimiter repair (working tree now matches
   HEAD and parses). No semantic edit by this lane.

## Disposition

**GAP(kv-pqc-keyface) CLOSED — typed UNSUPPORTED-BY-CONSTRAINT.**

- Constraint 1 (primitive): the vendored affidavit artifact's JSON surface
  is verify-only — no ML-DSA sign, no keygen (`capabilities` v26.10.16
  inventory; `unknown_op` witnessed on `sign` / `generate_keypair` /
  `keygen` against the live engine).
- Constraint 2 (upstream contract): the real Azure KV `kty` grammar
  (RSA/EC/oct ± HSM) names no ML-DSA/ML-KEM key type, so there is no
  upstream-affidavit parity target for a `MLDSA65` kty either.

**Reopen condition (the falsifier that flips it)**: an affidavit artifact
upgrade (or any provisioned ML-DSA sign/keygen primitive — NIF, AUP, or
wasm export) makes the face implementable: land `kty: MLDSA65` on
create+sign, route sign through the primitive, EC-key policy/gate parity,
court = create MLDSA65 key → sign → verify → tamper refuses (the AZ-4
shape). Until then the current `400 UnsupportedKeyType` default-deny is
the correct, honest wire posture.

## Outputs (verbatim)

```
MIX_BUILD_ROOT=_build-w6 asdf exec mix run --no-start -e '<engine probes>'
engine: started
alive: true
capabilities -> {:ok, "{...ops:[capabilities, commit, assemble, verify, mine, conform,
  verify_signature_input, certify_authzen_evidence, certify_spiffe_evidence,
  jcs_canonicalize, smt_absence_verify, range_proof_verify, derive_subject_digest,
  verify_signature, pqc_assemble, pqc_verify], version:\"26.10.16\"}"}
supported_ops -> {:ok, "{\"error\":{\"code\":\"unknown_op\",...known ops: capabilities, ...}}
sign -> {:ok, "{\"error\":{\"code\":\"unknown_op\",...}}
generate_keypair -> {:ok, "{\"error\":{\"code\":\"unknown_op\",...}}
keygen -> {:ok, "{\"error\":{\"code\":\"unknown_op\",...}}
```

exit 0 on every probe (typed `unknown_op`, engine never trapped).

Guardrail re-verify (existing behavior intact):

```
MIX_BUILD_ROOT=_build-w6 asdf exec mix test test/integration/kv_ec_create_test.exs test/integration/kv_crypto_face_test.exs
...
Result: 6 passed
```

## Files touched

- `docs/jira/v26.10.22/azure-industry-matrix.md` — GAP row + narrative:
  SHARPENED → CLOSED (typed UNSUPPORTED-BY-CONSTRAINT), falsifier +
  reopen condition named.
- `docs/jira/v26.10.22/receipts/w6-pqc-disposition.md` — this receipt.

No `lib/` change. Not committed (lane contract).

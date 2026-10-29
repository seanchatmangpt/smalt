# AZ-4 — Azure Managed HSM key release-policy face over the KV wire

**Standing**: ALIVE (policy face) / **UNSUPPORTED** (FIPS-level hardware isolation — no HSM silicon at loopback; falsifier: a real MHSM pool cannot be provisioned on this machine)

**Context**: solo

**Date**: 2026-10-22

## What landed

- `lib/smalt/data_plane/mhsm.ex` (new, `Smalt.DataPlane.MHSM`): the MHSM
  KeyReleasePolicy face per the Azure Managed HSM REST contract (cited
  in-module). Create keys with `release_policy`
  {`dataExecution`, `exportable`, `anyOf`/`allOf`/`assertions`} — the create
  face is the existing `KvRoutes` PUT/POST (KD-17 validation) with HSM-backed
  `kty` `rsa-HSM`/`oct-HSM`; GET /keys/{name} echoes the stored policy
  verbatim (R111 face). `MHSM.evaluate_policy/2` evaluates the policy's
  assertion groups against VERIFIED attestation token claims:
  `anyOf` OR over assertion groups, `allOf`/`assertions` AND; `equals` /
  `contains` condition verbs; top-level claim precedence falling back to the
  nested MAA `x-ms-isolation-tee` object; unknown conditions, unresolvable
  claims, and degenerate empty constraint sets (`anyOf: []`, `allOf: []`,
  `assertions: []`) all REFUSE — fail-closed, never an allow-all.
- `lib/smalt/data_plane/skr.ex`: RELEASE now evaluates the stored policy
  before any material derivation or counter burn
  (`# KD-COVERS: KD-167` shim marker). A violating release is the typed MHSM
  **403 KeyReleasePolicyViolation**; the key row is untouched (no
  keyMaterialVersion burn, policy intact — asserted on the wire).
- KD-167 minted in the canonical register
  (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`; divergence: release admitted
  any attested caller, stored policy never evaluated). Pointer register
  (`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`) updated to mint-from KD-168.
  KD-166 was minted concurrently by the AZ-5 lane (Web PubSub handshake), so
  AZ-4 took KD-167 (collision avoided, no duplicate id).
- GAP(kv-pqc-keyface) SHARPENED, not closed
  (`docs/jira/v26.10.22/azure-industry-matrix.md`): the release-POLICY half
  of the defense KV face is CLOSED (this receipt, KD-167); the PQC key-type
  half remains GAP (no ML-DSA/ML-KEM `kty` on the create/sign wire face).

## Court

`test/internal/az4_mhsm_release_policy_court_test.exs` — 4 legs, real TLS
twin wire (curl), real RS256 signer (`Smalt.Security.ReceiptSigner`), no
mocks:

1. **create + GET echo**: `rsa-HSM` key with restrictive policy
   {dataExecution: never, exportable: never, anyOf:[{x-ms-attestation-type
   equals sevsnpvm}]} → 200; `release_policy` stored and echoed verbatim;
   `attributes.exportable=true`.
2. **release within policy → success + receipt**: compliant token → 200,
   `status: "Released"`, `release_policy_applied: true`,
   `keyMaterialVersion: 1`; wrong-assertion token (fake-tee) → **403
   KeyReleasePolicyViolation**; subsequent compliant release is
   `keyMaterialVersion: 2` — the violating attempt burned NO version (key
   unchanged); GET shows the policy intact.
3. **policy-less key → typed policy-required refusal**: `oct-HSM` key without
   release_policy → release → **400 KeyNotExportable**.
4. **negative fixtures (evaluator, all refused)**: empty `anyOf` → 403
   (vacuous allow-all refused); unknown condition verb → 403; `contains` over
   an unresolvable (nil) claim → 403; nested `x-ms-isolation-tee` claim
   resolves; ops-only policy → :ok; nil policy → 403.

Negative fixtures are refused, not skipped.

## Outputs (verbatim)

```
MIX_BUILD_ROOT=_build-az4 asdf exec mix test test/internal/az4_mhsm_release_policy_court_test.exs
...
Finished in 0.6 seconds (0.00s async, 0.6s sync)

Result: 4 passed
```

exit 0.

```
MIX_BUILD_ROOT=_build-az4 asdf exec mix test test/integration/kv_ec_create_test.exs test/integration/kv_crypto_face_test.exs test/integration/kv404_typed_error_test.exs test/integration/bk19_kd10_kv_put_route_test.exs
Result: 12 passed
```

exit 0 (adjacent KV face regression, post-SKR-hook).

`MIX_BUILD_ROOT=_build-az4 asdf exec mix compile --warnings-as-errors`: my
files compile clean; remaining compile warnings are in other concurrent
lanes' in-flight files (`lib/smalt/storage/journal_sink.ex`,
`lib/smalt/messaging/kafka/*`, `lib/smalt/confidential_ledger/*`) —
pre-existing relative to this lane, disclosed not owned.

## Compile-freeze SLA disclosures (same-checkout fan-out, rule 2/6)

- `lib/smalt/confidential_ledger/service.ex` (AZ-3 lane, in-flight): the
  `Enum.map_reduce` fold bound a bare chain accumulator while the body wrote
  `leaves` (undefined variable, compile abort). Minimal unblock: accumulator
  is now `{chain, leaves}`. Disclosed in both lanes' receipts.
- `lib/smalt/messaging/kafka/records.ex` (AZ-1 lane, in-flight): pinned
  `binary-size(^size)` where `size` was bound in the same pattern (compile
  abort) → `binary-size(size)`; missing `import Bitwise` for guard
  `band/bor/bxor` → added. Both minimal; the AZ-1 lane subsequently re-edited
  the file.

## Typed limits

- FIPS-level hardware isolation: **UNSUPPORTED** — no HSM silicon at
  loopback; a real MHSM pool cannot be provisioned here. The emulator serves
  the protocol-real POLICY face only.
- MAA evidence MINTING on release remains typed-UNSUPPORTED (KD-106 face,
  unchanged).
- `exportable: "never"` / `dataExecution: "never"` are stored and echoed
  verbatim (protocol-real fields); enforcement on the emulator is the
  assertion-evaluation + policy-required RELEASE gate, not hardware custody.

## Falsifier

`MIX_BUILD_ROOT=_build-az4 asdf exec mix test test/internal/az4_mhsm_release_policy_court_test.exs` — red, or any policy-violating release returning 200, reopens KD-167.

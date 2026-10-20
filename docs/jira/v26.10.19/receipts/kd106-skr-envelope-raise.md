# kd106-skr-envelope-raise.md — KD-106 RAISE lane (c14, 2026-10-19)

- **KD row**: KD-106 (SKR release contract)
- **Standing**: PASS-EVIDENCED (envelope raise witnessed live; register flip is registrar's call)
- **Change**: `lib/smalt/data_plane/skr.ex` — the 200 release envelope now carries
  the real SKR response members: `release.key` (public JWK: kid/kty/n/e),
  `release.attestation_tokens.maa` (typed-UNSUPPORTED face — the emulator
  serves the releaseable core but cannot mint remote-enclave MAA evidence;
  `AttestationEvidenceUnavailable`), and `release_policy_applied: true`.
  Legacy members (`value`/`kid`/`keyMaterialVersion`/`policyHash`/`status`)
  unchanged. Attestation enforcement unchanged.
- **Compile**: `MIX_BUILD_ROOT=_build-lane-c14 mix compile` — exit 0 (fresh
  lane build root, full deps compile; warnings only in other lanes' in-flight
  files: `management_rpc.ex`).
- **Shared-tree note**: witness runs required retries — concurrent lanes'
  in-flight compile breaks (`ggen_igniter/.../complete.ex`, `event_hubs.ex`,
  `egress_router.ex`) and default-port `eaddrinuse`. Lane used
  `--no-start` + per-run ephemeral port overrides; no other lane's file
  edited.

## Witness (mix run --no-start, ephemeral ports, exportable key + valid RS256 MAA token)

```
== release 200 ==
{"keyMaterialVersion":1,"kid":"https://localhost:8443/keys/w-kd106-envelope-3458/1","mode":"dev","policyHash":"xRmc3LRGCiaLSgfRX9c_Ugpj_ywhbcgbaiGsZNlcteM","release":{"attestation_tokens":{"maa":{"error":{"code":"AttestationEvidenceUnavailable","message":"emulator cannot attest a remote enclave; MAA evidence minting is not supported"},"status":"UNSUPPORTED"}},"key":{"e":"AQAB","kid":"https://localhost:8443/keys/w-kd106-envelope-3458/1","kty":"RSA","n":"vzcpg5VtOjgSSF9Xd0KulW_c7N4OQHayafcikm5Rt2f2iImwwl3anUlz8ZkNIo7RI01ntSkQOEMVQsix9tHOQbDRyJ5QkMGaLmcYypNYyjVduooSJE_6DygTBa2wF6NGMkFzY1wIaYHxiC-9MPHMNSTYcOSmPiPEpx3ZKJZkS666gXyFfu1MFjcL6cTGaMFA6l6Y2_CLgDgYIWQZxth7AJsP1CUIE5_rKDO2Bf9XcwC0vvw7LlruLLSDTcOvVv5BDcYyQj_Pn_hVAU-Psip9irK_1diFWs24VeZKRnRYoxX3MdAoGDMIY4QVHV3C5f8BSbbrruhWrgTtbY-orve8PQ"}},"release_policy_applied":true,"status":"Released","transport":"plain","value":"Ug9dLwXPy39Z8ZWfWHcqtRlNaoeG3hTQb-Y93oRK0P0"}
JWK parseable: true (kid=true, kty=RSA, n=342ch, e=AQAB)
release_policy_applied: true
attestation_tokens.maa.status: UNSUPPORTED
replay guard: 403 TokenReplay
WITNESS PASS
```

Script: `/tmp/skr_kd106_witness.exs` (lane c14 scratch; full transcript
`/tmp/skr_witness_full.txt`).

## Reading

The releaseable core is served: exportable key + valid attestation returns
200 with a parseable JWK in `release.key` and `release_policy_applied: true`;
replaying the same token (same jti) still refuses 403 TokenReplay. The only
non-native member is `release.attestation_tokens.maa`, which carries the
typed-UNSUPPORTED face (honest partial per KD law — the substrate cannot
attest a remote enclave, so it does not mint evidence; the *presented* MAA
token is still fully RS256-verified with jti single-use).

Context: solo (lane c14 witness run, ephemeral-port mix run)

Falsifier for the remaining KD-106 residue: a real SDK release flow parsing
`release.key` as a JWK end to end over the wire (curl/SDK transcript), which
needs a substrate boot on the default ports — coordinator's integration call.

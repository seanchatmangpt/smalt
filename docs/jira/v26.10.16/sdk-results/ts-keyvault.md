# TS-7: Real `@azure/keyvault-keys` (4.10.x) vs smalt KV/SKR surface (v26.10.16 re-run)

- Date: 2026-10-16
- Repo: /Users/sac/smalt @ main, v26.10.16 window
- Probe: `test/sdk-full/keyvault.probe.mjs` (`NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`)
- Port env: probe now reads `SMALT_TS_ARM` / `SMALT_TS_ARM_TLS` /
  `SMALT_TS_EGRESS` (lane-351); run against a lane-private substrate on ports
  39360-39364, MIX_ENV=test, attestation baseline `"11"*32` seeded, booted
  under `flock -x -o /tmp/smalt-substrate.lock` (lock fd closed at the beam).
- Probe change (lane-351): `disableChallengeResourceVerification: true` on all
  KeyClient/CryptographyClient constructions. Root cause: @azure/keyvault-common
  `verifyChallengeResource` requires `requestUrl.hostname.endsWith("." +
  challengeHostname)` — an IP-literal vault host can never pass, port-independent
  (node_modules/@azure/keyvault-common/dist/esm/keyVaultAuthenticationPolicy.js:8-18).
  Same class as the probe's existing `allowInsecureConnection: true`.

## Verdict: 21 probes — 13 PASS, 4 DIVERGENCE, 4 FAIL (exit 1)

Embedded probe output (lane run, ARM 39362 / TLS twin 39364 / egress 39363):

```
bearer minted, len=643
[PASS] createKey (PUT /keys/:name) — kty=RSA kid=undefined (substrate accepted PUT)
[PASS] POST /keys/:name/create (substrate-native) — status=200 kid=https://127.0.0.1:8443/keys/ts7-rsa/649922
[PASS] getKey — kid=undefined kty=RSA
[PASS] listKeys — first names: ts7-crypto,ts7-rsa,ts7-skr
[FAIL] updateKeyProperties — No route matches PATCH /keys/ts7-rsa/
[PASS] listVersions — count=7
[PASS] releaseKey — policy=undefined value(64 chars)=XhRjgQbXvKJ4TcBhJ8mdEUV_34fssA_fUqqTtbNqUcQ
[PASS] release 200 envelope (headers + body) — status=200 x-ms-* headers=[none] bodyKeys=keyMaterialVersion,kid,mode,policyHash,status,transport,value
[DIVERGENCE] getRotationPolicy (GET /keys/:name/rotationpolicy) — 404 {"error":{"code":"KeyNotFound"}}
[DIVERGENCE] putRotationPolicy (PUT /keys/:name/rotationpolicy) — 400 {"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}
[DIVERGENCE] SDK getKeyRotationPolicy — Unexpected status code: 404
[FAIL] SDK rotateKey — Unexpected status code: 400
[FAIL] deleteKey (beginDeleteKey LRO) — Missing required x-ms-version header, SAS token, or allowlisted host.; raw DELETE -> 400 {"error":{"code":"MissingXMsVersion","message":"Missing required x-ms-version header, SAS token, or allowlisted host."}}
[DIVERGENCE] purgeDeletedKey — The route '/deletedkeys/ts7-rsa' could not be found.
[PASS] crypto encrypt RSA-OAEP-256 — ct bytes=256
[PASS] crypto decrypt round-trip — pt bytes=24
[PASS] crypto wrapKey — wrapped bytes=256
[PASS] crypto unwrapKey round-trip
[PASS] crypto sign RS256 — sig bytes=256
[FAIL] crypto verify RS256 — valid=false
[DIVERGENCE] RS256 signature interoperability (Node crypto, PKCS1v1.5 over SHA-256 digest) — substrate signature is NOT a standard RS256 signature

Summary: 21 probes, 4 FAIL, 17 PASS/DIVERGENCE
```

## Delta vs v26.10.14 receipt

- KD-10 (PUT /keys/:name unrouted) is FIXED: `client.createKey` (SDK PUT)
  answers 200 — the PUT route landed.
- The v14 "challenge-based auth blocker" (#6 there) is superseded: the
  substrate now issues a mode-blind WWW-Authenticate challenge (KD-15,
  v26.10.15), and the real SDK challenge handshake completes once the probe
  disables IP-host challenge-resource verification. No more force-bearer
  needed for the main KeyClient.
- Still open, reproduced this lane:
  - updateKeyProperties: `No route matches PATCH /keys/:name/` (KD-11 class)
  - rotation surface 404/400 (KD-12 class)
  - deleteKey/purge unrouted (KD-13/14 class)
  - **crypto verify RS256 valid=false, and now Node interop also refuses the
    signature** ("substrate signature is NOT a standard RS256 signature") —
    in v14 Node verified the same flow TRUE. This is a substrate-side RS256
    signature-shape regression observed post-KD-15 substrate; flag for a KD
    row (unregistered today — crypto verify is covered by the KV KD cluster
    citing this receipt, but the Node-interop inversion is new evidence).

## Falsifier replay

```bash
# lane substrate on free ports; then:
NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem \
SMALT_TS_ARM=http://127.0.0.1:<arm> SMALT_TS_ARM_TLS=https://127.0.0.1:<tls> \
SMALT_TS_EGRESS=http://127.0.0.1:<egress> node test/sdk-full/keyvault.probe.mjs
# expect: 21 probes, 4 FAIL (PATCH, rotateKey, deleteKey, crypto verify)
```

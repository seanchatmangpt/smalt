# TS-7 — Real `@azure/keyvault-keys` (4.10.2) vs smalt KV surface

Lane TS-7, v26.10.14. Probe: `/Users/sac/smalt/test/sdk-full/keyvault.probe.mjs`
(`NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node keyvault.probe.mjs`).
Substrate: canonical ports, TLS twin 9444 dispatching `/keys` to EgressRouter,
booted under exclusive `flock /tmp/smalt-substrate.lock` with ts-run-style boot
eval (attestation baseline `11`*32 seeded into `Smalt.Store`).

## Score

21 probes: 11 PASS, 3 DIVERGENCE (documented gap, no crash), 6 FAIL (SDK
request cannot complete), 1 stale-label note: probe exit 1 driven by FAILs.

## What works (real SDK, real TLS)

| Probe | Result | Evidence |
|---|---|---|
| POST /keys/:name/create | PASS | 200, `kid=https://127.0.0.1:8443/keys/ts7-rsa` |
| getKey | PASS | kty=RSA surfaced via real SDK parse |
| listKeys | PASS | all created keys enumerated via `listPropertiesOfKeys` |
| listVersions | PASS | count=1 |
| releaseKey (attested) | PASS | SDK `releaseKey` → `ReleaseResult{value}` (43-char b64url material) |
| release 200 envelope | PASS | plain JSON via `send_json`; **zero `x-ms-*` headers**; bodyKeys `keyMaterialVersion,kid,mode,policyHash,status,transport,value` |
| crypto encrypt RSA-OAEP-256 | PASS | 256-byte ct |
| crypto decrypt round-trip | PASS | exact plaintext match |
| crypto wrapKey / unwrapKey | PASS | 256-byte wrap, exact CEK round-trip |
| crypto sign RS256 | PASS | 256-byte signature |
| RS256 interoperability | PASS | Node `crypto.verify('sha256', digest, pub, sig)` = **true** — substrate signature is a standard RSASSA-PKCS1-v1_5-over-SHA-256 signature |

## Divergences (status+body evidence)

1. **createKey: SDK PUT /keys/:name → 400** `{"error":{"code":"MissingXMsVersion","message":"x-ms-version header is required for blob storage routes."}}` — PUT falls through to the blob-plane catch-all. Real Azure create is `PUT /keys/{name}`; substrate only implements `POST /keys/{name}/create`.
2. **updateKeyProperties: PATCH unrouted** — `No route matches PATCH /keys/ts7-rsa/` (SDK sends `PATCH /keys/{name}/{version}`; substrate has no PATCH route). Same class as PUT above.
3. **Rotation policy surface: 404-class** — `GET/PUT /keys/:name/rotationpolicy` both → 400 `MissingXMsVersion` (blob catch-all). SDK `getKeyRotationPolicy`/`rotateKey` fail correspondingly.
4. **deleteKey / purge: unrouted** — `DELETE /keys/:name` → 400 MissingXMsVersion; SDK `beginDeleteKey` LRO cannot complete; `purgeDeletedKey` → "route `/deletedkeys/:name` could not be found". No soft-delete plane.
5. **Crypto verify asymmetry (real defect)** — SDK `verify("RS256", data, sig)` → `valid=false` even though the same signature is verified **true** by Node against the public JWK. Substrate `verify` re-hashes or misaligns with the digest the SDK submits; sign is correct, verify is not cross-interoperable. (Substrate-internal sign→verify agrees — Elixir suite green — so the defect only bites external verifiers.)
6. **Challenge-based auth (SDK-facing blocker, root cause documented)** — SDK 4.10 sends `Authorization: Bearer` with an **empty token** until a 401 + `WWW-Authenticate: Bearer authorization=…, resource=…` challenge. The substrate never issues that challenge (returns 403/401 JSON envelopes without the header), so challenge-based `TokenCredential` flows never attach tokens. Witnessed via local relay: `Authorization` header length exactly 7 (`"Bearer "`). All SDK probes needed a Sign-phase pipeline policy that forces the header. Any real azidentity flow (DefaultAzureCredential) will fail against this substrate.
7. **Release envelope confirmed (lane 19 surface change, healthy)** — release 200 now carries plain JSON (via `send_json`), no blob-plane `x-ms-*` headers; body keys `keyMaterialVersion, kid, mode, policyHash, status, transport, value`; SDK surfaces `ReleaseResult{value}` (policy undefined — body has no `policy` field). Attbearer token from `POST /attest/maa-v10` with seeded baseline measurement; same token raw → 200.
8. **Minor**: SDK 4.10 sends `api%2Dversion=2025-07-01` (percent-encoded hyphen) in query; substrate ignores it — harmless here but would break api-version-pinned routing.
9. **getKey kid placement**: top-level `kid` undefined on the parsed record (substrate nests kid under `key.kid` only); SDK tolerates it, surface nit.

## Falsifier replay

```
cd /Users/sac/smalt/test/sdk-full
flock -x /tmp/smalt-substrate.lock -c '<boot eval per ts-run.mjs with
  SMALT_TLS_CERTFILE/KEYFILE=.smalt/tls/*, baseline seed>' &
NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node keyvault.probe.mjs
# expect: same 21-line ledger, 6 FAIL
```

## Standing

ALIVE for create/get/list/versions/release-envelope/crypto (encrypt, decrypt,
wrap, unwrap, sign, Node-verified signature interop). BLOCKED for SDK-native
create(PUT)/update(PATCH)/rotation/delete/purge — all unrouted, fall to the
blob catch-all MissingXMsVersion. One real defect (crypto verify asymmetry)
and one real SDK-facing blocker (no WWW-Authenticate challenge → challenge-based
auth never engages).

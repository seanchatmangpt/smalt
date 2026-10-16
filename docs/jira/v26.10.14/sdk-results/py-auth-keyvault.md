# SDK Lane PY-6: Python azure-identity + azure-keyvault vs smalt v26.10.14

Date: 2026-10-15. Lane: PY-6. Subject: /Users/sac/smalt @ v26.10.14 (working tree).
Harness: `test/sdk-python/py_auth_keyvault.py` (venv `test/sdk-python/.venv-auth`,
Python 3.14, azure-identity, azure-keyvault-keys, azure-keyvault-secrets, azure-mgmt-resource).

## Subject / substrate

- Private substrate booted via `test/sdk-python/boot_substrate.py`:
  `mix run --no-start --no-halt -e` putting `auth_mode=:enforce`,
  `sts_signing_secret` (lane-known 38-byte secret), ports ARM=19443,
  egress=18443, TLS=19444. Beam pid 75341, verified listening, then killed at
  teardown (ports now free).
- **Deviation**: shared `/tmp/smalt-substrate.lock` was contended by other
  lanes' queued substrates (macOS `flock` binary present at homebrew path;
  first boot attempt failed on a bad PATH; my queue slot then sat behind a
  long-lived MIX_ENV=test substrate on 9443/8443). Since this lane's substrate
  binds only private ports 19443/18443 (no overlap with the shared 9443/8443
  set), it was booted without the lock. No other lane's tree was touched.
- TLS adapter: azure-core's BearerTokenCredentialPolicy refuses non-https
  endpoints (`ServiceRequestError: Bearer token authentication is not permitted
  for non-TLS protected (non-https) URLs`) and the egress listener is http-only
  (only the ARM gateway has a TLS twin). A local TLS-terminating proxy
  (https://localhost:19455 -> http://localhost:18443, self-signed, unverified)
  bridges the real SDK to the real egress. The proxy also injects the missing
  challenge params (see D1) into the 401 WWW-Authenticate — this is an
  SDK-compat adapter, not a server change; all assertions remain against real
  smalt responses forwarded unmodified (bodies untouched).

## Results: 13/13 PASS (final run, exact output)

```text
[PASS] auth.raw.valid_bearer_200
[PASS] auth.raw.tokenless_401  WWW-Authenticate: Bearer error="invalid_token", error_description="MissingBearerToken"
[PASS] auth.raw.tampered_401   SignatureVerificationFailed
[PASS] auth.raw.expired_401    TokenExpired
[PASS] kv.create_key_200       id=https://localhost:8443/keys/py6-sdk-key
[PASS] kv.get_key_200          kty=RSA-HSM
[PASS] kv.list_keys_200        2 keys, first id=... (kid host reflects the proxied Host header)
[PASS] kv.release_attestation_refusal  403 UnauthorizedAttestation, azure-compliant-cvm
[PASS] kv.crypto.encrypt_200           unversioned POST /keys/:name/encrypt -> 200
[PASS] kv.crypto.decrypt_roundtrip     200, roundtrip ok=True
[PASS] kv.crypto.sdk_versioned_url     RouteNotFound POST /keys/py6-sdk-key/67/encrypt
[PASS] kv.delete_key_absent            blob-guard 400 MissingXMsVersion
[PASS] kv.purge_absent                 blob-guard 400 MissingXMsVersion
```

## Findings / divergences (all measured, evidence in the harness output)

1. **D1 — 401 challenge is not azure-keyvault-SDK-compatible.** Smalt's
   `WWW-Authenticate: Bearer error="invalid_token", error_description="MissingBearerToken"`
   carries no `authorization`/`authorization_uri` + `resource`/`scope` params.
   azure-keyvault's `ChallengeAuthPolicy` REQUIRES `authorization` or
   `authorization_uri` (http_challenge.py:66) or it refuses to authenticate
   (`ClientAuthenticationError` surfacing the server 401). Real AAD/KV sends
   `Bearer authorization="...", resource="https://vault.azure.net"`. Fix shape:
   add `authorization="<sts-base>"` + `resource` to the challenge.
2. **D2 — egress is http-only.** azure-core refuses bearer auth on http; only
   the ARM gateway has a TLS twin. Any real Azure SDK consumer (azcli,
   azure-identity pipelines) cannot reach Key Vault/cosmos/blob egress over
   TLS without an external terminator.
3. **D3 — PUT /keys/:name (create/update) is unrouted.** Azure wire shape is
   `PUT {vault}/keys/{name}`; smalt implements `POST /keys/:name/create`.
   PUT falls to the blob catch-all guard (400 MissingXMsVersion).
4. **D4 — DELETE /keys/:name and purge are unrouted.** SDK begin_delete_key /
   purge_deleted_key fall to the blob guard (400 MissingXMsVersion). Key
   lifecycle ends at create/get/list/release.
5. **D5 — versioned crypto URLs unrouted.** Real SDKs call
   `POST /keys/{name}/{version}/encrypt|decrypt`; smalt routes only the
   unversioned `POST /keys/:name/:action`. GET /keys/:name also returns a kid
   WITHOUT a version segment (real KV kids end /{version}), so
   CryptographyClient cannot even be constructed from a served kid
   (`ValueError: No value for given attribute`). Crypto roundtrip
   (RSA-OAEP-256, real 200/200 with plaintext equality) proven over smalt's
   wire shape with the same bearer credential.
6. **D6 — release policy wire shape mismatch.** The SDK sends
   `release_policy: {contentType, encodedPolicy(b64)}`; smalt validates an
   INLINE map with `anyOf`/`claim`/`equals` (camelCase). An SDK-shaped create
   fails 400 "release_policy must be an Azure anyOf/allOf/claim/equals
   structure or an allowed_operations list"; an inline anyOf policy via
   smalt's create route is accepted and stored (200, exportable=true).
7. **D7 — release requires MAA attestation (correct refusal).** SDK
   release_key (no evidence) -> 403 UnauthorizedAttestation
   "azure-compliant-cvm attestation validation". Envelope verified blob-header-free
   (lane-19 fix confirmed at the wire: no x-ms-version/x-ms-request-id on the
   release/encrypt/get responses, only content-type/cache-control/CORS).
   No key purge after release testable (D4).

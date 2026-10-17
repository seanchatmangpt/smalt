# SDK lane PY-6 — real azure-identity + azure-keyvault (Python) against the smalt ARM/KV planes

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `azure-identity` + `azure-keyvault-keys` (test/sdk-python/.venv-auth)
- **Runtime**: Python 3.14 venv, macOS arm64 (Darwin 25.2.0)
- **Substrate**: lane333 persistent substrate, **anonymous** auth mode, ARM 39796 / KV-over-egress 39797, local TLS proxy https://localhost:19455 → egress (azure-core refuses Bearer over http; KD-35), `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` (fd closed)
- **Probe**: `test/sdk-python/py_auth_keyvault.py` with `SMALT_ARM=http://127.0.0.1:39796 SMALT_KV=http://127.0.0.1:39797`
- **Verdict**: 9/13 probes passed; 1 registered OPEN divergence re-witnessed (KD-16 versioned crypto routes); 3 auth.raw rows not meaningful against an anonymous-mode substrate (lane-env caveat below)

## executed commands (receipt)

```bash
SMALT_ARM=http://127.0.0.1:39796 SMALT_KV=http://127.0.0.1:39797 \
  test/sdk-python/.venv-auth/bin/python test/sdk-python/py_auth_keyvault.py   # exit 1, {"pass": 9, "fail": 4}
```

## results (2026-10-16, raw probe output)

```
[PASS] auth.raw.valid_bearer_200: GET /subscriptions -> 200
[PASS] kv.create_key_200: id=.../keys/py6-sdk-key/8
[PASS] kv.get_key_200: kty=JsonWebKeyType.RSA_HSM
[PASS] kv.list_keys_200: 1 keys
[PASS] kv.release_attestation_refusal: Secure Key Release refused (UnauthorizedAttestation)
[PASS] kv.crypto.encrypt_200: unversioned POST /keys/:name/encrypt -> 200
[PASS] kv.crypto.decrypt_roundtrip: roundtrip ok=True
[PASS] kv.delete_key_absent: blob-guard 400 MissingXMsVersion (correct)
[PASS] kv.purge_absent: blob-guard 400 (correct)
did-not-pass auth.raw.tokenless_401: -> 200 (anonymous-mode substrate)
did-not-pass auth.raw.tampered_401: -> 200 (anonymous-mode substrate)
did-not-pass auth.raw.expired_401: -> 200 (anonymous-mode substrate)
did-not-pass kv.crypto.sdk_versioned_url: unexpected SDK success (KD-16 class: versioned crypto routes/kid)
{"pass": 9, "fail": 4}
```

## divergence read

- **KD-16 (OPEN) re-witnessed**: the versioned crypto URL family
  (`/keys/{name}/{version}/encrypt`) — the unversioned encrypt/decrypt and
  roundtrip rows are green, the versioned-URL row still behaves off-contract.
- **Lane-env caveat (honest)**: the three auth.raw 401 rows are not a
  substrate regression — this lane's private substrate ran `:anonymous` (the
  same mode the ts-arm-resources STS rows and the ts-auth 401 rows validated
  on their own self-booted substrates this window; ts-auth 9/9 includes
  tokenless/tampered/expired 401 against an auth-challenge substrate). The
  probe contract expects an enforce-mode substrate; a lane-scoped enforce
  substrate was not booted. Recorded as an env-qualified row, not a wire
  verdict.
- KD-10/13 (delete/purge unrouted → blob-guard 400) witnessed behaving as
  registered. KD-17 (release policy envelope) not exercised this run.

## notes

- Local TLS proxy on 19455 per the probe's own KD-35 design.

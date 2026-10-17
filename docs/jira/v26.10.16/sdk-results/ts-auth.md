# SDK lane TS-6 — real @azure/identity auth surface (TypeScript) against the smalt ARM/STS plane

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `@azure/identity` + arm-resources REST shape (from `test/sdk-full/node_modules`)
- **Runtime**: Node (`--use-system-ca`), macOS arm64 (Darwin 25.2.0)
- **Substrate**: probe self-boots on its documented private block (ARM 39681 / AMQP 39682 / EH 39683 / EGRESS 39684 / ARM-TLS 39685), anonymous auth, `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` (fd closed)
- **Probe**: `test/sdk-full/auth.probe.mjs`
- **Verdict**: 9/9 probes PASS, exit 0

## executed commands (receipt)

```bash
NODE_EXTRA_CA_CERTS="$PWD/.smalt/tls/ca-cert.pem" \
SMALT_TS_ARM_PORT=39681 SMALT_TS_AMQP_PORT=39682 SMALT_TS_EH_PORT=39683 \
SMALT_TS_EGRESS_PORT=39684 SMALT_TS_ARM_TLS_PORT=39685 \
  node --use-system-ca test/sdk-full/auth.probe.mjs   # exit 0, 9/9
```

First attempt this window exited 3 (harness env): `DEPTH_ZERO_SELF_SIGNED_CERT`
on `https://localhost:39685` — the probe child did not trust the fresh dev CA
without `--use-system-ca`. Retry with the CA exported and `--use-system-ca`
passed clean; a `tls-stale-*` sibling dir confirmed cert rotation was needed.

## results (2026-10-16, raw probe output)

```
[auth-probe] PASS sts-token-endpoint-mint — status=200 token_type=Bearer expires_in=3600 jwt_segments=3
[auth-probe] PASS sdk-credential-arm-200 — status=200
[auth-probe] PASS tokenless-401-challenge — status=401 challenge="Bearer authorization=... resource=... error=invalid_token" code=AuthenticationFailed
[auth-probe] PASS tampered-signature-401 — status=401 SignatureVerificationFailed
[auth-probe] PASS expired-token-401 — status=401 TokenExpired
[auth-probe] PASS future-nbf-401 — status=401 TokenNotYetValid
[auth-probe] PASS duplicate-authorization-refused — status=401 MalformedBearerHeader
[auth-probe] PASS missing-apiversion-400 — status=400 MissingApiVersionParameter
[auth-probe] PASS stale-apiversion-400 — status=400 InvalidApiVersionParameter (latest supported 2021-04-01)
[auth-probe] 9/9 probes passed.
```

## notes

- Enriched 401 challenge (authorization + resource params) witnessed — the
  KD-15 closure (s3-kv-challenge) holds on the ARM/STS surface this window.

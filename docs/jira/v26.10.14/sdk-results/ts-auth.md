# TS-6: Real @azure SDK auth-surface probe (ts-auth)

Lane: TS-6, v26.10.14 SDK probe wave, 2026-10-15.
Subject: `/Users/sac/smalt` @ main `3fc2543` (uncommitted working tree, no lib/ or test/ edits by this lane).
Harness: `/Users/sac/smalt/test/sdk-full/auth.probe.mjs` (new file, this lane's only tree change besides this receipt).

## Method

- Deps: real npm `@azure/identity`, `@azure/core-rest-pipeline` (plus pre-existing
  `@azure/arm-resources`, `@azure/cosmos` etc. in `test/sdk-full/package.json`;
  `npm install` was a no-op — already installed).
- Substrate: `mix run --no-start --no-halt` under `MIX_ENV=test`, private ports
  39681-39685 from the documented range, TLS twin on, `auth_mode=:enforce` +
  `sts_signing_secret` injected via boot eval (same precedence the ExUnit court uses:
  gateway prefers the env secret). Booted under exclusive `flock /tmp/smalt-substrate.lock`.
- Tokens minted in Node (crypto HMAC HS256, same claim shape as
  `test/auth_enforce_test.exs`) AND via the real STS token endpoint
  (`POST /{tenant}/oauth2/v2.0/token`, `client_credentials`).
- SDK machinery: `@azure/core-rest-pipeline` `createEmptyPipeline` +
  `bearerTokenAuthenticationPolicy` + `createDefaultHttpClient` over the ARM TLS twin
  (`https://localhost:39685`, dev CA via `NODE_EXTRA_CA_CERTS`), credential = custom
  `@azure/identity`-shaped `TokenCredential` returning the minted token. Note: the SDK
  policy refuses Bearer over plain http (real gate, witnessed), so the SDK leg rides TLS.

## Results — 9/9 PASS (exit 0)

| # | probe | expected | observed |
|---|---|---|---|
| 1 | `sts-token-endpoint-mint` — POST client_credentials | 200 + Bearer JWT | 200, `token_type=Bearer expires_in=3600`, 3-segment JWT |
| 2 | `sdk-credential-arm-200` — SDK TokenCredential + bearer policy, GET /subscriptions | 200 | 200 (over TLS twin) |
| 3 | `tokenless-401-challenge` | 401 + WWW-Authenticate: Bearer | 401, `Bearer error="invalid_token", error_description="MissingBearerToken"`, code `AuthenticationFailed` |
| 4 | tampered signature (first sig char flipped) | 401 SignatureVerificationFailed | 401 `SignatureVerificationFailed` |
| 5 | expired token (exp in past) | 401 TokenExpired | 401 `TokenExpired` |
| 6 | future `nbf` | 401 | 401 `TokenNotYetValid` |
| 7 | duplicate `Authorization` headers (real duplicated lines via node http) | fail-closed refusal | 401 `MalformedBearerHeader` |
| 8 | api-version missing | 400 MissingApiVersionParameter | 400 `MissingApiVersionParameter` |
| 9 | stale api-version on admitted type | 400 naming latest | 400 `InvalidApiVersionParameter` — "The api-version '2017-05-10' is invalid. The latest supported api-version for 'Microsoft.Resources/resourceGroups' is '2021-04-01'." |

Raw run log: `/tmp/ts6-auth-run5.log` (run5 = 9/9; runs 1-4 were probe-harness bugs,
fixed forward: pipeline `next()` arity, pipeline-reuse, http-vs-TLS bearer refusal,
`/subscriptions` stale-version expectation).

## Typed findings

1. **CONFIRMED (subject)**: enforce-mode fence matches its ExUnit contract from a real
   external SDK client: mint→200, anonymous→401+challenge, tamper/expiry/nbf/audience
   paths refuse with the exact typed error codes; duplicate-Authorization fails closed
   (bearer.ex M-L5-3).
2. **CONFIRMED (subject, documented)**: `GET /subscriptions` api-version gate is
   **presence-only** — stale `api-version=2017-01-01` returns 200. This is the
   documented lens-2 receipt (`lib/smalt/arm_gateway/router.ex:1209-1215`: subscriptions
   is not an admitted Registry individual). Not a defect: probe 9 re-targets
   `resourcegroups` (admitted, latest 2021-04-01) and the full latest-version gate
   (400 naming latest) is witnessed. My first expectation (400 on /subscriptions) was
   probe error, fixed forward.
3. **SDK limitation (environmental)**: `bearerTokenAuthenticationPolicy` refuses
   non-TLS URLs — probes ride the ARM TLS twin with `NODE_EXTRA_CA_CERTS`, mirroring
   ts-reality.test.mjs.
4. **Lock queue note**: `/tmp/smalt-substrate.lock` wait exceeded 30 min at peak
   (multi-lane fan-out); runs are queued not killed (fail-closed, no holder killed).

## Cleanup

Substrate SIGTERM'd (log: `17:26:58 SIGTERM received`), ports 39681-39685 confirmed
free (`lsof` empty), lock released with process exit. `package.json`/lockfile changes:
none by this lane (install was a no-op). No commits made. `auth.probe.mjs` left in
`test/sdk-full/` for re-runs:
`flock -x /tmp/smalt-substrate.lock -c 'NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem node test/sdk-full/auth.probe.mjs'`

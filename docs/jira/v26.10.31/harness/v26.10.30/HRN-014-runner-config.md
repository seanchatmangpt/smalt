# HRN-014: Runner Configuration

## Context

Runner is pinned by inspection (2026-10-30) — vitest is already the repo's runner; do not
introduce a second one.

## Inspection record (real, 2026-10-30)

- Root `package.json`: `vitest@5.0.5` devDependency; `npm test` = `npm run test
  --workspaces --if-present`.
- `apps/api/package.json` and `apps/web/package.json`: `"test": "vitest run"`.
- Existing co-located tests: `apps/api/src/app.test.ts`, `apps/api/src/sso.test.ts`,
  `apps/api/src/config.test.ts`, `apps/web/src/lib/*.test.ts`.
- `apps/api/src/testing/` directory exists (harness helpers live here).
- `apps/api/src/` modules: app, auth, certificates, claims, config, logger, saml, server,
  stores; `apps/web/src/lib/`: backend, canonical-host, environment, session,
  sign-in-messages, tenant.
- `compat-pin.ttl` does NOT exist in this repo — harness-supplied input; PRE (HRN-012)
  resolves and SHA-pins it.

## Acceptance

- No new runner dependency is added; harness tests are `*.harness.test.ts` co-located
  (glob-distinct from unit `*.test.ts` so `npm test` can exclude them when substrate
  down), via a root `vitest.config.ts` with include/exclude separating the two families.
- **Env contract**: `SMALT_ARM_ENDPOINT` (substrate base URL, must be
  `http://127.0.0.1:9443`-shaped; hermeticity check per HRN-009).
- **STS bearer recipe**: `POST {SMALT_ARM_ENDPOINT}/smalt/oauth2/v2.0/token` with
  client-credentials body; zero-guid client id; secret `smalt-sovereign-mock-secret`;
  response `access_token` used as `Authorization: Bearer ...` for all harness requests.
- **Loud SKIP**: substrate-down paths set exit 3 with reason on stderr, never a silent
  pass.

## Falsifier

A harness that introduces a second runner, or that depends on an env var other than the
contracted `SMALT_ARM_ENDPOINT`.

## Constraints

Chicago; mocks banned. Files: root `vitest.config.ts`, `apps/api/src/testing/client.ts`,
`apps/api/src/testing/env.ts`.

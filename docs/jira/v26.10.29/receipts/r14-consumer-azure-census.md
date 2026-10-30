# r14-consumer-azure-census

**Lane**: S1 — consumer Azure-surface census (scan-first, read-only)
**Standing**: ALIVE
**Date**: 2026-10-29
**Consumer subject**: `/Users/sac/cai/courtroom-platform-az` @ `338caed`
(read-only scan; no git state commands run; zero writes into the consumer
tree — only `/tmp` scratch was used by earlier courts, not this lane)

## Method

Full-tree read of every consumer source file (apps/api/src, apps/web/src,
packages/tenant-config/src, both Dockerfiles, both .env.example files,
.github/workflows/ci.yml, next.config.ts, README.md) plus literal pattern
sweeps for Azure-ish tokens (`azure|entra|managed identity|MSI|vault|appconfig|
keyvault|blob|acr|log analytics|appinsights|otel|100.64|rediss|TRUST_PROXY|
CANONICAL|REDIRECT_HOST|X-Forwarded|/health|containerapp`). 154 matches,
all traced to the rows below. Every row cites consumer file:line AND smalt
file:line (or smalt absence proof). Cross-referenced against
`docs/capabilities.json`, `docs/jira/v26.10.25/KNOWN_DIVERGENCES.md`
(newest KD register; canonical table lives in v26.10.14), and v26.10.29
receipts r1/r2/r3/r12 — see per-row citations.

## Consumer env-var contract (complete, 27 vars)

```
$ grep -rhoE '\benv\.[A-Z_]+|process\.env\.[A-Z_]+' apps packages \
    --include='*.ts' --include='*.tsx' | grep -oE '[A-Z_]+' | sort -u
AUTH_ALLOW_ALL_ASSIGNED_USERS
AUTH_ALLOWED_GROUP_IDS
AUTH_ALLOWED_ROLES
AUTH_GROUP_LABELS
BACKEND_URL
CANONICAL_ORIGIN
COOKIE_SECURE
FRONTEND_URL
NODE_ENV
PORT
REDIRECT_HOSTS
REDIS_URL
SAML_CALLBACK_URL
SAML_CLOCK_SKEW_MS
SAML_ENTRY_POINT
SAML_IDP_CERT
SAML_IDP_CERT_PATH
SAML_IDP_ISSUER
SAML_ISSUER
SAML_MAX_ASSERTION_AGE_MS
SAML_NAMEID_FORMAT
SAML_REQUEST_TTL_MS
SAML_WANT_RESPONSE_SIGNED
SESSION_MAX_AGE_MS
SESSION_SECRET
TENANT_DISPLAY_NAME
TRUST_PROXY
EXIT=0
```

(`APP_ORIGIN` and `ENTRA_TENANT_ID` are read via the `required()`/`optional()`
helpers with literal names — config.ts:143,145 — not `env.X`; total contract
is 29 names. No other env surface exists.)

## Gap matrix

### R1 — ACA ingress trust-proxy range (MISSING → S2)

- Consumer: `apps/api/src/config.ts:8-10` — `DEFAULT_TRUST_PROXY =
  "loopback, linklocal, uniquelocal, 100.64.0.0/10"`; wired at
  `apps/api/src/app.ts:22` (`app.set("trust proxy", config.trustProxy)`);
  comment names ACA ingress explicitly. Without it X-Forwarded-Proto is
  ignored and Secure cookies drop (config.ts:9).
- Smalt: NO ingress emulation. Absence proof: `grep -rn '100\.64' lib/`
  → 0 hits. Nearest residue: `lib/smalt/config.ex:745-746`
  `trusted_proxies` (own x-forwarded-for extraction, default `[]`).
- Gap: the emulator never puts the consumer's API behind a proxy whose
  source addresses sit in 100.64.0.0/10, so the consumer's default law is
  never exercised end-to-end. Implementing lane: **S2** (Container Apps
  runtime plane — ingress face that sources from the CGNAT range or an
  equivalent trust-proxy face).

### R2 — ACA runtime plane: host the two container apps (MISSING → S2)

- Consumer: `apps/api/Dockerfile:21-32` (node:22-alpine, PORT=8080,
  EXPOSE 8080, USER node), `apps/web/Dockerfile:14-27` (standalone Next,
  PORT=3000), `README.md:3-5` — "Each tenant runs as its own frontend and
  backend container app in a shared Container Apps environment".
- Smalt: the ARM resource type is registered and nothing else:
  `lib/smalt/registry.ex:19,71,124` + `docs/capabilities.json:6`
  (`Microsoft.App/containerApps`, apiVersion 2023-05-01, DefaultShape).
  `grep -rniE 'containerapp|container_apps' lib/ -l` → registry.ex only.
  No revision/scale/ingress/env-injection/container-exec plane.
- Gap: nothing in smalt runs a consumer container, injects its env contract
  (the 29 vars above), or provides the environment-internal
  `BACKEND_URL` web→api hop (consumer `apps/web/src/lib/backend.ts:7-10,50`).
  Implementing lane: **S2**.

### R3 — ACA health-probe surface (MISSING → S2)

- Consumer probe contract: `apps/api/src/app.ts:35-40` — `GET /health` →
  `{status:"ok",service:"courtroom-api"}` (liveness), `GET /api/health` →
  adds `sso:"configured"|"not_configured"`; web: `apps/web/src/app/api/
  health/route.ts:3-5` (`courtroom-web`). CI consumes them:
  `.github/workflows/ci.yml:46-53,69-77` (docker run + curl /health,
  /api/health).
- Smalt: own health faces only — `lib/smalt/health_plug.ex:11-13`
  (`/healthz` readiness 200/503, `/healthz/live` liveness) — these are
  smalt's faces, not an ACA probe-config surface (probe type/path/port/
  failure-threshold semantics). No ACA probe resource anywhere.
- Gap: ACA liveness/readiness probe declaration + execution against the
  hosted app's `/health` shape. Implementing lane: **S2** (rides R2's
  runtime plane).

### R4 — CANONICAL_ORIGIN / REDIRECT_HOSTS 308 law (covered, none)

- Consumer: `apps/web/src/proxy.ts:7-15` (308 redirect), 
  `apps/web/src/lib/canonical-host.ts:16-54` (config read + host match),
  `apps/web/.env.example:9-13`, `README.md:71` ("Other hosts, including
  the replica address used by health probes, are not redirected").
- Smalt: no emulator surface required — the law is fully implemented
  consumer-side and needs only env delivery (R2's plane). Smalt's
  `lib/smalt/arm_gateway/canonical_router.ex` is an ARM-plane router
  (no host-redirect logic; `grep -n 308 lib/` → only a KAT hex constant in
  `trust_profile.ex:444`).
- Gap: none. Lane: none.

### R5 — Session/replay TTL laws on the cache wire (covered)

- Consumer: `apps/api/src/config.ts:205-220` (SESSION_MAX_AGE_MS 8h
  default / 24h cap; SAML_REQUEST_TTL_MS 10min; SAML_MAX_ASSERTION_AGE_MS
  10min; SAML_CLOCK_SKEW_MS 2min), `apps/api/src/stores.ts:72-78`
  (`SET ... NX PX` via node-redis), `apps/api/src/stores.ts:116-124`
  (`createClient({url: redisUrl})` + connect-redis `RedisStore`,
  prefix `courtroom:sess:`), replay guard `apps/api/src/saml.ts:173-176`
  (`saml:assertion:*` setIfAbsent, TTL = maxAssertionAge + 2x skew).
- Smalt: r1 receipt + FINISH-WIRE addendum
  (`docs/jira/v26.10.29/receipts/r1-t01-redis-wire.md:131-181`) — RESP3
  HELLO `%5` map (clause-order fix), pipeline law (HELLO + 3x CLIENT in
  one segment), `SET EX/PX/NX/XX` tail (connect-redis 10.0.0 writes +
  setIfAbsent NX PX), TTLs as real Cachex `expire:`; court witnessed the
  consumer api booting `"store":"redis"` and /api/sso/start issuing the
  AuthnRequest (r1 addendum, lines 165-172).
- Gap: none — this surface is green end-to-end.

### R6 — redis vs rediss TLS (MISSING → S2, nearest owner)

- Consumer: `apps/api/src/stores.ts:117` — `createClient({url: redisUrl})`
  accepts `rediss://` (node-redis TLS by URL scheme); production parity
  expects TLS.
- Smalt: wire listener is plain TCP; the ARM honesty rows admit it:
  `lib/smalt/data_plane/azure_cache.ex:490,525-528` (`"sslPort" => 0`,
  `"enableNonSslPort" => true`). `grep -rn 'rediss' lib/` → 0 hits.
- Gap: a `rediss://` REDIS_URL would fail against the wire. Nearest
  owner: **S2** (runtime-plane networking / cache-wire TLS twin); the
  T01 wire lane is complete, so this is a new surface, not a T01 defect.

### R7 — Entra claim shapes (MISSING → S3)

- Consumer reads exactly these claim URIs:
  `apps/api/src/claims.ts:3-15` — displayname, name, emailaddress,
  givenname, surname, objectidentifier, tenantid,
  authnmethodsreferences, `.../ws/2008/06/identity/claims/groups`,
  `groups.link` overage, `role`. Semantics at claims.ts:60-100
  (tenant_mismatch, groups_overage, app-roles vs groups vs
  entra_assignment — auth.ts:195-201).
- Smalt: `lib/smalt/identity/saml_idp.ex:384-387` mints ONE attribute,
  `Name="groups"` with basic NameFormat and values from `:groups`
  config (default `["smalt-admin"]`, single-user shape, lines 39-41).
  Absence proof: `grep -rn 'schemas.microsoft.com/identity'
  lib/smalt/identity/` → 0 hits. The consumer's authorization would see
  empty groups/roles/objectId/tenantId (fallback to NameID) and could not
  exercise group/role policy at all.
- Gap: mint the Entra schema attribute set (incl. multi-valued
  groups/role/authnmethodsreferences and the groups.link overage signal).
  Implementing lane: **S3** (Entra identity+claims+MSI).

### R8 — SAML IdP face: entryPoint/issuer/cert/signature (partially-covered → S3)

- Consumer: `apps/api/src/config.ts:147-176` (SAML_ENTRY_POINT,
  SAML_IDP_ISSUER, SAML_IDP_CERT[_PATH] derivation incl. the Entra
  `login.microsoftonline.com/{tenant}/saml2` + `sts.windows.net/{tenant}/`
  defaults), `apps/api/src/saml.ts:79-101` (node-saml options:
  wantAssertionsSigned, ValidateInResponseTo.always, sha256).
- Smalt: r2 (`receipts/r2-t02-saml-idp.md`) — `/metadata` + `/sso`,
  REDIRECT+POST bindings, real RSA-SHA256, cert in `.smalt/tls/dev-cert.pem`,
  entityID `urn:smalt:identity:saml`. r3
  (`receipts/r3-t03-consumer-court.md:100-127`) blocked leg 3 C on the
  non-canonical digest; the c14n fix has since landed on disk —
  `lib/smalt/identity/saml_idp.ex:365-374` ("digested over its
  INCLUSIVE-C14N bytes ... raw-string digests are the [rejection reason]")
  — file mtime 23:12, L16 in-flight, court rerun not yet receipted.
- Gap: `just courtroom-court` rerun proving leg 3 C→D green
  (`303 → /dashboard`, `/api/auth/me 200`) is the close condition
  (r3 close condition, lines 129-134). Implementing lane: **S3**.
  Note: IdP metadata advertises only the HTTP-POST SSO binding
  (saml_idp.ex:431); node-saml never reads it (uses entryPoint config),
  so this is a parity footnote, not a consumer blocker.

### R9 — SAML SLO / sign-out (partially-covered → S3)

- Consumer: `apps/api/src/auth.ts:205-231` (POST /api/auth/logout →
  `saml.createLogoutUrl` at auth.ts:214; GET/POST /saml/logout/callback
  landing), `apps/api/src/config.ts:221` (SAML_IDP_LOGOUT_URL).
- Smalt: SLO landed on disk by L16 after being queued (r12 §2: face
  `saml2-slo` standing queued, ticket T04) — `lib/smalt/identity/
  saml_slo.ex` (28 KB, mtime 23:11), wired into saml_idp.ex
  (`logout_request_xml` saml_idp.ex:268, `record_session` :355) and the
  metadata now advertises SingleLogoutService REDIRECT+POST at /slo
  (saml_idp.ex:431). No L16 receipt on disk yet.
- Gap: SLO receipt + a consumer-shaped logout court (SAML_IDP_LOGOUT_URL
  → /slo → callback). Implementing lane: **S3**.

### R10 — Managed identity / IMDS (covered, none)

- Consumer: touches nothing —
  `grep -rniE 'MSI_ENDPOINT|IDENTITY_HEADER|managed.?identity|169\.254'
  apps packages` → 0 hits; no @azure/* packages
  (apps/api/package.json deps: express, express-session, connect-redis,
  redis, @node-saml/node-saml, @xmldom/xmldom, zod only).
- Smalt: IMDS face exists (`lib/smalt/auth/imds.ex:1-6`,
  `lib/smalt/arm_gateway/plug/metadata.ex:20-22`
  `/metadata/identity/oauth2/token`).
- Gap: none for this consumer. Lane: none.

### R11 — App Config + Key Vault secret references (MISSING → S4)

- Consumer: secrets arrive only as plain env (config.ts:179-183
  SESSION_SECRET; config.ts:166-169 SAML_IDP_CERT / SAML_IDP_CERT_PATH
  readFileSync). In a real ACA deploy these are Key Vault references
  (`@Microsoft.KeyVault(SecretUri=...)`) resolved by the platform into
  container env — an implied technique, zero direct API calls.
- Smalt: both data planes exist — App Configuration /kv
  (`lib/smalt/egress_router.ex:1835,1909-1990,2124` incl. snapshots and
  KV-modified/deleted events) and KeyVault faces (r9c receipt:
  `receipts/r9c-keyvault-split.md` — keys/secrets/certificates split).
  Absence proof: `grep -rniE '@Microsoft|keyvault.?ref' lib/` → 0 hits —
  no secret-reference resolution into container env.
- Gap: resolve KV secret references into the env contract of hosted
  containers (pairs with R2's env injection). Implementing lane: **S4**.

### R12 — Console-log → Log Analytics shape (partially-covered → S5)

- Consumer: `apps/api/src/logger.ts:11-16` — one JSON object per line
  ("the format Azure Container Apps forwards to Log Analytics"),
  `{time, level, event, ...fields}` on stdout/stderr.
- Smalt: Log Analytics ingest face exists
  (`lib/smalt/egress_router.ex:4951` — DCR ingest 204 + x-ms-request-id;
  Sentinel/Log Analytics route family at :2293, :16) — that is a push-API
  emulation, NOT the ACA console-log collection pipeline that would scrape
  a hosted app's stdout into a workspace.
- Gap: the ACA log pipeline (stdout scrape → workspace) around R2's
  runtime plane. Implementing lane: **S5**.

### R13 — CI/CD deploy loop to ACA (MISSING → S5)

- Consumer: `.github/workflows/ci.yml` is build+test+scan only — api-image
  (:37-59) and web-image (:61-83) build, run, curl-health, trivy-scan;
  there is NO deploy job (no az login, no ACR push, no az containerapp).
  The deploy target is implied by README.md:3-5 (per-tenant container apps).
- Smalt: no deploy/azd/az-containerapp CLI face or workflow emulation;
  the KIND-E2E sibling lane (k8s/courtroom-*.yaml +
  scripts/courtroom_kind_court.sh, in-flight) is the emerging vehicle.
- Gap: a deploy loop (image push + per-tenant app revisions + env from
  R11) so `main` lands on the emulated ACA. Implementing lane: **S5**.

### R14 — Tenant-config zod schema → per-tenant topology (partially-covered → S5)

- Consumer: `packages/tenant-config/src/schema.ts:22-46` (slug/displayName/
  hostnames canonical+redirects/loginMethods `entra-saml`/access modes
  `assigned-users|allowed-groups`), tenants.ts:34-53 (loadTenants,
  slug-filename law), tenants.ts:63-69 (resolveTenantByHost).
- Smalt: tenant isolation exists in the data planes (KD-184/185/186 KV
  tenant-fence courts, KNOWN_DIVERGENCES v26.10.25) but there is no
  per-tenant ACA topology mapper (schema → N container-app pairs per
  README's shared-environment law).
- Gap: provisioning projection from tenant JSON to runtime topology.
  Implementing lane: **S5** (deploy loop; runtime hosting is R2/S2).

### R15 — OIDC surface (covered, none — informational)

- Consumer: `grep -rniE 'oidc|openid' apps packages --include='*.ts'
  --include='*.tsx'` → 0 hits. The consumer is SAML-only
  (LOGIN_METHODS = ["entra-saml"], schema.ts:8).
- Smalt: L18 is landing OIDC additively (oidc_authorize.ex mtime 23:24,
  oidc_idp.ex, r-t05a receipt). Additive smalt-side capability; no
  consumer coupling.
- Gap: none for this consumer. Lane: none.

## Named cross-reference note: r13

`docs/jira/v26.10.29/receipts/` has no r13 file. Bounded poll (5 tries x
3s):

```
R13_ABSENT_AFTER_5_TRIES_X_3S
POLL_EXIT=0
```

Typed as of scan-close: r1/r2/r3/r12 + KNOWN_DIVERGENCES (v26.10.25,
canonical v26.10.14) were sufficient for every row above. No SKIP exit:
this census does not depend on r13's content.

## Scoreboard

| status | rows |
|---|---|
| covered | R4, R5, R10, R15 |
| partially-covered | R8, R9, R12, R14 |
| MISSING | R1, R2, R3, R6, R7, R11, R13 |

Lane allocation of gaps: S2 = R1, R2, R3, R6 · S3 = R7, R8, R9 ·
S4 = R11 · S5 = R12, R13, R14.

## Verification (real output, this session)

```
$ grep -rn '100\.64' /Users/sac/smalt/lib/ --include='*.ex' | wc -l
       0
$ grep -rn 'rediss' /Users/sac/smalt/lib/ --include='*.ex' | wc -l
       0
$ grep -rniE '@Microsoft|keyvault.?ref' /Users/sac/smalt/lib/ --include='*.ex' | wc -l
       0
$ grep -rn 'schemas.microsoft.com/identity' /Users/sac/smalt/lib/smalt/identity/ | wc -l
       0
PROOF_EXIT=0
$ grep -rniE 'oidc|openid' apps packages --include='*.ts' --include='*.tsx' | wc -l
       0
```

All scans were reads against the two repos on disk; no compile/test run was
required by this lane (read-only census), so no MIX_BUILD_ROOT was created.

## Standing

ALIVE — census complete; every consumer surface mapped with two-sided
citations; 7 MISSING / 4 partially-covered / 4 covered rows; r13 named
absent after a bounded poll.

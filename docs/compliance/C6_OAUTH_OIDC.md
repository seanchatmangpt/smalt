# C6 — OAuth 2.0 / OIDC Compliance: smalt STS vs RFC 6749 / OIDC Discovery / Azure AD

C6_OAUTH_OIDC

## Scope

Validates the smalt ARM-gateway STS (`Smalt.ArmGateway.Router` token issuance,
`Smalt.Auth.Bearer` verification) against RFC 6749 (OAuth 2.0), OIDC Discovery
3.0 / Azure AD v2.0 endpoint contract, RFC 7519 (JWT), and RFC 6750 §3
(WWW-Authenticate challenges). Fence tests: `test/compliance/c6_oauth.exs`.

## Court method

Every row below was decided by a live run of the real router plug pipeline
(Plug.Test through `Smalt.ArmGateway.Router.call/2` — real Joken HS256
signing, real `Plug.Parsers` form decoding), per
`test/compliance/c6_oauth.exs` (18 tests, 0 failures as of 2026-10-15).

## Row status legend

- **PASS** — observed, spec-conformant for the emulated surface.
- **DEV-MODE** — deliberate emulator divergence from real AAD, pinned as-is.
- **GAP** — divergence from RFC/AAD contract, pinned by test with the
  expected-AAD behavior documented.

## RFC 6749 token endpoint

| # | Probe | smalt observed (live) | RFC/AAD contract | Status |
|---|-------|----------------------|------------------|--------|
| 1 | `POST /oauth2/v2.0/token`, form `grant_type=client_credentials&client_id&client_secret` | 200, `{"token_type":"Bearer","expires_in":3600,"ext_expires_in":3600,"access_token":"<jwt>"}` | RFC 6749 §5.1: token_type Bearer, expires_in int, access_token | PASS (router.ex:290-315) |
| 2 | invalid `grant_type=password` | **400 `{"error":"unsupported_grant_type"}`** + `Cache-Control: no-store` | RFC 6749 §5.2: 400 `unsupported_grant_type` | PASS (router.ex `validate_token_request/1`) |
| 3 | missing `client_id` | **400 `{"error":"invalid_client"}`** | AAD/RFC §5.2: 400 `invalid_client` | PASS (same locus) |
| 4 | garbage form body `not=a form` | **400 `{"error":"invalid_request"}`** | AAD/RFC §5.2: 400 `invalid_request` | PASS (same locus) |
| 4a | duplicate `grant_type` in form (either order, last-wins decode) | **400 `{"error":"invalid_request"}`** (fail-closed; detected on raw body) | OAuth 2.1 draft security considerations / AAD parity: duplicates refused, never last-wins | CONFORMANT — landed by auth lane 2026-10-15, fenced both in auth_enforce_test (mint fuzz) and c6 compliance corpus |
| 5 | tenant path `POST /{tid}/oauth2/v2.0/token` | 200, same envelope; tid echoed into `iss`/`tid` claims | AAD v2.0 tenant-scoped token endpoint | PASS (router.ex:2430) |
| 6 | `/common/oauth2/v2.0/token` | 200 (falls to the `:tenant_id` route, tid="common") | AAD: /common issues tokens only with param-derived tid | DEV-MODE (router.ex:2430) |

## JWT contract (RFC 7519 + Azure claims)

| # | Field | smalt observed (live-decoded) | AAD/RFC 7519 | Status |
|---|-------|------------------------------|--------------|--------|
| 7 | header `alg`/`typ` | `{"typ":"JWT","alg":"RS256","kid":"<RFC 7638 thumbprint>"}` | AAD: `RS256` | **PASS (FLIPPED from DEV-MODE 2026-10-19)** — mint rides `Smalt.Auth.StsKey.signer/0` (RSA 4096, env-PEM-first precedence, kid = thumbprint); legacy HS256 dev mode stays behind `config :smalt, :sts_key_mode, :hs256_dev` |
| 8 | RFC 7519 registered claims | `exp`,`iat`,`nbf` (iat==nbf), `aud`=`https://management.azure.com`, `iss`, `sub` all present, ints in Unix s | §4.1 required-set parity | PASS (router.ex:291-304) |
| 9 | Azure claims | `tid`,`oid`,`appid`,`azp`,`roles`=["Contributor","Owner"] present | AAD access-token contract | PASS (router.ex:299-304) |
| 10 | claim values | ALL fixed: appid/azp zero-GUID, oid==sub fixed GUID, roles always Contributor+Owner regardless of client | AAD: derived from the authenticated service principal | DEV-MODE (router.ex:291-304) |

## OIDC Discovery document

| # | Field | smalt observed | OIDC Discovery (REQUIRED in bold) | Status |
|---|-------|---------------|-----------------------------------|--------|
| 11 | **issuer** | `http://<client-authority>/{tid}/v2.0` — request-authority-derived | Stable per-tenant issuer | PASS as surfaced, see row 12 |
| 12 | issuer == token `iss` (EXACT) | EXACTLY equal: token `iss` now derives from the SAME `request_authority/1` as the discovery doc (`#{authority}/{tid}/v2.0`) | OIDC §4.3 / AAD: EXACTLY equal | PASS (router.ex `issue_token/2` + `openid_envelope/2`) — fixed GAP C6-4 |
| 13 | **token_endpoint** / **authorization_endpoint** | `{authority}/{tid}/oauth2/v2.0/{token,authorize}` | required | PASS (router.ex:390-400) |
| 14 | **jwks_uri** | `{authority}/{tid}/discovery/v2.0/keys` → **served 200 `{"keys":[{kty RSA, n, e AQAB, use sig, alg RS256, kid}]}`** | required | **PASS (FLIPPED from honestly-empty 2026-10-19)** — RS256 mode publishes `Smalt.Auth.StsKey.jwk_map/0`; `:hs256_dev` keeps the honestly-empty `{"keys":[]}` pin (secret never published) |
| 15 | **response_types_supported** | `["token"]` | REQUIRED | PASS — fixed GAP C6-6 |
| 16 | **spec-required `subject_types_supported`** | `["public"]` | REQUIRED | PASS — fixed GAP C6-7 |
| 17 | **id_token_signing_alg_values_supported** | `["RS256"]` | AAD: `["RS256"]` | **PASS (FLIPPED from DEV-MODE 2026-10-19)** — mode-conditional in `openid_envelope/2`: `["RS256"]` under the default RS256 STS key, `["HS256"]` under `:hs256_dev` (always self-consistent with row 7) |
| 18 | well-known path forms | `/.well-known/openid-configuration` (issuer `.../organizations/v2.0`) AND `/{tid}/v2.0/..well-known/openid-configuration` both served | AAD v2.0 path forms `/common/v2.0/.well-known/openid-configuration` and `/{tid}/v2.0/...` | PASS as pin: tenant form matches AAD; bare form is the emulator's own (organizations ≠ common) — DEV-MODE |
| 19 | tenant discovery wiring | `/common/discovery/instance` serves `tenant_discovery_endpoint` → `/{tid}/v2.0/.well-known/openid-configuration`, plus `authorization_endpoint`/`token_endpoint`/`issuer` consistent with the tenant doc | required for MSAL bootstrap | PASS (router.ex:2530-2545) |

## RFC 6750 §3 — protected-resource challenges

| # | Probe | smalt observed | RFC 6750 §3 | Status |
|---|-------|---------------|-------------|--------|
| 20 | anonymous `GET /subscriptions` under `:auth_mode=:enforce` | 401 + `WWW-Authenticate: Bearer error="invalid_token", error_description="..."` + ARM error envelope, halts | §3 challenge shape | PASS (bearer.ex:565,595) |
| 21 | challenge error code | always `invalid_token` for every refusal reason (missing/expired/wrong-aud/issuer/cross-secret) | §3.1 allows `invalid_request` for missing creds | DEV-MODE: RFC 6750 §3.1 says a request without credentials → 401 without error code; AAD uses `invalid_token` broadly — acceptable pin |

## Form encoding / charset

| # | Probe | smalt observed | Contract | Status |
|---|-------|---------------|----------|--------|
| 4/6 | `application/x-www-form-urlencoded; charset=UTF-8` body | decoded by `Plug.Parsers [:json, :urlencoded]` regardless of charset suffix; wrong-charset bodies are decoded too | RFC 6749 §4.4.2 form requirements | PASS (router.ex:42-46 parser config); permissive, no charset enforcement — pinned permissive |
| 22 | token-response cache headers | `Cache-Control: no-store` + `Pragma: no-cache` on ALL token responses (success AND §5.2 errors) | RFC 6749 §5.1 REQUIRES `Cache-Control: no-store` + `Pragma: no-cache` | PASS — fixed GAP C6-8 (router.ex `token_error/2` + `issue_token/2`) |

## Former GAP ledger (all closed this wave, 2026-10-14)

- **C6-1/2/3**: `handle_token/2` now validates the form
  (`validate_token_request/1`): unparseable/missing grant_type → 400
  `invalid_request`; wrong grant_type → 400 `unsupported_grant_type`;
  missing client_id/secret → 400 `invalid_client`.
- **C6-4**: token `iss` = `"#{request_authority(conn)}/#{tid}/v2.0"` — the
  same derivation as the discovery doc, so issuer EXACT-match holds.
- **C6-5**: `GET /:tid/discovery/v2.0/keys` → 200 `{"keys":[]}` (HS256
  dev-mode: honest empty JWKS).
- **C6-6/7**: `openid_envelope/2` adds `response_types_supported:
  ["token"]`, `subject_types_supported: ["public"]`.
- **C6-8**: `Cache-Control: no-store` + `Pragma: no-cache` on every token
  response including §5.2 errors.
- Remaining DEV-MODE pins (deliberate, unchanged): HS256 not RS256, fixed
  zero-GUID claim values, `/organizations` bare well-known form, always-
  `invalid_token` challenge code.
- Non-required AAD-parity fields still absent: `grant_types_supported`,
  `tenant_region_scope`, `cloud_instance_name`, `claims_supported`,
  `x-ms-*` metadata.

## Receipt

- Falsifier run: `mix test test/compliance/c6_oauth.exs` → **18 tests, 0 failures**
  (2026-10-15 re-measured; prior `:c6_gap` pins flipped to CONFORMANT assertions).
- Full gate: c1+c2+c3+c4+c5+c6+c7 + smalt_arm_gateway + smalt_services +
  auth_enforce → **141 tests, 0 failures** (16 excluded pre-existing tags).
- Regression rows updated for the new §5.2 contract: the two
  smalt_arm_gateway STS tests (request-authority iss; form now carries
  client_id+secret) and c6's tenant-path / form-charset rows.
- Locus lines verified against `lib/smalt/arm_gateway/router.ex` and
  `lib/smalt/auth/bearer.ex` on 2026-10-14.
- Concurrency note: the shared checkout had ~10 other lane beams listening;
  standalone `mix run --no-halt` sockets died under the Amqp sweeper crash
  loop, so the court drives the real router in-process (same pattern as
  `test/auth_enforce_test.exs`). No mocks; real plug pipeline + real Joken.

- Live socket attempt: server binds shifted ephemeral ports (e.g. 63844/63845)
  but shuts down ("Application smalt exited: shutdown") under `mix run --no-halt`
  outside `mix test` — the Amqp sweeper crash loop terminates the app. The
  in-process court is the working gate.

## Arcus dual anchors (P3-L6 re-anchor, 2026-11-05)

The C6 behavior surface is re-anchored dual-repo: smalt loci (rows above cite
`router.ex`/`bearer.ex`) map line-for-line onto the arcus Go membrane
(`/Users/sac/arcus/internal/dialect/azure/`). NOTE on router.ex rows: the STS
route family was extracted from `router.ex` into the route-family plug
`lib/smalt/arm_gateway/plug/oidc_sts.ex` (T06, v26.10.29); every `router.ex:NNN`
citerow above now resolves to the plug. Real verified lines (grep -n on
2026-11-05):

| smalt locus | behavior | arcus anchor (real lines) |
|---|---|---|
| `router.ex` token rows → `arm_gateway/plug/oidc_sts.ex:290-315` (routes `post "/oauth2/v2.0/token"` :290, `post "/:tenant_id/oauth2/v2.0/token"` :294; `handle_token/2` :30; `validate_token_request/1` :75; `issue_token/2` :121; `token_error/2` :58) | token endpoint, §5.2 validation, envelope mint | `oidc_sts.go:286` `HandleTenantToken`, `:220` `ValidateTokenRequest` (`invalid_request` :224/:226, `unsupported_grant_type` :228, `invalid_client` :230), `:236` `TokenClaims`, `:279` `writeTokenError`, `:432` `Router` mux |
| `router.ex` discovery rows → `arm_gateway/plug/oidc_sts.ex:256-276` (`openid_envelope/2`: issuer :262, token_endpoint :262, jwks_uri :261, id_token_signing_alg :267, response_types :273, subject_types :274; `HandleOIDCDiscovery` :313, `HandleJWKS` :319, `HandleInstanceDiscovery` :331, tenant_discovery_endpoint :339-340) | OIDC discovery doc, JWKS, instance discovery | `oidc_discovery.go:24` `OAuthAuthServerMetadataDoc` (issuer :26, token_endpoint :28, jwks_uri :29, response_types :32), `:41` `HandleOAuthAuthServerMetadata`, `:51` `MatchOAuthAuthServerRoute`; `oidc_sts.go:256` `OIDCDiscoveryDoc` (issuer :258, token_endpoint :259, jwks_uri :261, id_token_signing :262, response_types :263, subject_types :264) |
| `bearer.ex:683,719` (`challenge_value/2` :710, `send_challenge/2` :738) | RFC 6750 §3 `WWW-Authenticate: Bearer error="invalid_token"` challenge | `errors_aad.go:171` `ChallengeValue` (renders `Bearer authorization=… resource=… error="invalid_token"` :178), subcode vocabulary :24-25, code map :39-40; `oidc_authorize.go:224` `writeAuthorizeError` |
| `identity/oidc_idp.ex:206` `handle_token`, `:213` `handle_code_grant` (PKCE :269-279, client check :245, redirect_uri :259; discovery `:315` `discovery_document`, auth-server metadata :337; token response :354; id-token mint :371) | interactive IdP: authorize-code + PKCE + id_token | `oidc_authorize.go:71` `validateAuthorize` (client_id :73, PKCE `code_challenge` :85, method :90), `:109` `checkClient` (`invalid_client` :117), `:124` `validateRedirectURI` (:126/:135/:138), `:152` `mintAuthorizeCode`, `:180` `TakeAuthorizeCode`, `:208` `redirectLocation` |

P0 fence: the anchored smalt files are UNCHANGED this lane (P0 fence law).
Corrected citation (2026-11-05, P3-L6 retry): the earlier plan cited
`lib/smalt/identity/oidc_sts.ex`, which DOES NOT EXIST — smalt's identity
plane has `oidc_idp.ex`, `oidc_authorize.ex`, `oidc_jwks.ex`,
`oidc_code_store.ex`, `entra_*` (no `oidc_sts.ex`; the STS route family
lives at `lib/smalt/arm_gateway/plug/oidc_sts.ex`). Fence over the files
that actually exist, sha256 computed fresh 2026-11-05:

- `arm_gateway/plug/oidc_sts.ex` `20867639168e334c927ac04d8622c0d8fd93f9156cbee145c265ec714e9e2ae6`
- `identity/oidc_idp.ex` `8fc6ad22565a27e9d25899d98b1191cfbffe10288844c5934c7e67ed0b54e953`
- `identity/oidc_authorize.ex` `ac1a600a1736446b07af52ff5699b90235023b86f7aaff37bc80cd752c4980e4`
- `identity/oidc_jwks.ex` `971a6ec600da6169f09077b5aa2a7605c6a3f9930f48d76744b43cb16779eb91`

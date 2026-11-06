# P3-L6 — C6 OAuth/OIDC arcus re-anchor receipt (retry lane)

Standing: PASS

Date: 2026-11-05. Repo: /Users/sac/smalt (C6 doc), arcus membrane at
/Users/sac/arcus (anchor targets, read-only).

## Retry context

Previous P3-L6 lane died on a 429 after appending the anchor section to
`docs/compliance/C6_OAUTH_OIDC.md` but before writing its receipt. The
appended section was found intact in the working tree (~23 lines + table);
this lane verified/completed it rather than re-appending.

## Per-anchor verdicts (grep -n on disk, 2026-11-05)

| # | anchor | verdict | evidence |
|---|---|---|---|
| 1 | token endpoint: smalt `arm_gateway/plug/oidc_sts.ex` (`:290` `post "/oauth2/v2.0/token"`, `:294` tenant route, `:75` validate, `:121` issue, `:58` token_error) ↔ arcus `oidc_sts.go` (`:286` HandleTenantToken, `:220` ValidateTokenRequest with invalid_request :224/:226, unsupported_grant_type :228, invalid_client :230; `:236` TokenClaims; `:279` writeTokenError; `:432` Router mux, HandleTenantToken dispatch :450) | PASS | all line refs re-read from disk this session |
| 2 | discovery: smalt `oidc_sts.ex:256-276` (issuer :262, token_endpoint :262, jwks_uri :261, signing :267, response :273, subject :274) ↔ arcus `oidc_discovery.go:24` OAuthAuthServerMetadataDoc (issuer :26, token_endpoint :28, jwks_uri :29, response_types :32), `:41` handler, `:51` route match; `oidc_sts.go:256` OIDCDiscoveryDoc (issuer :258, token_endpoint :259, jwks_uri :261, signing :262, response :263, subject :264) | PASS | all line refs re-read from disk |
| 3 | RFC 6750 challenge: smalt `bearer.ex:683,719` (challenge_value :710, send_challenge :738) ↔ arcus `errors_aad.go:171` ChallengeValue (render `error="invalid_token"` :178; subcode const block :24-38, refusalPairs map :39+) and `oidc_authorize.go:224` writeAuthorizeError | PASS | one drift fixed: appended row cited `errors_aad.go:159` (a comment line); actual func is :171 — corrected in C6 doc |
| 4 | interactive IdP: smalt `identity/oidc_idp.ex` (`:206` handle_token [defp], `:213` handle_code_grant, `:245` check_client_id, `:259` check_redirect_uri, PKCE :269-279 [code_challenge :270, S256 :281, plain :292], `:315` discovery_document, `:337` auth_server_metadata, `:354` token_response, `:371` mint_id_token) ↔ arcus `oidc_authorize.go` (`:71` validateAuthorize: client_id :73, code_challenge :85, method :90; `:109` checkClient invalid_client :117; `:124` validateRedirectURI; `:152` mintAuthorizeCode; `:180` TakeAuthorizeCode; `:208` redirectLocation) | PASS | all line refs re-read from disk |

## Corrected P0 fence (sha256, fresh 2026-11-05)

Premise correction (census-verified): `lib/smalt/identity/oidc_sts.ex` DOES
NOT EXIST — the earlier plan's sha citation was unfounded. The STS route
family lives at `lib/smalt/arm_gateway/plug/oidc_sts.ex`. Fence over files
that actually exist:

- `lib/smalt/arm_gateway/plug/oidc_sts.ex`
  `20867639168e334c927ac04d8622c0d8fd93f9156cbee145c265ec714e9e2ae6`
- `lib/smalt/identity/oidc_idp.ex`
  `8fc6ad22565a27e9d25899d98b1191cfbffe10288844c5934c7e67ed0b54e953`
- `lib/smalt/identity/oidc_authorize.ex`
  `ac1a600a1736446b07af52ff5699b90235023b86f7aaff37bc80cd752c4980e4`
- `lib/smalt/identity/oidc_jwks.ex`
  `971a6ec600da6169f09077b5aa2a7605c6a3f9930f48d76744b43cb16779eb91`

## Gate

- Anchor marker count vs receipt rows: 4 anchor rows in the C6 dual-anchor
  section ↔ 4 receipt rows above — MATCH.
- Standing line present (PASS).
- No git actions performed.

## Files touched

- `docs/compliance/C6_OAUTH_OIDC.md` (fixed errors_aad.go:159→:171;
  completed the P0 fence block with corrected citations + 4 fresh shas;
  explicit note that identity/oidc_sts.ex does not exist)
- this receipt

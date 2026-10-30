# T05 — Entra-shaped OIDC/OAuth identity provider

- window: v26.10.29 · status: QUEUED (after T04) · unlocks the MSAL-SDK
  consumer family (more Azure-typical than SAML)

## Exists today

Emulator STS mints HS256 bearers (`POST /{tenant}/oauth2/v2.0/token`, any
client_id/secret); ARM plane already exempts Entra-shaped paths
(`/oauth2/*`, `/.well-known/*`, `/common/discovery/*`, `/tenant(s)`). That
is client-credentials interception, not an identity provider.

## Scope

- Per-tenant discovery: `/.well-known/openid-configuration` +
  `/.well-known/oauth-authorization-server`.
- `/authorize` with an auto-approve sign-in form (T02 auto-submit form
  pattern).
- Authorization-code + PKCE; code exchange at `/oauth2/v2.0/token`.
- ID token minting as RS256-signed JWT — the affidavit/attestation modules
  already do RS256 JWS in-repo.
- `/userinfo`, JWKS (`/discovery/v2.0/keys`), refresh tokens; optionally
  client-credentials with real scope/role claims.
- Architecture: identity-plane attach point + config-stamp pattern T02
  established (`config :smalt, :saml_idp` → sibling `:oidc_idp`, or one
  unified identity config surface).

## Law

Real-consumer court: a real `openid-client` / `@azure/msal-node` client
runs the full code+PKCE flow against smalt — discovery → authorize → code
exchange → ID token signature verify against the JWKS — never an in-BEAM
assert alone.

## Falsifier

An unmodified MSAL-family client obtains a verified ID token whose `iss`,
`aud`, and `kid` all resolve against the smalt discovery + JWKS surfaces —
or the ticket is not done.

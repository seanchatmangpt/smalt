# T04 — SAML Single Logout (SLO) on the smalt IdP

- window: v26.10.29 · status: QUEUED (after FINISH-WIRE) · depends: T02
- consumer need: `apps/api` already carries the SP half —
  `SAML_IDP_LOGOUT_URL`, `POST /api/auth/logout`,
  `GET, POST /saml/logout/callback` — waiting on the IdP side.

## Scope

- `GET /slo` (REDIRECT binding) + `POST /slo` (POST binding) accepting a
  signed `<LogoutRequest>`: parse, verify the SP signature, reply with a
  signed `<LogoutResponse>` (Status Success).
- IdP-initiated logout face: mint a signed `<LogoutRequest>` pushed to the
  SP's single-logout callback.
- Session index tracking: (NameID, SessionIndex) pairs issued per sign-in,
  so logout requests validate meaningfully. Lazy shadow ETS/Store table
  (AzureCache registry precedent, heir to `:init`).
- Signing/c14n/metadata reuse from T02 (RSA-SHA256 canonical-XML machinery,
  dev cert material, `/metadata` gains an SingleLogoutService descriptor).

## Law

Real-consumer court, not just in-BEAM structural asserts: the SLO flow must
validate through the real `@node-saml` logout path in the consumer app
(T03 harness pattern) — the RESP3 saga showed handshake pinions only break
under real clients.

## Falsifier

A signed logout round-trip through the consumer app's existing routes ends
with the session destroyed in the smalt-backed Redis store and
`GET /api/auth/me` answering 401 — or the ticket is not done.

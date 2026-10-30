# r-p01 — Browser-witnessed zero-touch SAML sign-in (P01, CLM-01)

- window: v26.10.30 · date: 2026-10-30 · tier: in-cluster (kind `smalt`)
- standing: **ALIVE**
- court: real headless chromium (playwright 1.56) in the `r30-driver` pod,
  CA trust = substrate's own CA (`NODE_EXTRA_CA_CERTS`-style baked image
  law), browsing the consumer's documented dev shape
  (`http://localhost:3000` via an in-pod TCP pipe; Secure cookies on
  localhost = the consumer's own documented dev law). No mock IdP, no
  bypass flags, no injected cookies — the production `@node-saml` in
  `courtroom-api` validated every signature.

## Claim witnessed

Click sign-in → `/api/sso/start` 302 → IdP `/sso` → auto-POST
`SAMLResponse` (12 016-char form value, complete) → production
`@node-saml` validation in the api → session issued → `/dashboard`
reached → `GET /api/auth/me` 200 carrying the full Entra claim shape:

```json
{"verdict":"P01-PASS","url":"http://localhost:3000/dashboard",
 "identityProvider":"Microsoft Entra ID","nameID":"smalt-user",
 "tenantId":"11111111-1111-4111-8111-111111111111",
 "groups":[{"id":"33333333-3333-4333-8333-333333333331",
            "name":"Courtroom-Admins","authorizing":true}, ...]}
```

## Defects found and fixed en route (each with a wire witness)

1. IdP minted no `AudienceRestriction` — node-saml rejects with
   "SAML assertion has no AudienceRestriction"; fixed: audience falls
   back to the AuthnRequest Issuer (saml_idp.ex, coordinator patch).
2. Entra claims minted NESTED inside a second
   `<saml:AttributeStatement>` wrapper (EntraClaims emits its own) —
   node-saml's xml2js read only the outer node → profile =
   `{groups}` only → `tenant_mismatch`. Fixed: unwrap before
   concatenation (saml_idp.ex).
3. Docker layer-cache staleness: the pod's baked `_build/prod` beams
   out-dated the source mtimes, so boot compiles skipped; fixed with a
   boot-time `touch` of the identity sources (deployment args) + full
   `--no-cache` rebuilds.

## Honest residue

- The host-browser variant (mapping in-cluster DNS to 127.0.0.1) hits
  Chromium's SameSite=None; Secure law on non-localhost http — the
  consumer's own comment documents localhost as the dev exception.
  The in-cluster driver shape is the lawful witness.

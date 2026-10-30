# T02 — SAML 2.0 IdP face (Entra-shaped, identity plane)

- window: v26.10.29 · status: LANDED (ALIVE — receipt
  `receipts/r2-t02-saml-idp.md`) · consumer need: `apps/api`
  SP-initiated SAML sign-in (real `@node-saml/node-saml` validator)

## Scope

Minimal Entra-shaped IdP over HTTP POST binding:

- `GET /metadata` — IdP metadata XML (entityID, SSO POST binding location,
  X509Certificate KeyDescriptor, NameID format).
- `GET|POST /sso` — accepts a deflated+base64 `SAMLRequest`
  (AuthnRequest), mints a `<samlp:Response>` with an RSA-SHA256-signed
  `<Assertion>` (bearer subject confirmation, InResponseTo bound to the
  request ID, conditions/subject-confirmation-data windows), and answers
  with the auto-submit HTML POST form targeting the request's
  AssertionConsumerServiceURL with `SAMLResponse` + `RelayState`.
- Claims: NameID + attribute statement (groups), configurable defaults.

## Crypto

smalt controls the XML it emits, so the assertion is minted in canonical
form directly (no generic c14n engine needed): SHA-256 digest over the
assertion element, RSA-SHA256 (`:public_key`) over the SignedInfo, digest
method `#sha256`, transform `enveloped-signature`, cert material from the
dev cert pair (`.smalt/tls/`) or `config :smalt, :saml_idp` overrides.

## Surface

- `Smalt.Identity.SamlIdp` — Bandit plug router on
  `config :smalt, :saml_idp_port` (default 9445), identity plane, loopback
  bind law.
- Consumer wiring (T03): `SAML_ENTRY_POINT=http://127.0.0.1:9445/sso`,
  `SAML_IDP_ISSUER=<entityID>`, `SAML_IDP_CERT=<dev cert PEM>`.

## Falsifier

The real validator decides: the T03 consumer court runs the actual
`@node-saml/node-saml` `validatePostResponse` against a live smalt-minted
response through the actual courtroom API ACS route — signature,
InResponseTo replay cache (shared Redis store), audience/recipient/
destination, and validity windows all enforced by the consumer's own code.

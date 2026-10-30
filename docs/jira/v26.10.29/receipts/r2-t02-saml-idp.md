# Receipt: R2 T02 — SAML 2.0 IdP face

Standing: **ALIVE** (real Bandit listener, real HTTP, real RSA-SHA256
verification against the cert embedded in the response; 6/6 courts passed
this session).

## Files landed (contract-owned only)

- `lib/smalt/identity/saml_idp.ex` (new) — Bandit plug router
  `Smalt.Identity.SamlIdp`: `GET /metadata`, `GET|POST /sso`, typed 400s,
  ACS loopback/allowlist law, canonical-XML minting + RSA-SHA256 enveloped
  signature (`:public_key`, dev cert/key, `:persistent_term` cache).
- `test/integration/saml_idp_test.exs` (new) — in-repo court (Chicago):
  real listener on a private random port, bounded poll for readiness, real
  xmerl parses, real signature/digest recompute; tamper non-vacuity court.
- `lib/smalt/plane/identity_supervisor.ex` (one attach point) —
  `Smalt.Identity.SamlIdp` added alongside `Smalt.Plane.Identity.StsGate`;
  `one_for_one` contains a bind failure to the child.
- `docs/jira/v26.10.29/receipts/r2-t02-saml-idp.md` (this receipt).

## Commands / exits

- `MIX_BUILD_ROOT=_build-t02 mix test test/integration/saml_idp_test.exs`
  → exit 0, `Result: 6 passed` (real output:
  `Result: 6 passed` / `Finished in 0.2 seconds`, failures 0).
- `MIX_BUILD_ROOT=_build-t02 mix compile --warnings-as-errors` → exit 1,
  **pre-existing**: a HEAD probe (my two files temporarily swapped out,
  `_build-t02probe`) also fails with 285 baseline warnings
  (canonical_router.ex, redis_wire.ex — other lanes'/pre-existing).
  Zero warnings cite `saml_idp.ex` or `identity_supervisor.ex`
  (grep count 0 in the gate log). Plain `mix compile` → exit 0.

## Verification ladder (what the courts actually assert)

1. `/metadata` pins entityID `urn:smalt:identity:saml`, signing
   KeyDescriptor with DER base64 cert, POST SingleSignOnService at
   `<base>/sso`.
2. REDIRECT binding (deflate raw + base64) AuthnRequest → 200 auto-submit
   form → SAMLResponse extracted, xmerl-parsed: StatusCode Success,
   InResponseTo (Response + SubjectConfirmationData) match the request ID,
   Recipient = ACS, NameID = `smalt-user`.
3. Signature court: SHA-256 recomputed over the emitted assertion with the
   `<ds:Signature>` element removed, compared to DigestValue, and
   SignatureValue verified with the embedded cert's public key
   (SPKI extraction via `elem(tbs, 7)`; `cert_public_key/1` does not exist
   on this OTP 28/public_key 1.21.8).
4. POST binding (plain base64 XML) end to end incl. signature.
5. Tamper court (non-vacuity): mutating NameID → `{:error, :digest_mismatch}`.
6. Non-loopback ACS → 400 `ACS_NOT_LOOPBACK`; garbage request → 400
   `UNPARSEABLE_SAML_REQUEST`.

## SP consumer parameters (entryPoint/issuer/cert)

- entryPoint (SSO URL): `http://127.0.0.1:9445/sso` (port via
  `config :smalt, :saml_idp_port`; bind IP via `Smalt.Config.bind_ip()` law)
- metadata URL: `http://127.0.0.1:9445/metadata`
- issuer / IdP entityID: `urn:smalt:identity:saml`
  (override `config :smalt, :saml_idp, :entity_id`)
- cert: the X.509 in `.smalt/tls/dev-cert.pem`, served in `/metadata` and
  in every response KeyInfo (override `:cert_path` / `:key_path`)
- protocol: REDIRECT binding for AuthnRequest, POST binding accepted;
  response POSTed to the request's AssertionConsumerServiceURL
  (loopback-only unless `:allowed_acs` allowlisted)

## Honest divergences

- No SLO, no artifact resolution, single-user claims
  (`:name_id` / `:groups` config; defaults `smalt-user` /
  `["smalt-admin"]`).
- Assertion/response IDs random per mint; no replay cache — InResponseTo
  tracking is left to the SP (node-saml validates InResponseTo + clocks).
- Signature covers the assertion only (response-level signing not
  implemented); SignedInfo is minted in canonical form with `ds` declared
  on the element itself (exclusive-c14n shape), matching what standard
  validators recompute.
- Baseline compile is not warnings-clean (285 pre-existing warnings) — the
  `--warnings-as-errors` gate cannot exit 0 on this tree; my delta is zero
  new warnings.
- `Process.sleep(10)` appears ONLY inside the audited bounded-poll
  implementation (wait_until), per no-sleep law 1.

## Test output (verbatim tail)

```
Result: 6 passed
```

run: `MIX_BUILD_ROOT=_build-t02 mix test test/integration/saml_idp_test.exs`
exit 0, 2026-10-29.

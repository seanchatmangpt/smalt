# P01 — Zero-touch SAML enterprise sign-in witnessed by a real browser

- window: v26.10.30 · id: CLM-01 (Scenario 1) · receipt: r-p01-browser-saml.md
- standing law: the consumer repo is READ-ONLY forever — every artifact lands in
  smalt's tree.

## Claim

A real headless browser (no stubs, no shims, no disabled signature checks)
completes the full SP-initiated loop: click -> IdP auto-post -> production
`@node-saml` validation -> `connect.sid` issued -> `/dashboard` reached ->
`/api/auth/me` 200 carrying `sub`/`roles`/`tenant_id`.

## Falsifier

Any mock IdP, any bypassed signature check, or a manually-injected session
cookie marks the ticket FAIL.

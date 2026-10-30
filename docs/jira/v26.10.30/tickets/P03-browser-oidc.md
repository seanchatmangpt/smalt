# P03 — OIDC code+PKCE witnessed by a real browser AND a real client library

- window: v26.10.30 · id: CLM-03 · receipt: r-p03-browser-oidc.md
- depends: L17/L18 landed.

## Claim

Discovery -> `/authorize` consent -> code exchange -> RS256 `id_token`
verified against the live JWKS, all through the production client stack —
extending the L17/L18 `openid-client` proof from HTTP-level to browser-level.

## Falsifier

id_token accepted without JWKS verification, or the flow only demonstrated
server-side.

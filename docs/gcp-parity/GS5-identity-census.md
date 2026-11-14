# GS5 Identity Census

Standing: PARTIAL

- Azure: `Smalt.ArmGateway.Router` (:9443) plugs `Smalt.Auth.Bearer`; `/oauth2/*`,
  `/.well-known/*` are Bearer-exempt; tokens minted via `Smalt.Auth.StsKey` (RS256/HS256).
- Routing is path/port-based; no host dispatch exists today.
- GCP slot: `Smalt.GCP.Router` is a host-keyed Plug placed BEFORE `Smalt.Auth.Bearer`
  (googleapis hosts self-authenticate with `ya29.` tokens from `Smalt.GCP.Identity`);
  non-GCP hosts pass through unchanged. Census from ls/head reads only; not mix-verified.

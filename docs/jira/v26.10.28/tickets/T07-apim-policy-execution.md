# T-07 — API Management: service resource + policy execution model

- status: CODE-COMPLETE (2026-10-29): r16, awaiting integration run
- window: v26.10.28 · maps-to: Topaz v1.12 "API Management — rate-limit · set-header/body · validate-jwt · backend forwarding" · verdict-at-open: **PARTIAL** (adjacent primitives shipped)
- size: **L** · depends-on: — · parity-leg: apim gateway suite

## current state (evidence)

The four named policies exist as substrate-wide primitives, ahead in
coverage but not as an APIM resource: fixed-window 429 + `Retry-After`
(`:arm_rate_limit`), Bearer/STS validation on every plane
(`lib/smalt/auth/bearer.ex`), egress header/CORS policy
(`:egress_cors_origins`). There is no `Microsoft.ApiManagement/service`
resource, no gateway route, no policy document execution
(`parity/COVERAGE_VS_TOPAZ.md` — Topaz APIM 53/59 vs smalt absent).

## scope

1. ARM `Microsoft.ApiManagement/service` + `apis` + `operations` +
   `policies` CRUD (registry pattern).
2. A gateway listener route (`/{service}/{api}/{operation}` shaped, or the
   configured gateway base) executing an inbound policy subset, in the real
   policy XML dialect:
   - `rate-limit` / `rate-limit-by-key` (quota window, 429 + Retry-After)
   - `set-header` / `set-body` (inbound rewrite)
   - `validate-jwt` (required-claim/issuer checks against the mounted STS)
   - backend forwarding to the operation's configured smalt backend URL.
3. Policy rejection at PUT time for malformed XML (typed 400, real code).

## non-goals

- Full APIM expression language; outbound/on-error sections beyond the
  named four policies.

## Definition of Done — the Azure developer's view

You `az apim create`, add an API with an operation backed by one of your
smalt-mounted services, and attach the same inbound policy XML you use in
Azure: `<rate-limit calls="5" renewal-period="60"/>`. Pointing your HTTP
client at the gateway URL, requests 1–5 forward to your backend (with your
`set-header` additions visible on the backend side) and request 6 gets
`429` with a `Retry-After`. Swap in `<validate-jwt>` and a tokenless call
gets `401` with the WWW-Authenticate shape your error middleware expects;
a request whose token lacks the required claim gets `403`. `az apim show`
lists it all exactly like the real service's ARM shapes.

## receipts required

Gateway transcript court per policy (429 windowing, header rewrite, jwt
valid/invalid matrix, forwarding); malformed-policy PUT refusal.

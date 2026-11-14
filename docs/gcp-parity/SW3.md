# SW3 Receipt

Standing: UNVERIFIED

Lane SW3: nothing compiled or run (no mix/just/git).

## Diff

`lib/smalt/arm_gateway/router.ex`: inserted `plug(Smalt.GCP.Router)` immediately after
`plug(Smalt.Auth.XArrCert)`, i.e. above `ReceiptTurnstile` and `Smalt.Auth.Bearer`
(plus a comment). Plug order is now: Logger, arm_cors, normalize_leading_empty_segment,
XArrCert, GCP.Router, ReceiptTurnstile, Bearer, Parsers, ...

## Verification by reading

- `Smalt.GCP.Router.call/2`: `dialect(conn.host)` returns `:none` for any host other than
  oauth2/iam/cloudresourcemanager.googleapis.com, metadata.google.internal, 169.254.169.254;
  `:none` returns `conn` unchanged. Non-GCP (ARM) hosts pass through.
- GCP hosts are halted after response; Plug.Builder skips later plugs, so GCP responses carry
  no ARM receipt headers or Bearer 401 (intended: GCP uses its own `ya29.` verify).
- Functions exist: `Identity.token/1`, `tokeninfo/1`, `metadata/2`, `verify/1`, `json/3`;
  `IAM.serve/3`, `IAM.err/4`. `Router` calls `Identity.metadata(conn, segs)` and
  `IAM.serve(conn, d, segs)` with matching arities.

## Resolved risks

- JOSE verify_strict: `Smalt.Auth.Bearer` uses Joken; mix.exs has `{:joken, "~> 2.6"}`,
  mix.lock pins joken 2.7.0 -> jose 1.11.13 (non-optional). `JOSE.JWT.verify_strict/3`
  exists in jose 1.11.x, so identity.ex line 83 resolves; jose is a transitive dep only
  (acceptable; not declared directly).
- Plug.Test host override: `Plug.Test.conn/3` defaults host "www.example.com"; tests must set
  `%{conn | host: "oauth2.googleapis.com"}` (conn.host is what dialect/1 reads, port suffix
  tolerated). Residual: ARM `normalize_leading_empty_segment` runs before GCP router, harmless.
- Residual: hosts matched on `conn.host` only; GCP.Router `parse/1` uses Jason (present).

## Gate

Pending: `mix compile --warnings-as-errors` and `mix test test/gcp/identity_plane_test.exs`
(coordinator to run).

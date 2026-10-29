# KD-55 witness — ARM provider surface holes closed (FIX)

**Standing:** ALIVE (fix landed, wire-witnessed; FLIP-ELIGIBLE)

Row: KD-55 — tenant `GET /providers`, `GET /providers/{ns}`,
`GET /providers/Microsoft.Resources/operations`, and the subscription-scope
operations route all 404; per-ns subscription provider GET already worked.
Subject: `lib/smalt/arm_gateway/router.ex`

## Fix (surgical, `# KD-COVERS: KD-55`)

Three GET routes added in the providers section of the ARM router:

- `get "/providers"` — ProviderMatrix.provider_listing/1 (same Registry-projection
  the subscription route serves).
- `get "/providers/:ns"` — ProviderMatrix.provider/1; unknown namespace 404
  ResourceNotFound (no fabricated provider).
- `get "/providers/Microsoft.Resources/operations"` and
  `get "/subscriptions/:sub_id/providers/Microsoft.Resources/operations"` —
  `arm_operations_listing/0`, a minimal deterministic operations envelope.

All four gate `check_api_version(conn, nil)` (presence gate, mirroring the
existing subscription providers listing).

## Evidence (lane K4 substrate, MIX_ENV=test on :39551, 2026-10-21)

```
== KD55a tenant GET /providers
{"value":[{"namespace":"Microsoft.App","registrationState":"Registered","resourceTypes":[{"apiVersions":["2023-05-01"],"resourceType":"containerApps"}]},...
== KD55b tenant GET /providers/Microsoft.Storage
{"namespace":"Microsoft.Storage","registrationState":"Registered","resourceTypes":[{"apiVersions":["2023-05-01"],"resourceType":"storageAccounts"},...
== KD55c tenant GET unknown ns
{"error":{"code":"ResourceNotFound",...,"message":"Provider namespace 'Unknown.Provider' could not be found.",...}}
== KD55d sub operations
{"value":[{"display":{...},"is_data_action":false,"name":"Microsoft.Resources/operations/read"}]}
== KD55e tenant operations
{"value":[{"display":{...},"is_data_action":false,"name":"Microsoft.Resources/operations/read"}]}
```

Falsifier from the row (raw curls -> 200 Provider envelope) now passes; the
previously-404 cells answer the Provider/operations envelopes.

## Regression check

`MIX_BUILD_ROOT=_build-k4 mix test test/integration/namespace_put_test.exs
test/integration/arm_dcr_test.exs` -> 8 tests, 0 failures. The
arm_error_corpus suite reports 10 failures, all in other lanes' in-flight
surfaces (cosmos TTL, bridge fan-out, two-node join, internal census) — none
reference the ARM provider/PATCH routes; classified pre-existing/concurrent,
not session-introduced.

## Flip

FLIP-ELIGIBLE (dry-run only; flip via `scripts/kd_flip.py --apply` gated on
this receipt's mtime, never by hand).

Verdict: PASS (falsifier of the row executed on the wire; output above).

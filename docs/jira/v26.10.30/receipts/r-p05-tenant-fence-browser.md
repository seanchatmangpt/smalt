# r-p05 — Cross-tenant fence through the browser path (P05, CLM-06)

- window: v26.10.30 · date: 2026-10-30 · tier: in-cluster (kind `smalt`)
- standing: **ALIVE (3/3 asserts)**

## Claim witnessed

With the api's `ENTRA_TENANT_ID` flipped to a foreign tenant, the full
browser → ingress → api path runs the fence law: the substrate's
assertion (tenant `1111…`) fails the consumer's tenant-claim fence →
typed denial, error payload data-free, **no session issued**:

```json
{"verdict":"P01-FAIL","landed":"http://localhost:3000/?error=access_denied"}
```

Asserts: foreign-tenant-typed-denial ✓ · no-session-issued ✓ ·
error-payload-data-free ✓ — then the config restores and the identical
browser sign-in PASSES (`P01-PASS` with the true tenant, full claim
shape, `sso_login_success` carrying the objectId claim in the api log).
The fence's positive path (same tenant) and negative path (foreign
tenant) are both witnessed through the real browser stack.

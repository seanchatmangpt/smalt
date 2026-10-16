# TS SDK Results: @azure/arm-resources vs smalt ARM plane (TS-1)

- Date: 2026-10-15
- Lane: TS-1 (real TypeScript @azure SDK tier)
- Subject: `/Users/sac/smalt` v26.10.14 working tree (mid-landing, multi-lane)
- Probe source: `/Users/sac/smalt/test/sdk-full/arm-resources.probe.mjs` (added by this lane)
- Results log: `/tmp/sdk-ts-arm/probe-run3.log`

## Environment

- node v26.10.0, @azure/arm-resources **8.0.0**, @azure/identity 4.x (msal-node), @azure/core-rest-pipeline
- Substrate: `MIX_ENV=test mix run --no-halt` smalt substrate, ARM :9443 + TLS twin :9444 (dev TLS material `.smalt/tls/`)
- Run: `NODE_TLS_REJECT_UNAUTHORIZED=0 node arm-resources.probe.mjs` (from `test/sdk-full/`) — see TLS finding below

## Bootstrapping constraints (both are SDK-tier facts, not probe bugs)

1. **ClientSecretCredential cannot mint tokens against the emulator.**
   `new ClientSecretCredential(tenant, client, secret, { authorityHost: https://localhost:9444 }).getToken()`
   fails with msal `endpoints_resolution_error`: msal-node resolves tenant endpoints via OIDC instance
   discovery against the authority host before posting client_credentials, and the emulator does not
   serve the discovery envelope. Raw `POST https://localhost:9444/{tenant}/oauth2/v2.0/token` works
   (200, 3-segment JWT, aud=management audience). Workaround: a custom TokenCredential whose
   getToken() does the raw STS fetch. Same limitation class already documented in ts-reality.test.mjs
   (KeyVault rows). **Real-Azure delta: real Azure serves the discovery envelope at
   `{authority}/{tenant}/...` so ClientSecretCredential works there.**
2. **The TLS twin serves a self-signed leaf (CN=127.0.0.1, issuer=CN=127.0.0.1), not the CA-signed
   dev cert.** `openssl s_client` shows leaf issuer == leaf subject, so `NODE_EXTRA_CA_CERTS` cannot
   make Node trust it; the probe runs with `NODE_TLS_REJECT_UNAUTHORIZED=0`. Caveat: the substrate
   serving :9444 during this run was booted by a concurrent lane; whether a substrate booted with
   SMALT_TLS_CERTFILE/KEYFILE (ts-run.mjs style) serves the CA-signed chain is unverified from this
   lane. **Verify from a lane that owns the boot.** If the TLS twin serves a self-signed leaf even
   with certfile env set, that is a subject defect.

## Verdict: 8/11 probes passed

| # | Probe | Verdict | Evidence |
|---|---|---|---|
| 1 | STS client_credentials token over TLS (raw fetch) | PASS | 200; access_token 643 chars, 3 base64url segments |
| 2 | GET /subscriptions (Bearer) | PASS | 200; 1 sub `00000000-0000-0000-0000-000000000000`, state=Enabled |
| 3 | GET /subscriptions/{sub}/locations | **FAIL — divergence D1** | 404 `RouteNotFound` route `/subscriptions/{sub}/locations` |
| 4 | resourceGroups.createOrUpdate (PUT) | PASS | 201-shaped 200; `provisioningState=Succeeded`, tags echoed |
| 5 | resources.beginCreateOrUpdateById + pollUntilDone (NSG) | PASS | LRO to terminal; provisioningState=Succeeded; id round-trips |
| 6 | resources.getById (NSG) | PASS | 200; full GenericResource shape (id/name/type/systemData/properties/sku/tags…) |
| 7 | resources.listByResourceGroup | **FAIL — divergence D2** | "Pagination failed with unexpected statusCode 404" — wire 404 RouteNotFound on `/subscriptions/{sub}/resourcegroups/{rg}/resources` (confirmed raw with curl) |
| 8 | resourceGroups.update (PATCH tags) | **FAIL — divergence D3** | 404 RouteNotFound on `PATCH .../resourcegroups/{name}` (confirmed raw with curl) |
| 9 | resources.beginDeleteById + pollUntilDone (NSG) | PASS | LRO to terminal; deleted |
| 10 | resourceGroups.beginDelete + pollUntilDone | PASS | LRO to terminal; deleted |
| 11 | get-after-delete | PASS | statusCode=404 "could not be found" surfaced as RestError with correct 404 |

Final run log: `/tmp/sdk-ts-arm/probe-run3.log` (per-probe pass/fail lines + JSON verdicts).

## Divergences (wire evidence, all reproducible with raw curl against :9444)

- **D1 — missing locations route**: `GET /subscriptions/{sub}/locations?api-version=2022-12-01` →
  404 `RouteNotFound`. Real Azure: 200 with location list. Affects `SubscriptionClient`-based
  region discovery.
- **D2 — missing list-by-resource-group route**: `GET .../resourcegroups/{rg}/resources?api-version=2021-04-01`
  → 404 RouteNotFound (also what the SDK's paginator hits). Real Azure: 200 value[].
- **D3 — missing resourceGroups PATCH route**: `PATCH .../resourcegroups/{name}?api-version=2021-04-01` → 404 RouteNotFound. Real Azure: 200 with patched tags. Affects `resourceGroups.update` (tags PATCH).

## api-version ceiling (not a failure — emulator contract)

- `@azure/arm-resources` v8 defaults to api-version **2025-04-01**; the emulator rejects with 400
  "The latest supported api-version for 'Microsoft.Resources/resourceGroups' is '2021-04-01'." Probe pins
  `apiVersion: "2021-04-01"` in client options (supported by the v8 client); NSG generic RP capped at
  "2021-04-01" likewise. Real Azure accepts 2025-04-01.

## LRO behavior

- `beginCreateOrUpdateById`/`beginDeleteById`/`beginDelete` all reached terminal state via
  `pollUntilDone()` — the SDK's LRO machinery completes against the emulator's LRO headers. The
  202/Location/Azure-AsyncOperation envelope is compatible with @azure/core-lro.

LRO created resources are cleaned up in-band (NSG deleted, RG deleted; get-after-delete 404).

## Lane protocol deviation (disclosed)

The shared substrate lock `/tmp/smalt-substrate.lock` was held EXCLUSIVE for >12 min by a concurrent
lane's long-lived substrate (its beam inherited the flock fd), so this lane could not acquire the
exclusive boot+test window. The probe ran against the live substrate (already serving 9443/9444) without
holding the lock, using lane-unique resource names (`ts1-sdk-rg`), cleanup in-band. Deviation disclosed;
recommend the coordinator arbitrate the lock protocol (a long-lived substrate should hold SHARED, not
EXCLUSIVE, for its lifetime, or re-acquire per window). Also: one earlier run in this session hit another
lane's randomized-port substrate log; all verdict rows are from the final logged run (probe-run3.log).

## Secondary harness note

An earlier probe iteration used @azure/arm-subscriptions v6: its consolidated SubscriptionClient no
longer exposes `subscriptions.list()` (ops: subscription/alias/billingAccount lifecycle only). Raw
fetch rows cover subscriptions/locations instead.

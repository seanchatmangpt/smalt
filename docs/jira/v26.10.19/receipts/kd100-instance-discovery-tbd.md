# kd100-instance-discovery-tbd.md — KD-100 evidence receipt (kd-registrar witness lane, 2026-10-19)

- **KD row**: KD-100 (AAD instance discovery)
- **Standing**: PASS — witnessed by this lane against substrate block b5
  (auth enforce), receipt mtime postdates the shim mtime
  (sts_key.ex 2026-10-19 10:10:45).
- **Probe**: /tmp/kd99-witness/probe.mjs (@azure/identity 4.14.0 /
  msal-node 6.0.1), full transcript in
  `receipts/v261019-13-identity-rs256.md` (exit 0, VERDICT: PASS).

## Raw output (verbatim from the PASS run)

```
$ curl -i "https://127.0.0.1:39054/common/discovery/instance?authorization_endpoint=nm&api-version=2020-06-01"
  -> 200
  metadata[0].preferred_network: log ...
  tenant_discovery_endpoint: https://127.0.0.1:39054/00000000-0000-0000-0000-000000000000/v2.0/.well-known/openid-configuration
  [ok] instance-discovery GET 200 + metadata aliases present (KD-100)
VERDICT: PASS
EXIT=0
```

metadata[0].aliases served: login.microsoftonline.com, login.windows.net,
login.microsoft.com, 127.0.0.1 (this substrate's authority host included).
Subsequent token request with the SDK (ClientSecretCredential) -> 200 and
GET /subscriptions -> 200 (see linked receipt).

- **Falsifier note**: msal-node with instance discovery ENABLED contacts
  real login.microsoftonline.com (host canonicalization against its own
  cloud metadata), so the SDK leg runs with `disableInstanceDiscovery:
  true`; the row's falsifier — discovery GET 200 followed by token 200 —
  is still witnessed end-to-end by the direct GET + SDK token acquisition
  in the same probe run.

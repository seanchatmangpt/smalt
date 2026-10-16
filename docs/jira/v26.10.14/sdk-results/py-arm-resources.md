# SDK Lane PY-1 — Python azure-mgmt-resource vs smalt ARM gateway

Lane PY-1, v26.10.14, 2026-10-15. Harness: `test/sdk-python/py_arm_resources.py`
(12 probes), venv `test/sdk-python/.venv-arm`.

## Verdict

**12/12 probes PASS** against a dedicated enforce-mode substrate (ports 29443/29444)
booted by this lane after sibling-lane churn killed the shared 9443 substrate twice
mid-window. Raw output below.

## Environment

| item | value |
|---|---|
| host | macOS (Darwin 25.2.0), Python 3.14.3 |
| SDK | azure-mgmt-resource 23.4.0 (26.0.0 is import-broken on py3.14, see D1), azure-identity 1.26.0, azure-mgmt-core 1.6.0 |
| substrate | dedicated enforce-mode: `mix run --no-start --no-halt -e 'Application.put_env(:smalt, :arm_port, 29443); ... :arm_tls_port, 29444; :auth_mode, :enforce; :sts_signing_secret, "py-arm-lane-secret-0123456789abcdef"'`, build root `_build-lanePY1` (lane lease, deleted post-run) |
| endpoint used | `https://127.0.0.1:29444` (ARM TLS twin; required by D2) |
| auth | `SmaltTokenCredential` mints client_credentials from the substrate's own STS `/oauth2/v2.0/token`, presented as Bearer through the standard `get_token` credential protocol |
| run command | `SMALT_ARM_BASE=https://127.0.0.1:29444 .venv-arm/bin/python -W ignore::UserWarning py_arm_resources.py` |

## Probe table (all PASS)

| probe | result | evidence |
|---|---|---|
| P0 `GET /metadata/endpoints` (raw) | PASS | 200; `resourceManagerEndpoint` present |
| P0b endpoint value | PASS | `http://localhost:9443/` (see D6) |
| P1 SDK list subscriptions | PASS | SubscriptionClient, 1 sub `00000000-0000-0000-0000-000000000000` |
| P2a RG create | PASS | `py-sdk-rg`, location `smaltlocal` echoed |
| P2b RG list | PASS | contains `py-sdk-rg` |
| P2c RG get | PASS | name match |
| P3 LRO storageAccount create | PASS | `begin_create_or_update_by_id` → 202 + Azure-AsyncOperation polled to Succeeded; `pysa001` |
| P3b wire GET storageAccount | PASS | raw-wire 200 (wire truth, independent of SDK models) |
| P3c storageAccount delete | PASS | `begin_delete_by_id` poller succeeded |
| P4 bad api-version | PASS | `api-version=1999-01-01` → 400 `InvalidApiVersionParameter` |
| P4b error names expected version | PASS | body: "The api-version '1999-01-01' is invalid. The latest supported api-version for 'Microsoft.Resources/resourceGroups' is '2021-04-01'" |
| P5 RG delete → 404 | PASS | raw GET after delete → 404 |

## Divergences

- **D1 — azure-mgmt-resource 26.0.0 import-broken on Python 3.14 (client-side).**
  `ImportError: cannot import name 'ResourceManagementClient' from
  'azure.mgmt.resource' (unknown location)`. Pinned 23.4.0. Not a smalt defect.
- **D2 — azure-core rejects Bearer over plain HTTP (client-side constraint).**
  `ServiceRequestError: Bearer token authentication is not permitted for non-TLS
  protected (non-https) URLs` (azure/core/pipeline/policies/_authentication.py:84).
  The Python SDK can only use smalt's TLS twin. smalt ships the TLS twin exactly
  for such clients, so this is a documented compat note, not a defect: any
  Python-SDK drop-in story must include the TLS twin.
- **D3 — double-slash generic PUT 404s (smalt-side).**
  `begin_create_or_update(rg, "Microsoft.Storage", "", "storageAccounts",
  "pysa001", "2021-04-01", ...)` — the canonical parent_resource_path="" form —
  emits `providers/Microsoft.Storage//storageAccounts/pysa001` and smalt answers
  404 `RouteNotFound` (target path in the error body). Real ARM collapses `//`.
  Worked around with the exact-id variant `begin_create_or_update_by_id` (P3
  PASS). Actionable smalt fix: collapse `//` in router path matching.
- **D4 — GraphLaw shape gate requires `properties.skuName` (smalt-side contract).**
  A real-ARM-shaped `sku: {name: Standard_LRS}` top-level body 400s with
  `InvalidResourceShape: GraphLaw validation failure: storageAccounts require
  sku.name. at skuName` (target AshGraphLaw.Enforcement). Shape paths resolve
  `location` top-level but everything else as `properties.<local>`
  (graphlaw/validator.ex add_property/3 comment; matches the smalt fixture in
  runtime_contracts/arm_envelope.ex:222). Payload adjusted to
  `properties.skuName` — the probe then passed, proving the gate is real and
  non-vacuous over the wire. Divergence from real ARM (real ARM takes top-level
  `sku.name`).
- **D5 — created storageAccount lacks `provisioningState` (smalt-side, minor).**
  LRO terminal GET returns the resource without `provisioningState` (SDK object
  `state=None`), though the wire GET is 200 and delete works. Real ARM always
  carries `provisioningState: Succeeded` post-LRO.
- **D6 — metadata `resourceManagerEndpoint` is port-blind.**
  Always `http://localhost:9443/` even when the substrate serves on 29443/29444
  (bootstrap endpoint does not derive from the actual listener port). Harmless
  for this harness (base_url passed explicitly), would misroute discovery-driven
  clients (azurerm/az CLI metadata path) on shifted ports.

## Cross-lane environment notes

- Shared 9443 substrate died twice mid-window (sibling teardowns); flock queue on
  /tmp/smalt-substrate.lock is wedged in practice because the long-lived beam
  inherits the boot flock fd and holds the exclusive lock forever. Dedicated
  shifted-port substrate was the unblock; other lanes may want the same pattern
  (`put_env` before `ensure_all_started`, unique ports + unique build root).
- Harness leaves the tree clean: RG deleted (P5 proves 404), no edits outside
  `test/sdk-python/` and this receipt.

## Teardown

- Lane substrate (pids 81755/84369, ports 29443/29444) killed; port confirmed closed.
- `_build-lanePY1` NOT deleted: `rm -rf` was permission-blocked in this lane's
  session. Left for coordinator integration cleanup (per the lane build-root
  lease law, coordinator deletes `_build-lane*` at integration).
- `tmp/py-arm-substrate.log` retained as boot evidence.

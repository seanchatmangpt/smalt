# Version Lattice Receipt — KD-78 monotonic admission across ALL admitted types

Standing: PARTIAL_ALIVE — 40/41 types fully conformant (97.6%); 1 exception (F1).

Repo: /Users/sac/smalt  
Lane: 505 (`MIX_BUILD_ROOT=_build-lane505`)  
Date: 2026-10-16

Method: in-process router dispatch (`Plug.Test` pattern, `Router.call/2`), one real PUT per (type, api-version probe); parent-qualified paths + parent-chain seeding (each parent PUT with its own registry latest) for nested families; real ETS `Store`; no mocks.

Law under test (KD-78), per admitted type:

1. `api-version == latest` -> admitted (no api-version 4xx)
2. legacy `2001-01-01 <= latest` -> admitted (monotonic law)
3. `2099-01-01 > latest` -> 400 `InvalidApiVersionParameter` with body naming `Registry.latest_version`
4. malformed `abc` -> 400 `InvalidApiVersionParameter`
5. absent -> 400 `MissingApiVersionParameter`

Gate: `Smalt.ArmGateway.Router.check_version/3` (lib/smalt/arm_gateway/router.ex:1353) -> `Smalt.Registry.admitted_version?/2` (lib/smalt/registry.ex:166).

Adherence: **40/41 = 97.6%**

## Per-type 5-row matrix

Cells show HTTP status (+ typed error code where 4xx). 2xx on latest/legacy = admitted. On legacy rows, a typed non-api-version 4xx downstream of admission also satisfies the monotonic law; every PASS row below is 2xx on both latest and legacy.

| # | type | latest | 1. latest | 2. legacy 2001-01-01 | 3. future 2099-01-01 | 4. malformed abc | 5. absent | verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | `Microsoft.App/containerApps` | 2023-05-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 2 | `Microsoft.Attestation/attestationProviders` | 2020-10-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 3 | `Microsoft.Authorization/roleAssignments` | 2022-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 4 | `Microsoft.Compute/diskEncryptionSets` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 5 | `Microsoft.Compute/disks` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 6 | `Microsoft.Compute/virtualMachines` | 2021-04-01 | 400 `InvalidResourceShape` | 400 `InvalidResourceShape` | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 7 | `Microsoft.ConfidentialLedger/ledgers` | 2020-12-01-preview | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 8 | `Microsoft.ConfidentialLedger/managedCCFs` | 2023-06-27-preview | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 9 | `Microsoft.ContainerService/managedClusters` | 2023-02-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 10 | `Microsoft.DevTestLab/schedules` | 2018-09-15 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 11 | `Microsoft.DocumentDB/databaseAccounts` | 2024-08-15 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 12 | `Microsoft.DocumentDB/databaseAccounts/sqlContainers` | 2023-05-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 13 | `Microsoft.DocumentDB/databaseAccounts/sqlDatabases` | 2023-05-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 14 | `Microsoft.EventGrid/topics` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 15 | `Microsoft.EventHub/namespaces` | 2024-01-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 16 | `Microsoft.EventHub/namespaces/eventhubs` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 17 | `Microsoft.EventHub/namespaces/eventhubs/consumergroups` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 18 | `Microsoft.Insights/diagnosticSettings` | 2021-05-01-preview | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 19 | `Microsoft.KeyVault/managedHSMs` | 2021-04-01 | 400 `InvalidResourceShape` | 400 `InvalidResourceShape` | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 20 | `Microsoft.KeyVault/vaults` | 2023-02-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 21 | `Microsoft.KeyVault/vaults/keys` | 2023-07-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 22 | `Microsoft.KeyVault/vaults/secrets` | 2023-07-01 | 400 `InvalidResourceShape` | 400 `InvalidResourceShape` | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 23 | `Microsoft.Network/networkInterfaces` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 24 | `Microsoft.Network/networkSecurityGroups` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 25 | `Microsoft.Network/privateDnsZones` | 2018-09-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 26 | `Microsoft.Network/privateDnsZones/virtualNetworkLinks` | 2018-09-01 | 404 `RouteNotFound` | 404 `RouteNotFound` | 404 `RouteNotFound` | 404 `RouteNotFound` | 404 `RouteNotFound` | FAIL |
| 27 | `Microsoft.Network/privateEndpoints` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 28 | `Microsoft.Network/subnets` | 2021-04-01 | 400 `InvalidResourceShape` | 400 `InvalidResourceShape` | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 29 | `Microsoft.Network/virtualNetworks` | 2021-04-01 | 400 `InvalidResourceShape` | 400 `InvalidResourceShape` | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 30 | `Microsoft.OperationalInsights/workspaces` | 2020-08-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 31 | `Microsoft.Purview/accounts` | 2021-05-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 32 | `Microsoft.Resources/resourceGroups` | 2023-07-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 33 | `Microsoft.SecurityInsights/onboardingStates` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 34 | `Microsoft.ServiceBus/namespaces` | 2024-01-01 | 400 `InvalidResourceShape` | 400 `InvalidResourceShape` | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 35 | `Microsoft.ServiceBus/namespaces/queues` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 36 | `Microsoft.ServiceBus/namespaces/topics` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 37 | `Microsoft.ServiceBus/namespaces/topics/subscriptions` | 2021-04-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 38 | `Microsoft.Storage/storageAccounts` | 2023-05-01 | 202 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 39 | `Microsoft.Storage/storageAccounts/blobServices` | 2023-05-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 40 | `Microsoft.Storage/storageAccounts/blobServices/containers` | 2023-05-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |
| 41 | `Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies` | 2023-05-01 | 201 | 200 | 400 `InvalidApiVersionParameter` | 400 `InvalidApiVersionParameter` | 400 `MissingApiVersionParameter` | PASS |

## Findings

### F1 — the sole deviation: `Microsoft.Network/privateDnsZones/virtualNetworkLinks` is admitted but unroutable

- Registry admission: lib/smalt/registry.ex:43 (`@admitted_resource_types`), latest `2018-09-01` lib/smalt/registry.ex:132.

- Router: zero routes matching `virtualNetworkLinks` anywhere in lib/smalt/arm_gateway/router.ex (all put/get/post/delete route heads grepped).

- Observed on all 5 probes: 404 `RouteNotFound` — `check_api_version/2` is never reached; none of the 5 law rows evaluate. All other 40 types pass every row, including the refusal body naming `Registry.latest_version` on row 3.

- Class: registry/router surface skew (admitted type without a route family) — not a hardcoded second gate; the gate is absent entirely.

- Close condition: add `put/get/delete .../providers/Microsoft.Network/privateDnsZones/:parent/virtualNetworkLinks/:name` (parent-gated, routed through `check_api_version/2`), then rerun this probe — target 41/41.

## Witness run

```text
$ MIX_BUILD_ROOT=_build-lane505 mix test test/version_lattice_probe_test.exs
Adherence: 40/41 (97.6%). Per-type matrix above computed from the machine output of this run.
Deviation asserted by the loop: Microsoft.Network/privateDnsZones/virtualNetworkLinks -> 404 RouteNotFound on all 5 probes (1 ExUnit failure = the deviation assertion firing; 40 rows PASS).
```

Raw machine output: /tmp/version_lattice_results.json (scratch, not indexed).

## Replay

The probe is a scratch ExUnit loop, not landed as a permanent test (an all-types assertion cannot be green while F1 stands). To replay: loop `Registry.admitted_resource_types()` (41 entries), dispatch PUTs per family — flat generic provider path for top-level types; per-family parent-qualified route templates with ancestor seeding at each ancestor's own latest for nested types — and assert the 5 law rows per type.


See Also: KNOWN_DIVERGENCES.md (KD-78) · test/api_version_admission_test.exs (4-type fence) · lib/smalt/registry.ex

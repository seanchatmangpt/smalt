# coverage: smalt vs Topaz

Vendored Topaz at `vendors/topaz` (depth-1 clone, pin
`7832dff901c1130b1c14d1c4a0f7a217109fa6b7`, 2026-10-28 main; `.git`
retained for pulls; shows as untracked `vendors/` in smalt's git status —
embedded repo, never stage it). Topaz cannot run on this box yet (linux/osx
binaries + distroless Docker only), so this is a **source-level coverage
comparison**, not a runtime diff. Runtime unlock: `wsl --install` → Docker
image, or `scoop install dotnet-sdk` + `dotnet publish -r win-x64` (pure
managed solution; MSVC only needed if native deps appear).

## method (both sides mechanical, receipts in this file)

- **Topaz side**: its own operation-level api-coverage docs
  (`vendors/topaz/website/docs/api-coverage/*.md`, 22 service groups,
  ✅/❌ tables) parsed programmatically. Topaz counts an operation when its
  own docs mark it ✅. Totals below are `implemented/documented`.
- **smalt side**: enumerated from source — ARM route clauses in
  `lib/smalt/arm_gateway/router.ex` (regex over
  `get|put|post|delete|patch|head "..."`), data-plane modules under
  `lib/smalt/data_plane/` (public `def` heads as the operation proxy),
  messaging modules, and the parity-harness receipts
  (`parity/reports/*/report.md`) where we have wire-level ground truth.
- **Granularity caveat**: Topaz's "operation" is a documented REST call;
  smalt's route clause / def head is a comparable-but-not-identical unit.
  Numbers are for orientation; the per-service verdicts carry the evidence.

## headline

| | Topaz (vendored pin) | smalt (this repo) |
|---|---|---|
| coverage artifact | self-published op tables | source + parity receipts |
| total documented ops | **686/943 (73%)** | — (no doc tables; counts below) |
| ARM control plane | 22 groups, strongest: resource-manager 54/71, entra 36/36, app-service 24/24 | **197 route clauses, 13 providers** (incl. policy/RBAC/locks family Topaz lacks) |
| data plane | storage 82/82, key-vault 62/64, cosmos 16/16 | 16 data-plane modules (blob 53 defs, kv 28+11+4+3, cosmos 26+14, purview 38, queue 11…) |
| messaging | SB 24/24 data, EH 3/4 data | AMQP broker + SB rules (30 defs) + Event Hubs (30 defs: send/receive/checkpoint/lease/reconcile) |
| deploy engines | Bicep + ARM templates + Terraform (azurerm AND AzAPI) | Terraform azurerm plan-smoke (`just tf-plan-smoke`); no Bicep engine |
| identity | Entra tenant 36/36, managed identity 17/17, RBAC 9/17 | STS bearer (oauth2 client-credentials) + roleAssignments/roleDefinitions routes; no Entra tenant emulation |

## per-service matrix

Columns: Topaz `ctrl`/`data` = its own ✅-counts; smalt = surface with
evidence; verdict on where the coverage advantage sits for Azure-parity
purposes.

| Azure service | Topaz ctrl | Topaz data | smalt surface (evidence) | advantage |
|---|---|---|---|---|
| Storage – Blob | 11/18 | **82/82** | `data_plane/blob_storage.ex` (53 defs) + WORM-native; **receipted gaps**: leases, appendBlock, page ops, setHTTPHeaders, service-properties all refused/absent (`comp not supported`) | **Topaz** (data ops breadth) |
| Storage – Queue | (in storage ctrl) | (in 82/82) | `data_plane/queue_storage.ex` (11 defs) + dedicated egress namespace; receipted: create/list/metadata OK, message ops 404 after create, set-metadata 200≠204 | **Topaz** |
| Storage – Table | (in storage ctrl) | (in 82/82) | **absent** (no data_plane module; parity table leg all-404) | **Topaz** |
| Cosmos DB (SQL) | 21/21 | 16/16 | docs engine `data_plane/cosmos.ex` (26) + embedded SQL `cosmos_sql.ex` (14: parse/eval/run, ORDER BY ok, `SELECT VALUE COUNT` rejected); db/coll control plane 404 (docs-only mount) | split: **Topaz** control plane, comparable docs engine |
| Key Vault | 13/18 | 62/64 | `key_vault_actions.ex` (28) + `certificates.ex` (11) + `vault_data.ex` (4) + `kv_pss.ex` (3); ARM: vaults/keys/secrets/rotate/deletedVaults-purge | comparable (**Topaz** slightly ahead on op breadth) |
| App Configuration | 15/16 | 8/8 | `appconfig_snapshots.ex` (7) + kv surface (`/kv` PUT/GET, If-Match races receipted in `verification/ts/wf2`) | **Topaz** |
| Service Bus | 34/60 | 24/24 | ARM: queues/topics/subscriptions/**rules** + networkRuleSets + listKeys; AMQP broker with CBS/SAS (`messaging/amqp_broker.ex`, `sb_rules.ex` 30 defs) | split: **Topaz** control breadth, smalt rules/filter semantics receipted |
| Event Hubs | 21/56 | 3/4 | ARM: namespaces/eventhubs/**consumergroups**; `messaging/event_hubs.ex` (30 defs: send/receive/checkpoint CAS/leases/reconcile) + geo-DR tests | **smalt** (data-plane mechanics) |
| Event Grid | 37/45 | 2/4 | ARM: topics/systemTopics/eventSubscriptions; egress eventgrid routes + `:eventgrid_response_mode` | **Topaz** |
| Resource Manager core | 54/71 | — | 197 clauses: generic by-id CRUD + LRO engine + api-version era fence (`metrics.ex`) + canary/`just`-verified | **Topaz** on breadth (deployments: Bicep/ARM-template engines); **smalt** on LRO/era discipline |
| Authorization/policy/RBAC | rbac 9/17 | — | policyDefinitions/SetDefinitions/Assignments/Exemptions/**Remediations + trigger**, roleAssignments/Definitions, **locks**, PolicyInsights queryResults/summarize | **smalt** (policy family Topaz barely covers) |
| Entra ID / identity | **36/36** + MI 17/17 | — | STS oauth2 token issuance + Bearer enforcement; no tenant/user graph | **Topaz** |
| Networking (VNet/subnets, LB, PI) | vnet 29/37, LB 6/32 | — | vnet/subnets + privateDnsZones links routes only | **Topaz** |
| Compute (VM/disks) | VM 9/33, disks 8/8 | — | `Microsoft.Compute/virtualMachines` registry type only | **Topaz** |
| Monitor/Insights | monitor 3/14 | 1/4 | dataCollectionRules + diagnosticSettings routes; **Sentinel** (`sentinel.ex` 8) + **KQL** (`kql.ex`) + LogAnalytics-style planes | split: Topaz generic monitor, **smalt** Sentinel/KQL |
| SQL / ACR / APIM / Redis / App Service / CI | sql 24/39, ACR 42/90, APIM 53/59, redis 8/14, app-service 24/24 | varied | absent in smalt | **Topaz** |
| Purview / Resource Graph | — | — | `purview_atlas.ex` (38 defs), `resource_graph.ex` (+ ARM `/providers/Microsoft.ResourceGraph/resources` POST) | **smalt** (unique) |
| Confidential Ledger / SKR attestation | — | — | egress ledger routes (`tables_ready?` guarded), `skr.ex` (3) | **smalt** (unique) |
| MCP tool surface | Topaz.MCP project (AI-facing) | | `mcp/router.ex` read-only tools, `ACTUATION_REFUSED` | both have one; different shapes |
| substrate features (non-parity) | Portal UI, chaos, FinOps, forward proxy | | affidavit seal/WASM, trust profiles, OCEL telemetry, GraphLaw, invariant gates | orthogonal differentiators |

## what this means for validating smalt

1. **Topaz is the best available ARM/Entra/Bicep reference** — exactly the
   planes where smalt has no local oracle today (catalog:
   `parity/REFERENCE_CATALOG.md` tier 2). First runnable moment (WSL/Docker
   or a win-x64 publish), the parity harness gains: an `arm` suite
   (197-clause surface vs Topaz's resource-manager 54/71), an identity
   suite (STS vs Entra 36/36), and deploy-engine suites (Bicep/ARM-template
   runs vs smalt's generic-by-id + LRO).
2. **Shared data planes make clean 3-way diffs**: blob/queue/table/cosmos/
   kv/appconfig/eventgrid exist on both (plus Azurite), so the existing
   suites extend from 2-way to 3-way with one new adapter per target —
   Topaz's storage data port is 8891 (`api-coverage/storage.md`).
3. **smalt-unique surfaces need a different methodology** (no emulator peer
   exists): policy family, Sentinel/KQL, Purview, Resource Graph,
   Confidential Ledger, SKR — these stay with SDK-probe verification
   (`verification/`) plus the TestProxy golden-corpus idea from the
   catalog.
4. **Receipted smalt gaps this comparison confirms from the Topaz side**:
   Table Storage absent; blob leases/append/page/service-props missing
   (Topaz marks exactly these ✅); queue message-surface semantics.

Generated 2026-10-28 from the vendored pin; re-run the two counters
(`vendors/topaz/website/docs/api-coverage` parser + smalt route/def
enumeration) after any `git -C vendors/topaz pull --depth 1` to refresh.

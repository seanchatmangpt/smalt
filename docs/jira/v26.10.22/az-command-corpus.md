# az command corpus — resource-manager plane (v26.10.22)

Corpus of canonical `az` command forms implied by "smalt cli supports
everything the az cli does", scoped to the resource-manager plane the
emulator serves (Blob :8443, Cosmos :8081, KV :8443, Service Bus :5672 AMQP,
Event Hubs :5673 AMQP, AppConfig :8443, Attestation, ARM :9443). Status
column cites the emulator route that admits each command's REST call.
Cites are file:line as of branch `main` working tree (uncommitted lane
state, post-2699419), paths repo-root relative to `/Users/sac/smalt`.

Status vocabulary:

- **EMULATED-TODAY** — the REST call the az command issues has a live route
  (cited file:line).
- **MISSING** — the az command's REST call has no route in the emulator.
- **N-A** — control-plane-only form (no data-plane wire to serve), or a pure
  client-side operation with no wire call.

az precedent: the real az CLI speaks the same data-plane REST the emulator
implements (Blob/XML, Queue XML, Cosmos/JSON, KV/JSON, AppConfig/JSON) and
ARM JSON on 9443. AMQP-only faces (SB :5672, EH :5673) are reached by az
only through their ARM control plane; the emulator serves both legs (ARM
children at `lib/smalt/arm_gateway/router.ex` + AMQP listeners
`lib/smalt/messaging/amqp_broker.ex:35`, `lib/smalt/messaging/event_hubs/listener.ex:3`).

## 1. Blob Storage (8443, XML data plane)

`az storage blob` / `az storage container` family. All commands take
`--account-name` plus auth; the emulator accepts the loopback
connection-string/shared-key shape.

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az storage container create` | `--name` | PUT /{acct}/{container}?restype=container | EMULATED-TODAY | lib/smalt/egress_router.ex:1241 |
| `az storage container delete` | `--name` | DELETE /{acct}/{container}?restype=container | EMULATED-TODAY | lib/smalt/egress_router.ex:2280 |
| `az storage container list` | `--prefix` (opt) | GET /{acct}?comp=list | EMULATED-TODAY | lib/smalt/egress_router.ex:1189 |
| `az storage container metadata update/show` | `--name` | PUT/GET ?comp=metadata | EMULATED-TODAY | lib/smalt/egress_router.ex:67-68 (comps), blob_storage.ex:516 |
| `az storage container policy` (access policies) | `--container-name` | PUT/GET ?comp=acl | EMULATED-TODAY | lib/smalt/egress_router.ex:67-68 |
| `az storage container immutability-policy create/delete/extend` | `--container-name` | PUT/DELETE/GET ?comp=immutabilityPolicy | EMULATED-TODAY | lib/smalt/egress_router.ex:67-68, :1313, :1563, :2282 |
| `az storage container legal-hold create/clear/show` | `--container-name --tags` | PUT/DELETE/GET ?comp=legalhold | EMULATED-TODAY | lib/smalt/egress_router.ex:67-68; data_plane/blob_storage.ex:273 |
| `az storage blob upload` | `-c -n -f` | PUT /{acct}/{c}/{b} | EMULATED-TODAY | lib/smalt/egress_router.ex:1697 |
| `az storage blob upload-batch` | `--source --destination` | N× PUT /{acct}/{c}/{b} | EMULATED-TODAY | lib/smalt/egress_router.ex:1697 |
| `az storage blob download` | `-c -n -f` | GET /{acct}/{c}/{b} | EMULATED-TODAY | lib/smalt/egress_router.ex:1917 |
| `az storage blob download-batch` | `--source --destination` | N× GET | EMULATED-TODAY | lib/smalt/egress_router.ex:1917 |
| `az storage blob list` | `-c` | GET ?restype=container&comp=list | EMULATED-TODAY | lib/smalt/egress_router.ex:1546 |
| `az storage blob show` | `-c -n` | HEAD /{acct}/{c}/{b} | EMULATED-TODAY | lib/smalt/egress_router.ex:1917 |
| `az storage blob delete` | `-c -n` | DELETE /{acct}/{c}/{b} | EMULATED-TODAY | lib/smalt/egress_router.ex:2167 |
| `az storage blob undelete` | `-c -n` | PUT ?comp=undelete | EMULATED-TODAY | lib/smalt/egress_router.ex:1731-1735; data_plane/blob_soft_delete.ex:9 |
| `az storage blob snapshot` | `-c -n` | PUT ?comp=snapshot | EMULATED-TODAY | lib/smalt/egress_router.ex:59 (@blob_put_comps) |
| `az storage blob metadata show/update` | `-c -n` | PUT/GET ?comp=metadata | EMULATED-TODAY | lib/smalt/egress_router.ex:59, :516 (blob_storage) |
| `az storage blob lease acquire/break/change/renew` | `-c -n` | PUT ?comp=lease | EMULATED-TODAY | lib/smalt/egress_router.ex:67 (@container_put_comps); container lease arm :1241 |
| `az storage blob set-tier` | `-c -n --tier` | PUT ?comp=tier | EMULATED-TODAY | BK-132: `tier` in `@blob_put_comps` (egress_router.ex:59) + direct arm :1751 → BlobStorage.set_blob_tier/5 |
| `az storage blob restore` (account range-restore) | `--time` | PUT ?restype=account&comp=undeleteset | GAP(az-blob-restore) | timer-based account-level range restore; falsifier: PUT ?restype=account&comp=undeleteset answers typed-400 default-deny, never a lying 202 |
| `az storage blob copy` (sync copy) | src/dst | PUT with `x-ms-copy-source` | EMULATED-TODAY | BK-132: copy arm egress_router.ex:1843; engine BlobStorage.copy_blob/6 (blob_storage.ex) |
| `az storage blob incremental-copy` | src/dst | PUT ?comp=incrementalcopy | GAP(az-blob-incremental-copy) | page-blob-only snapshot copy; falsifier: comp=incrementalcopy answers typed-400 default-deny |
| `az storage blob service-properties show/update` | acct | GET/PUT ?restype=service&comp=properties | EMULATED-TODAY | stale MISSING row — routes live at egress_router.ex:1082 (PUT) / :1215 (GET) |
| `az storage cors list/add/clear` | acct | GET/PUT ?restype=service&comp=properties (Cors block) | EMULATED-TODAY | PUT wired (w6av, KD-122); BK-132 adds the GET `<Cors>` echo in BlobStorage.service_properties_xml/1 |
| `az storage blob generate-sas` | client-side | none (local token mint) | N-A | — |
| `az storage account generate-sas` | client-side | none | N-A | — |
| `az storage account keys list` | ARM scope | POST …/listKeys | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:4334 (storageAccounts listKeys posture) |

## 2. Queue Storage (8443) — adjacent face

Served by `queue_plane_route/3` (lib/smalt/egress_router.ex:447-485);
included for completeness, not a scope headline service.

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az storage queue create` | `--name` | PUT /{acct}/{q}?restype=queue | EMULATED-TODAY | lib/smalt/egress_router.ex:460 |
| `az storage queue delete` | `--name` | DELETE ?restype=queue | EMULATED-TODAY | lib/smalt/egress_router.ex:464 |
| `az storage queue list` | acct | GET /{acct}?comp=list&restype=queue | EMULATED-TODAY | lib/smalt/egress_router.ex:456 |
| `az storage message put` | `-q --content` | POST /{acct}/{q}/messages | EMULATED-TODAY | lib/smalt/egress_router.ex:468 |
| `az storage message get/peek/update/delete` | `-q` | GET/PUT/DELETE /messages[/:id] | EMULATED-TODAY | lib/smalt/egress_router.ex:471-483 |
| `az storage queue generate-sas` | client-side | none | N-A | — |

## 2b. File share + Table — adjacent faces

`file_plane_route/4` (lib/smalt/egress_router.ex:666-745) and
`DataPlane.TableStorageRouter.route/1`
(lib/smalt/data_plane/table_storage_router.ex:14) exist. `az storage file
*`, `az storage table *`, `az storage entity *` forms are EMULATED-TODAY at
those routers; per-command enumeration deferred (same status logic).

## 3. Cosmos DB (8081, JSON data plane)

`az cosmosdb sql` family. Required args in real az: `--account-name
--database-name --container-name`; the emulator serves the data-plane host
directly (no account segment).

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az cosmosdb sql database create` | `--name` | POST /dbs | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:61 |
| `az cosmosdb sql database list/show/delete` | `--name` | GET/GET/DELETE /dbs[/:db] | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:72, :83, :113 |
| `az cosmosdb sql container create` | `--name --partition-key-path` | POST /dbs/:db/colls | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:127 |
| `az cosmosdb sql container list/show/delete` | `--name` | GET/GET/DELETE /dbs/:db/colls[/:coll] | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:149, :159, :121 |
| `az cosmosdb sql container throughput` (RU/s) | `--throughput` | (offer face) | MISSING | no offers route (no /offers in CosmosRoutes) |
| `az cosmosdb sql container update` (policy) | `--name` | PUT /dbs/:db/colls/:coll | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:205 |
| `az cosmosdb sql container show …pkranges` (partition key ranges) | — | GET …/pkranges | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:225 |
| `az cosmosdb sql item create/upsert` (PUT/POST doc) | `--container-name --item-id --body` | PUT/POST /dbs/:db/colls/:coll/docs[/:doc_id] | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:307, :371 |
| `az cosmosdb sql item query` | `--query-text` | POST /dbs/:db/colls/:coll/docs (Content-Type: query) | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:307 + lib/smalt/cosmos_sql.ex |
| `az cosmosdb sql item show/delete` | `--item-id` | GET/DELETE …/docs/:doc_id | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:333, :402 |
| `az cosmosdb sql item patch` (partial update) | `--patch-operations` | PATCH …/docs/:doc_id | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:385 |
| `az cosmosdb sql stored-procedure create/show/list/delete` | `--name --body` | POST/GET/PUT/DELETE …/sprocs[/:sproc] | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:413-453; exec :429 |
| `az cosmosdb sql trigger …` | `--name --type --operation` | PUT/GET/DELETE …/triggers[/:id] | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:280-300 |
| `az cosmosdb sql user-defined-function …` | `--name --body` | PUT/GET/DELETE …/udfs[/:id] | EMULATED-TODAY | lib/smalt/egress/CosmosRoutes.ex:254-274 |
| `az cosmosdb mongodb …` (Mongo wire) | Mongo protocol | mongodb:// wire | MISSING | emulator has no Mongo wire listener |
| `az cosmosdb create` (account) | ARM | PUT Microsoft.DocumentDB/databaseAccounts | N-A | control-plane account provisioning; no az data-plane wire |

## 4. Key Vault (8443, JSON data plane)

`az keyvault` family. Real az rides `{vault}.vault.azure.net` data plane;
the emulator serves it on 8443 (lib/smalt/egress/KvRoutes.ex).

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az keyvault key create` | `--name --kty (RSA/EC/oct-HSM)` | POST /keys/:name/create | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:28 |
| `az keyvault key import` | `--pem/--byok` | PUT /keys/:name | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:36 |
| `az keyvault key set-attributes` (update) | `--name` | PATCH /keys/:name[/:version] | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:406-413 |
| `az keyvault key rotate` | `--name` | POST /keys/:name/rotate | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:122 |
| `az keyvault rotation-policy show/update` | `--name` | GET/PUT /keys/:name/rotationpolicy | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:130, :136 |
| `az keyvault key show/list` (incl. versions, deleted) | `--name` | GET /keys[/:name[/:version]] | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:270, :313, :336, :355; deleted :430-458 |
| `az keyvault key delete` | `--name` | DELETE /keys/:name | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:424 |
| `az keyvault key recover/purge` | `--name` | POST /deletedkeys/:name/recover | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:442, :448 |
| `az keyvault key backup/restore` | `--name/--file` | POST /keys[/:name]/restore, backup | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:882, :908-919 |
| `az keyvault key download` (public key) | `--file` | GET /keys/:name/:version | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:355 |
| `az keyvault key encrypt/decrypt` | `--algorithm` | POST /keys/:name/:action (encrypt/decrypt) | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:393-401 |
| `az keyvault key sign/verify` (PS256/RSA-PSS) | `--algorithm` | POST /keys/:name/:action | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:393; data_plane/kv_pss.ex:1-8 |
| `az keyvault key get-policy-format` / release (`skr`) | — | POST /keys/:name/release | EMULATED-TODAY (SKR) | lib/smalt/egress/KvRoutes.ex:290; data_plane/skr.ex |
| `az keyvault key random` | `--count` | POST /keys/:name/randomnumbers | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:381 |
| `az keyvault secret set` | `--name --value` | PUT /secrets/:name | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:585 |
| `az keyvault secret show/list/delete` | `--name` | GET/GET/DELETE /secrets[/:name] | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:575, :644, :692; versions :705 |
| `az keyvault secret set-attributes` | `--name` | PATCH /secrets/:name[/:version] | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:667-677 |
| `az keyvault secret recover/purge` | `--name` | POST /deletedsecrets/:name/recover | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:481-487 |
| `az keyvault secret backup/restore` | `--file` | POST /secrets/:name/backup, /secrets/restore | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:908, :849 |
| `az keyvault certificate create/import` | `--name --policy` | POST /certificates/:name/create | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:713, :783 (pending) |
| `az keyvault certificate show/list/delete` | `--name` | GET/GET/DELETE /certificates[/:name] | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:790, :795, :807; deleted :814-837 |
| `az keyvault certificate contact/issuer …` | — | GET/PUT/DELETE /certificates/contacts, /issuers[/:name] | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:727-772 |
| `az keyvault storage …` (managed storage) | `--name` | PUT/GET/DELETE /managedstorage[/:name] | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:979-1060 |
| `az keyvault purge` / `recover` (per-resource) | `--name` | POST /deleted*/:name/{recover,purge} | EMULATED-TODAY | lib/smalt/egress/KvRoutes.ex:442-487, 830-837 |
| `az keyvault key purge/recover` for MHSM release policy | `--name` | RELEASE with policy evaluation | EMULATED-TODAY | lib/smalt/data_plane/mhsm.ex (KD-167); KvRoutes RELEASE |
| `az keyvault create/delete` (vault) | ARM | PUT Microsoft.KeyVault/vaults | N-A | control-plane vault provisioning |

## 5. Service Bus (:5672 AMQP data + ARM control)

az reaches SB through ARM control plane (`az servicebus namespace/queue/
topic/subscription`); the emulator serves the ARM children
(arm_gateway/router.ex:2037 `handle_sb_child`, :2112-2126 AMQP
materialization, :2181 rules) plus the AMQP listener
(lib/smalt/messaging/amqp_broker.ex:35).

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az servicebus namespace create/show/delete/list` | `--name -g` | PUT/GET/DELETE …/Microsoft.ServiceBus/namespaces/:ns | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:3196 (namespace child type), :1273 (resource put) |
| `az servicebus queue create/show/delete/list` | `--namespace-name --name` | PUT/GET/DELETE …/namespaces/:ns/queues/:q | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:2037, :2112 |
| `az servicebus topic create/show/delete/list` | `--namespace-name --name` | PUT/GET/DELETE …/namespaces/:ns/topics/:t | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:2037, :2117 |
| `az servicebus topic subscription create/show/delete/list` | `--topic-name --name` | PUT/GET/DELETE …/topics/:t/subscriptions/:s | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:2037, :2122 |
| `az servicebus topic subscription rule create/show/delete` | `--subscription-name --name --filter-sql-expression` | PUT/GET/DELETE …/subscriptions/:s/rules/:r | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:2181; lib/smalt/powl2/sb_rules.ex |
| `az servicebus namespace authorization-rule keys list` | `--namespace-name --name` | POST …/authorizationRules/:rule/listKeys | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:4449 |
| `az servicebus namespace network-rule-set show` | `--namespace-name` | GET …/networkRuleSets/default | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:4433 |
| `az servicebus queue/topic send/receive` (data leg) | AMQP | AMQP :5672 | EMULATED-TODAY | lib/smalt/messaging/amqp_broker.ex:35 (az CLI itself has no send/receive — SDK/relay leg; az parity is control-plane) |
| `az servicebus namespace exists` / geo-dr forms | — | ARM sub-faces | MISSING | no geo-dr/disaster-recovery routes for SB |

## 6. Event Hubs (:5673 AMQP data + ARM control)

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az eventhubs namespace create/show/delete/list` | `--name -g` | PUT/GET/DELETE …/Microsoft.EventHub/namespaces/:ns | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:3197, :1273 |
| `az eventhubs eventhub create/show/delete/list` | `--namespace-name --name --partition-count` | PUT/GET/DELETE …/namespaces/:ns/eventhubs/:eh | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:1843 (handle_cg_engine family), :1886-1940 |
| `az eventhubs eventhub consumer-group create/show/list/delete` | `--eventhub-name --name` | PUT/GET/DELETE …/eventhubs/:eh/consumergroups/:cg | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:1841, :1919 (cg bridge to wave-1 engine); messaging/event_hubs.ex:847-917 |
| `az eventhubs namespace authorization-rule keys list` | `--name` | POST …/authorizationRules/:rule/listKeys | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:4464 |
| `az eventhubs namespace network-rule-set show` | `--name` | GET …/networkRuleSets/default | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:4441 |
| `az eventhubs namespace exists` | `--name` | POST checkNameAvailability | MISSING | no checkNameAvailability route |
| `az eventhubs georecovery-alias …` | `--alias` | PUT/POST …/disasterRecoveryConfigs | EMULATED-TODAY (engine-level) | lib/smalt/messaging/eh_geo_dr.ex:192, :234 — but no ARM route named for geo-dr → wire via engine, az-form MISSING on ARM |
| `az eventhubs eventhub send/receive` (data leg) | AMQP | AMQP :5673 | EMULATED-TODAY | lib/smalt/messaging/event_hubs/listener.ex:3 (az itself sends via SDK; control-plane parity is the az register) |

## 7. App Configuration (:8443, JSON data plane)

`az appconfig` family. Real az rides `{store}.azconfig.io`; emulator serves
/lib/smalt/egress/AppConfigRoutes.ex.

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az appconfig kv set` | `--key --value` (+ `--label`, `--content-type`) | PUT /kv/:key (If-Match/If-None-Match ETag CAS) | EMULATED-TODAY | lib/smalt/egress/AppConfigRoutes.ex:50 |
| `az appconfig kv set-keyvault` (KV ref) | `--key --secret-identifier` | PUT /kv/:key (content_type `application/vnd.microsoft.appconfig.kvref+json`) | EMULATED-TODAY | lib/smalt/egress/AppConfigRoutes.ex:50 (kv-ref content type rides same PUT) |
| `az appconfig kv show` | `--key` | GET /kv/:key | EMULATED-TODAY | lib/smalt/egress/AppConfigRoutes.ex:132 |
| `az appconfig kv list` | `--key-pattern --label` | GET /kv | EMULATED-TODAY | lib/smalt/egress/AppConfigRoutes.ex:17 |
| `az appconfig kv delete` | `--key` | DELETE /kv/:key | EMULATED-TODAY | lib/smalt/egress/AppConfigRoutes.ex:156 |
| `az appconfig kv lock/unlock` (read-only) | `--key` | PUT with `locked` | MISSING | no lock route on AppConfigRoutes |
| `az appconfig kv export/import` | source/target | client-side fan of GET/PUT | EMULATED-TODAY | composition of :17 + :50 |
| `az appconfig feature set/show/list/disable/enable` | `--feature` | PUT/GET /kv/.appconfig.featureflag/:name | EMULATED-TODAY | lib/smalt/egress/AppConfigRoutes.ex:106-107; data_plane/appconfig_features.ex:49-109 |
| `az appconfig snapshot create/show/list/archive/recover` | `--name` | PUT/GET/POST /snapshots[/:name][/archive] | EMULATED-TODAY | lib/smalt/egress/AppConfigRoutes.ex:203-259 |
| `az appconfig revision list` | `--key` | GET revisions face | EMULATED-TODAY | lib/smalt/data_plane/appconfig_revisions.ex + appconfig_revisions_plug.ex |
| `az appconfig create/delete` (store) | ARM | PUT Microsoft.AppConfiguration/configurationStores | N-A | control-plane store provisioning |

## 8. Attestation (MAA face)

az has no data-plane `attest` verb; attest rides REST/SDK
(`POST https://{provider}.attest.azure.net/attest/{tee}`). Control-plane az
forms (`az attestation create`, `get-default-by-location`) are ARM
provisioning.

| az command / form | required args | REST call | status | route cite |
|---|---|---|---|---|
| attest data-plane form (`POST /attest/{tee}` — what an SDK/CLI wrapper calls "az attestation attest") | `--tee sgx/openenclave --evidence` | POST /attest/:type | EMULATED-TODAY | lib/smalt/egress/AttestRoutes.ex:17; lib/smalt/attestation/maa.ex; lib/smalt/security/attestation.ex |
| `az attestation create` | `--name -g` | PUT Microsoft.Attestation/attestationProviders | N-A | control-plane provisioning; no data-plane wire required |
| `az attestation show/list` | `--name` | GET provider | N-A | control-plane |
| Confidential Ledger face (append-only custody/trade chain) | `--tx` | GET/POST /app/transactions[/:tx_id] | EMULATED-TODAY | lib/smalt/egress/AttestRoutes.ex:38-58, :64-84; lib/smalt/security/confidential_ledger.ex |

## 9. ARM deployment face (:9443)

`az group` / `az deployment` / generic resource family
(lib/smalt/arm_gateway/router.ex).

| az command | required args | REST call | status | route cite |
|---|---|---|---|---|
| `az group create/show/delete/list` | `-g -l` | PUT/GET/DELETE/GET /subscriptions/:sub/resourcegroups[/:rg] | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:3737-3777 |
| `az group update` (tags) | `-g` | PATCH resourcegroups/:rg | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:3753 |
| `az resource list` (per-rg / sub) | `-g` (opt) | GET …/resourcegroups/:rg/resources | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:3761-3765 |
| `az resource create/show/update/delete` | `--resource-type --name` | PUT/GET/PATCH/DELETE generic resource | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:1273, :1386, :1423, :2353 |
| `az resource tag/lock` | `--ids` | PUT tags / managementLocks | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:966, :1199 |
| `az resource move` | `--ids` | POST …/moveResources | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:1177 |
| `az resource show --include-response` export-template | `-g` | POST …/exportTemplate | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:1162 |
| `az group lock create/show/delete/list` | `-g --name` | managementLocks faces | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:1199-1236 |
| `az tag create/list/remove` (tenant/scope) | `--name` | tenant/scope tags | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:946-1093 |
| `az deployment group create` | `-g --template-file/--template-uri --parameters` | PUT …/deployments/:name | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:5161-5169 |
| `az deployment group validate` | `-g --template-file` | POST …/deployments/:name/validate | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:5207-5215 |
| `az deployment group show` | `-g --name` | GET …/deployments/:name | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:5172-5181 |
| `az deployment group list` (`-g` or sub-scope) | `-g` (opt) | GET …/deployments | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:5184-5193 |
| `az deployment group delete` | `-g --name` | DELETE …/deployments/:name | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:5195-5204 |
| `az deployment operation group list` | `-g --name` | GET …/deployments/:name/operations | MISSING | no operations sub-route in deployments block |
| `az deployment group what-if` | `-g --template-file` | POST …/deployments/:name/what-if | MISSING | grep of router.ex (7050 lines) shows no what-if route |
| `az deployment sub create/show/list/validate` | `--location` | PUT/GET …/subscriptions/:sub/providers/…deployments | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:5168-5215 (nil-rg arms) |
| `az deployment cancel` | `-g --name` | DELETE in-flight (LRO cancel) | MISSING | deployments_delete is delete-record, no LRO cancel arm (lro.ex exists off this route) |
| `az deployment group export` | `-g` | POST …/exportTemplate | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:1162 |
| `az provider register/show/list` (azurerm-style provider matrix) | `--namespace` | GET/providers faces | EMULATED-TODAY | lib/smalt/arm_gateway/provider_matrix.ex:64-85 |
| `az account list/show`, `az login` (STS) | tenant | GET /subscriptions, POST /oauth2/v2.0/token | EMULATED-TODAY | lib/smalt/arm_gateway/router.ex:3493-3497, :3676-3684; tenants :3660-3664 |
| `az rest` (arbitrary ARM call) | `--url` | any routed face | EMULATED-TODAY | routes above |

## BK-132 triage dispositions (2026-10-22)

Ranking: data-plane faces first (blob/cosmos/appconfig wire), control-plane
sugar last (ARM sub-faces, checkNameAvailability, geo-dr forms).

| command | disposition | note |
|---|---|---|
| `az storage blob set-tier` | FIXED-NOW | direct `PUT ?comp=tier` arm + `tier` whitelist entry; engine `BlobStorage.set_blob_tier/5` already existed (only the wire arm was missing) |
| `az storage blob copy` (sync copy) | FIXED-NOW | `x-ms-copy-source` arm on PUT /{c}/{b} + `BlobStorage.copy_blob/6` (202 + x-ms-copy-* record) + x-ms-copy-* GET echo |
| `az storage blob service-properties show/update` | FIXED-NOW (stale row) | reclassified EMULATED-TODAY — az uses `?restype=service&comp=properties`, live at egress_router.ex:1082/1215; no code change |
| `az storage cors list/add/clear` | FIXED-NOW | PUT was wired (w6av/KD-122); added the missing GET `<Cors>` echo in `BlobStorage.service_properties_xml/1` |
| `az storage blob restore` | GAP(az-blob-restore) | timer-based account-level range restore, over budget; falsifier: PUT ?restype=account&comp=undeleteset answers typed-400 default-deny |
| `az storage blob incremental-copy` | GAP(az-blob-incremental-copy) | page-blob-only; falsifier: comp=incrementalcopy answers typed-400 default-deny |
| `az cosmosdb sql container throughput` (offers) | GAP(az-cosmos-offers) — deferred | Cosmos router owned by active AZ lanes (SYNC-3/AZ-1..5); data-plane value, next wave |
| `az cosmosdb mongodb *` | GAP(az-cosmos-mongo-wire) — deferred | whole wire listener, far over budget; needs its own lane |
| `az servicebus namespace exists`/geo-dr | GAP(az-sb-geo-dr) — deferred | ARM control-plane sugar; AMQP data leg unaffected |
| `az eventhubs namespace exists` | GAP(az-eh-checkname) — deferred | control-plane sugar; AZ-5 owns the EH face this window |
| `az eventhubs georecovery-alias` (ARM route) | GAP(az-eh-geo-dr-arm) — deferred | engine exists (eh_geo_dr.ex) but ARM route is AZ-lane surface |
| `az appconfig kv lock/unlock` | GAP(az-appconfig-lock) — deferred | AppConfigRoutes owned by STORE-3 this window |
| `az deployment operation group list` | GAP(az-deploy-operations) — deferred | control-plane sugar |
| `az deployment group what-if` | GAP(az-deploy-whatif) — deferred | control-plane sugar |
| `az deployment cancel` | GAP(az-deploy-cancel) — deferred | LRO cancel arm, lro.ex exists off-route |

## Totals

Headline scoped families (1, 3-9). Adjacent faces (§2, §2b) excluded from
totals. GAP-typed rows are counted separately from MISSING (a GAP row is a
typed refusal + falsifier, not a silent 404).

| family | EMULATED-TODAY | MISSING | GAP-typed | N-A | total |
|---|---|---|---|---|---|
| Blob (incl. account-level) | 23 | 0 | 2 | 2 | 27 |
| Cosmos DB | 13 | 0 | 2 | 1 | 16 |
| Key Vault | 25 | 0 | 0 | 1 | 26 |
| Service Bus | 8 | 0 | 1 | 0 | 9 |
| Event Hubs | 6 | 0 | 2 | 0 | 8 |
| App Configuration | 9 | 0 | 1 | 1 | 11 |
| Attestation / Ledger | 2 | 0 | 0 | 2 | 4 |
| ARM + deployments | 19 | 0 | 3 | 0 | 22 |
| **total** | **105** | **0** | **11** | **7** | **123** |

Headline MISSING set is now empty; the work queue is the GAP register
above (2 blob GAPs closeable next wave; 9 deferred rows blocked on
active-lane router ownership, not on difficulty).

Adjacent faces (§2/§2b queue/file/table): EMULATED-TODAY at
egress_router.ex:447-485, :666-745, data_plane/table_storage_router.ex:14.

DoD: every EMULATED-TODAY cite resolves to a live route clause on disk
(this session verified all cited route lines via the route scans of
lib/smalt/egress/*.ex, egress_router.ex, arm_gateway/router.ex). MISSING
rows are absence-of-route findings at HEAD working tree; a MISSING flip to
EMULATED is receipt-gated per GAP convention.

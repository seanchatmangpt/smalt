# Bicep-types-az groundwork for "smalt cli supports everything az cli does"

Standing: PARTIAL_ALIVE (survey complete, converter not landed). Subject:
`/Users/sac/bicep-types-az` clone @ HEAD (shallow, 2026-10-22), smalt main 2699419.
Scratch excerpts: `tmp/bicep-survey/` (gitignored scratch, not receipts).

## Part A — bicep-types-az spec survey

### A1. `generated/index.json` — the master registry

- 9.0 MB single JSON, top-level keys: `resources`, `resourceFunctions`,
  `namespaceFunctions`, `settings`.
- **34,928 resources** keyed by `"<Type>@<apiVersion>"` strings, e.g.
  `Microsoft.Storage/storageAccounts@2025-01-01`. Value is a JSON-Pointer
  `$ref` into a **per-RP-per-apiVersion `types.json`**, e.g.
  `_tsp/cosmos-db/...` or `storage_0/microsoft.storage/2025-01-01/types.json#/355`
  — the `#/355` is an array index into that file's root array of type nodes.
- `Microsoft.Storage/storageAccounts` alone has **32 apiVersions** (2015 →
  2026-09-01 preview). Any smalt converter must pin apiVersions; latest stable
  for storageAccounts is **2025-01-01** (2025-06+ exist but check staging).
- Resolution is two-hop: index string → types.json array index → recursive
  `$ref` graph within that file (`#/163` body, etc.).

### A2. storageAccounts@2025-01-01 property tree (verified against disk)

types.json node 355 (`ResourceType`): `name`, `body: {$ref: #/163}`,
`readableScopes: 8, writableScopes: 8` (bitmask: 1=Tenant, 2=ManagementGroup,
4=Subscription, 8=ResourceGroup — 8 ⇒ RG-scoped, standard).

Body `#/163` (ObjectType "Microsoft.Storage/storageAccounts"):

| property | flags | meaning |
|---|---|---|
| id / type / apiVersion | 10 | ReadOnly + DeployTimeConstant |
| name | 9 | Required + DeployTimeConstant (string, `minLength 3, maxLength 24, pattern ^[a-z0-9]+$`) |
| sku | 1 | Required. Object: `name` (required union of 14 string literals + string), `tier` (read-only union Standard/Premium) |
| kind | 1 | Required. Union: Storage, StorageV2, BlobStorage, FileStorage, BlockBlobStorage, (string) |
| location | 1 | Required |
| tags | 0 | optional map<string,string> |
| identity, extendedLocation, zones, placement | 0 | optional |
| properties | 0 | optional `StorageAccountPropertiesCreateParametersOr...` object (~40 props: publicNetworkAccess, sasPolicy, customDomain, networkAcls, accessTier, ... ) |
| **none** | — | no `secure` flags in the whole 2025-01-01 file (storageAccounts has no write-only secret props; secrets live in KeyVault resource) |

**Flags vocabulary** (bits, confirmed empirically in-file and cross-checked with
[Azure/bicep-types](https://github.com/Azure/bicep-types) `PropertyFlags`):
Required=1, ReadOnly=2, Secure=4, DeployTimeConstant=8 (plus AllowDefault=16,
SystemProperty=32, Identifier=64, Singleton=128 per upstream). In
storage@2025-01-01 only 0/1/2/9/10 occur.

Enums are **not** a distinct node type: a "enum" is a `UnionType` of
`StringLiteralType` elements (e.g. sku.name = union of
`Standard_LRS ... PremiumV2_ZRS` literals) plus an open `StringType` element
when the enum is open. Nullability is likewise not a `nullable` key — it's a
`UnionType` element of `NullType` (none occur in the storage file; nullable
props are typed `string | null` upstream as unions).

### A3. Enums / nullability / secure — representation rules

| Concept | bicep-types representation | SHACL translation |
|---|---|---|
| enum | `UnionType` of `StringLiteralType` (+ `StringType` if open) | `sh:in ( ... )` on a `sh:PropertyShape`; omit `sh:in` + keep `sh:datatype sh:string` if open union |
| required | flag bit 1 (`flags & 1`) | `sh:minCount 1` |
| read-only | flag bit 2 | `sh:closed true`-adjacent annotation `smalt:readOnly true`; PUT-body shape drops the property |
| secure (write-only secret) | flag bit 4 | never materialize in GET responses; PUT accepts, GET redacts — map to `smalt:writeOnly` |
| nullability | `UnionType` with `NullType` element | `sh:maxCount` semantics unchanged; value may be `sh:null` |
| string constraints | `minLength/maxLength/pattern` keys on StringType | `sh:minLength`/`sh:maxLength`/`sh:pattern` direct |
| DTC | flag bit 8 (name/type/apiVersion) | constant per-resource; generator emits literal, never input |
| scopes bitmask | readableScopes/writableScopes (8 = RG) | determines route template prefix |

### A3.5 Raw JSON excerpt the converter consumes

Full machine-readable excerpt (index entry, resource node, body property map,
sku/kind unions, name constraints) written to
`tmp/bicep-survey/storageAccounts-2025-01-01-excerpt.json`; index structure
sample in `tmp/bicep-survey/index-head.json`.

Key snippet (truncated for prose):

```json
{
  "index_entry": {"$ref": "storage_0/microsoft.storage/2025-01-01/types.json#/355"},
  "resource_node": {"$type": "ResourceType",
    "name": "Microsoft.Storage/storageAccounts@2025-01-01",
    "body": {"$ref": "#/163"},
    "readableScopes": 8, "writableScopes": 8},
  "sku_object": {"$type": "ObjectType", "name": "Sku", "properties": {
      "name":  {"type": {"$ref": "#/50"}, "flags": 1,
                "description": "The SKU name. Required for account creation; optional for update."}}}
}
```

The full machine-written excerpt in `tmp/bicep-survey/` is ground truth for
converter work; this block is illustrative only.

### A4. Offline usability

- `generated/` is 583 MB total, 6.3 MB for
  `storage_0/microsoft.storage`; index.json 9.0 MB. Fully offline-usable,
  MIT license (Copyright Microsoft). Shallow clone at HEAD is the refresh
  model; pin the clone SHA when the converter lands.
- Clone tip includes preview-only versions; a converter should whitelist
  apiVersions (e.g. storageAccounts `2025-01-01`).

## Part B — smalt-cli / ARM face map

### B1. smalt-cli inventory (`/Users/sac/smalt/smalt-cli/`)

- Typer app `smalt-cli` (smalt_cli/cli.py): sub-apps `test`, `hw`, `daemon`,
  `audit`, `gate`, `migrate` (Terraform + bicep scan → topology →
  smalt.manifest.json), plus `ledger` docs-only. Env-configured via
  `smalt_cli/config.py`: `SMALT_ARM` (default `http://127.0.0.1:9443`),
  `SMALT_EGRESS`, `SMALT_AMQP`; `enforce_loopback()` rejects non-loopback URLs.
  Zero-actuation policy module (`policy.py guard`).
- Transport: `smalt_cli/gateway/proxy.py` — urllib-based forwarder to the
  substrate; no az-style resource commands today.
- Already bicep-adjacent: `smalt_cli/migrate/bicep.py` extracts
  `resource '<Type>@<apiVersion>'` declarations from .bicep with a hardcoded
  BICEP_TYPE_MAP (14 ARM types) — a bicep-types-driven converter replaces
  this hardcoded map with generated shapes.

### B2. ARM control-plane face (lib/smalt/arm_gateway/router.ex, 7050 lines, ~230 route lines)

Route families present (verified by route-line scan):

- Identity/STS: `/oauth2/v2.0/token`, MSI endpoint, discovery/keys.
- Subscriptions, tenants, locations, `operations` (LRO status: GET
  `/subscriptions/:sub_id/operations/:op_id`).
- Resource groups CRUD + `resources` list, tags face (full), `moveResources`,
  `exportTemplate`.
- Providers: list, per-ns GET, **register/unregister** (returns Registered /
  Unregistering), providerPermissions.
- Deployments face (arm/deployments.ex): PUT/GET/LIST/DELETE deployment,
  POST `validate`, GET `.../operations`, module-level `what_if` function
  (diff vs stored resources; non-admitted types → changeType "Ignore") —
  **but no HTTP route exposes what-if** (no `/whatif` route line found).
  Template validation is a shape gate, not bicep-types-driven.
  LRO machinery exists (arm_gateway/lro.ex, lro_sweeper, lro_notifier).
- Resource CRUD: named families for Storage (accounts, blobServices,
  containers, immutabilityPolicies, listKeys), KeyVault (vaults/keys/secrets/
  rotate/purge), ServiceBus (queues/topics/subscriptions/rules, networkRuleSets,
  listKeys), EventHub (eventhubs/consumergroups/networkRuleSets/listKeys),
  Network (dnsZones, privateDnsZones+vnet links, vnet subnets), DocumentDB
  (databaseAccounts/sqlDatabases/sqlContainers), EventGrid (topics/systemTopics/
  eventSubscriptions), Authorization (locks, roleAssignments, roleDefinitions,
  policyDefinitions/Assignments/Exemptions/Remediations/SetDefinitions),
  Insights (metrics, dataCollectionRules), OperationalInsights (workspaces/
  tables), PolicyInsights (summarize/queryResults), ResourceGraph.
- Generic catch-all: PUT/GET/PATCH/DELETE
  `/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:ns/:type/:name`
  plus `*glob` fallback — i.e. any bicep-declared resource already PUTs.

**Wire-compat pinions**: attach top-level ≤14 with locale fields omitted
(source=8/target=7 composite tripwires); SASL ANONYMOUS; .NET-GUID lock-token
reordering — do not regress these while adding families.

### B3. The az-CLI gap

`az` capabilities smalt-cli lacks today (verified by absence in cli.py /
router.ex route scan):

1. **Template submission + LRO polling as a CLI verb** — router has
   deployments PUT + LRO + operations GET, but smalt-cli has no
   `smalt-cli deploy` verb that POSTs a template, follows the LRO
   Azure-AsyncOperation / provisioningState polling loop, and prints the
   deployment outputs. Azure CLI's `az deployment group submit` / `--wait`.
2. **`az bicep build`** — smalt bicep.py is regex extraction of the .bicep
   source, not template compilation; no bicep CLI integration. Note:
   `az bicep build` shells out to the Bicep CLI (dotnet), so smalt-cli needs
   either the bicep binary or a template-shape gate.
3. **What-if over the wire** — `Smalt.ARM.Deployments.what_if/3` exists as a
   library function but no POST `.../deployments/:name/whatif` route; and
   no CLI verb. One route line + one typer command closes this.
   `az deployment group what-if`.
4. **Resource-group scoping defaults** — az has `--subscription`/`--resource-group`
   context via az configure; smalt-cli has no persistent defaults, no
   `smalt-cli configure` verb, and no per-RG resource list verb
   (`az resource list -g`). Router routes exist; CLI verbs don't.
5. **Provider registration as CLI verb** — router POST register/unregister
   routes exist; smalt-cli has no `smalt-cli provider register <ns>` verb;
   bicep deployments auto-register in real az, so a preflight "is
   `Microsoft.Storage` registered" check is the cheap version.
   `az provider show/register`.
6. **Schema-driven validation of resource bodies** — deployments validate is
   a shape gate; bicep-types SHACL shapes would make
   `smalt-cli deploy --validate-only` enforce sku.name ∈ enum, kind required,
   name pattern ^[a-z0-9]+$ — the actual az behavior smalt currently lacks.
7. **`az resource` generic verbs** (show/delete/list/tag update) and
   LRO-aware DELETE (--wait) as CLI verbs.

### Top 5 highest-value az capabilities to land first

1. **`smalt-cli deploy submit --rg <rg> -f template.json --wait`** — wire
   deployments PUT + operations polling (routes exist; CLI verb missing).
   Falsifier: a template PUT returns 201 with provisioningState Succeeded and
   resources materialize in the Store.
2. **POST `.../deployments/:name/whatif` route + `smalt-cli deploy what-if`**
   — library exists (`Smalt.ARM.Deployments.what_if/3`), one route line each.
   Falsifier: what-if over stored resources returns Create/Modify/Ignore
   changeTypes matching the existing unit semantics.
3. **bicep-types converter: `smalt-cli types sync`** — consume
   generated/index.json → emit SHACL shapes for pinned apiVersions →
   deployments validate gates PUT bodies on the shapes (sku.name enum, kind
   required, name pattern). Falsifier: `{"sku":{"name":"Bogus"}}` PUT is
   refused with typed InvalidResourceBody; `Standard_LRS` passes.
4. **`smalt-cli resource list/show/delete`** — generic family routes exist;
   CLI verbs give az-parity surface CRUD with RG scoping.
5. **`smalt-cli provider register/unregister/list`** — routes exist; CLI
   verb + preflight registration check in deploy submit.

Items 1–3 constitute the "template submission drives resource creation"
loop; 4–5 round out the az surface verbs.

### Mapping table

| bicep-types artifact | SHACL shape spec | smalt ARM route | smalt-cli command |
|---|---|---| Chicago-style verification |
| `index.json` resources key `Microsoft.Storage/storageAccounts@2025-01-01` | shape IRI `smalt:Microsoft.Storage_storageAccounts_2025-01-01` | PUT/GET/DELETE `/subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.Storage/storageAccounts/:name` | `smalt-cli resource show ...` / `deploy submit` |
| ResourceType.body `$ref` chain | node shape (properties tree) | PUT body gate in `deployments_put` / generic PUT handler | `smalt-cli deploy submit --validate-only` |
| UnionType of StringLiteralType (sku.name) | `sh:in (Standard_LRS ...)` | generic PUT handler enum gate | `--validate-only` refusal on bad sku.name |
| flags bit 1 (Required) | `sh:minCount 1` | PUT 400 on missing sku/kind/location | same |
| flags bit 2 (ReadOnly) | `smalt:readOnly` annotation | GET response always carries id/type/name; PUT ignores | `smalt-cli resource show` |
| flags bit 4 (Secure) | `smalt:writeOnly` | listKeys POST exists (storage listKeys route, router.ex:4479) | `smalt-cli resource list-keys` |
| flags bit 8 (DTC) | constant emission | router renders id/type/apiVersion in every resource JSON | n/a (server-side) |
| StringType minLength/maxLength/pattern (name) | sh:minLength/maxLength/pattern | name pattern gate (storage account name gate exists in generic PUT) | `--validate-only` |
| readableScopes/writableScopes bitmask 8 | RG-scope | route template has :rg_name segment | `-g` flag |

## Receipt

- Commands run: `git clone --depth 1` (bicep-types-az, exit 0), python3
  index/types.json inspection (exit 0), route scans over router.ex
  (exit 0), excerpt written (4671 bytes, exit 0).
- No lib/ or smalt-cli code modified; nothing committed.

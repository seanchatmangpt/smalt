# r9 — T-15: IaC state export — bicep + terraform from ONE projection pass

- window: v26.10.28 · ticket: `tickets/T15-iac-state-export.md` · date: 2026-10-29
- tier: beam (`test/integration/iac_export_test.exs`) · status: **CODE-COMPLETE (r9), awaiting integration run**

## landed

1. **The ONE projection pass** (`lib/smalt/data_plane/iac_export.ex`,
   `Smalt.DataPlane.IacExport`): `intermediate_model/1` walks the
   `:smalt_resources` rows once and produces the intermediate model — typed
   entries (canonical-cased resource type strings, pinned api-versions,
   symbolic names derived from the resource names and sanitized to
   identifiers with `_2`/`_3` dedupe, declarative properties with
   `provisioningState` stripped, stored sku/kind), parent references
   (resource groups parsed from the ARM ids; Service Bus namespaces for
   queue children), and outputs for keys/endpoints computed once
   (storage `listKeys().keys[0].value` / `primary_access_key`,
   cosmos `primaryMasterKey`, vault `vaultUri`, namespace
   `serviceBusEndpoint` → tf `hostname`). `intermediate_model/0` is the
   same walk over the live Store. Normalization mirrors the semantic
   read-path law: row STRUCTURE refuses typed (non-map row, vacuous
   identity via `Smalt.Projection.Identity.valid?/1` — adopted, not
   reimplemented, missing type), field VALUES are lenient (missing location
   omits the line; non-map properties project `%{}`).

2. **Two renderers, one model**: `render_bicep(model)` emits
   `%{"main.bicep" => body}` — subscription-scoped, real resource types
   (`Microsoft.Storage/storageAccounts@2023-05-01` etc.), symbolic names,
   sku/kind scaffolding (stored values first, disclosed defaults where the
   row carried none), `existing` blocks for referenced-but-unexported
   parents, and the model's outputs verbatim. `render_terraform(model)`
   emits `%{"main.tf" => .., "terraform.tfvars" => ..}` — azurerm HCL
   (azapi_resource for unknown types), names/locations riding `var.*` with
   the tfvars stub carrying their literals plus the `tenant_id` placeholder
   when a Key Vault is exported. Known children nest properly in both
   dialects (bicep `parent:` — never `scope`+`parent` together, which bicep
   rejects; terraform `namespace_id`).

3. **The CLI** (`lib/mix/tasks/smalt.export.ex`):
   `mix smalt.export --format bicep|terraform [--out <dir>]` (default out
   `tmp/export/`). Unknown format = typed refusal `:unknown_format`; a
   malformed Store row = typed refusal `:export_failed` (never a partial
   template).

File scope: semantic/ + projection/ untouched (read-only per the ticket);
parity/ untouched.

## court

`SmaltTest.Integration.IacExportTest` — real Store seeded with an RG +
storage account + key vault (`rg-smalt-fixture`-style name literals), 6
tests:

1. bicep: real type strings (`resourceGroups@2021-04-01`,
   `storageAccounts@2023-05-01`, `vaults@2023-07-01`), symbolic names
   (`rg_smalt_fixture`, `stsmaltfixture`, `kv_smalt_fixture`), literal
   names/locations/skus, outputs for the blob endpoint + primary key +
   vault URI, and `refute provisioningState` (runtime state never
   re-declared).
2. terraform: matching azurerm blocks (`azurerm_resource_group`,
   `azurerm_storage_account` with tier/replication split from the sku,
   `azurerm_key_vault` with `var.tenant_id`), sensitive key output, and the
   tfvars stub names/locations (+ tenant placeholder).
3. **single-source witness**: the court calls
   `intermediate_model/1` directly with the fixture rows, asserts the
   Store walk equals the rows walk, and asserts BOTH renderers quote the
   model's outputs and symbolic names verbatim.
4. unknown type (`Microsoft.ServiceFabricMesh/applications`): generic
   bicep block + `azapi_resource` (azapi provider pulled in) with
   properties verbatim.
5. Service Bus namespace + queue: queue nests under its namespace
   (bicep `parent:` / terraform `namespace_id`) without fabricating a
   parent.
6. typed refusals: vacuous identity, non-map row, missing type, non-list.

**Not yet executed** — the r9 lane is code-only per the compile-freeze SLA
(no mix/test/git in this pass); the court runs with the next integration
pass and this receipt + the ticket stamp say so.

## DoD mapping (the Azure developer's view)

- "a `main.bicep` that opens like something you would have written" =
  court test 1 (types, symbolic names, locations/SKUs filled in); "bicep
  build compiles clean" = the pending integration receipt (`bicep build` on
  `tmp/export/main.bicep`).
- "deploy to a FRESH smalt instance reproduces your world / probes pass
  unchanged" and "terraform init && plan shows no changes after apply" =
  the pending round-trip receipts (deploy-exported-artifact +
  plan-parity), per the ticket's receipts-required section.
- "the bicep and HCL never disagree, because both come from the same
  projection" = court test 3 (the witness) — the renderers are functions
  of one model, structurally incapable of divergence.

## usage

```sh
mix smalt.export --format bicep          # tmp/export/main.bicep
mix smalt.export --format terraform      # tmp/export/main.tf + terraform.tfvars
mix smalt.export --format bicep --out ./my-world
mix smalt.export --format json           # ERROR :unknown_format known=bicep|terraform
```

## notes

- Outputs are emitted conservatively: key outputs always for key-bearing
  types (keys are runtime `listKeys` material in real exports, never
  stored declaratively); endpoint outputs only when the stored properties
  actually carry the endpoint — the exporter never fabricates a URL the
  substrate didn't serve.
- Stub boundaries disclosed in the module docs: pinned api-versions per
  known type (rows carry none), sku/kind defaults when the row carried
  none, and azurerm attribute coverage limited to name/location/sku/tenant
  (deeper per-type attributes are the integration run's parity findings).
- `terraform.tfvars` `tenant_id` is a placeholder (`00000000-...`), marked
  as such in the file header — azurerm_key_vault requires it for plan/apply.

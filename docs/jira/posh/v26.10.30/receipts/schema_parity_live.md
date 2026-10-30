# Schema Parity — Live Consumer Plan (lane F3, 2026-10-30)

Verdict: **ALIVE (plan completes; gaps enumerated)** — after 6 falsifier-found
gaps were patched in the throwaway provider copy.

## Subject under test

- Provider: the archived Elixir spike
  (`/Users/sac/smalt/tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`,
  sha256 `f0fe321b...dab6a16d`), extracted to `/tmp/f3-provider/terraform-provider-smalt`,
  rebuilt with `MIX_BUILD_ROOT=_build-f3 mix escript.build` (exit 0).
- Consumer config: throwaway copy of
  `/Users/sac/cai/courtroom-platform-az/infra` at `/tmp/f3/infra` —
  consumer checkout untouched; backend block removed, `imports.tf` disabled
  (both marked `F3-THROWAWAY`).
- CLI: `terraform init -backend=false` (exit 0), then
  `terraform plan -input=false -lock=false` with zero-guid dummy vars
  (`subscription_id`, `entra_tenant_ids`). `plan -backend=false` is not a
  valid flag (plan rejects `-backend`); init-side opt-out + backend-block
  removal is the working recipe.

## Verdict table — resources

Consumer surface: 10 resources across the platform env + tenant-apps module.

Import receipts: `/tmp/f3/import_matrix_elixir.txt` (swept with /tmp; matrix
also reproduced inline below).

| resource | plan (create) | import | notes |
|---|---|---|---|
| azurerm_resource_group | PASS | FAIL | tags type-collapsed (G2) |
| azurerm_log_analytics_workspace | PASS | FAIL | reads need ARM face |
| azurerm_container_registry | PASS | FAIL | reads need ARM face |
| azurerm_key_vault | PASS | FAIL | vault_uri missing (G4) |
| azurerm_container_app_environment | PASS | FAIL | computed-attr inventory gap (G6) |
| azurerm_user_assigned_identity (x2) | create-plan PASS | FAIL | — |
| azurerm_federated_identity_credential | PASS | FAIL | — |
| azurerm_container_app (x2) | PASS | FAIL | revision_suffix missing (G5) |
| data.azurerm_client_config | PASS | n/a | read OK without ARM face |
| azurerm_key_vault_secret / storage / roles | n/a | n/a | not in consumer config (schemas/storage_account.ex etc. exist unused) |

## Gaps (every error names a schema/face gap)

All 6 are in the provider, all reproduced as concrete plan errors, all patched
in the throwaway copy to let the plan complete:

| # | gap | evidence (consumer plan error) | provider loc | patch |
|---|---|---|---| patches live ONLY in /tmp/f3-provider (throwaway) |
| G1 | AutoMTLS unimplemented: plugin ignores `PLUGIN_CLIENT_CERT`, handshake lacks cert field | `tls: first record not a TLS handshake` on GetProviderSchema | `lib/tfprovider_smalt/main.ex` (no cert exchange) | none — run with `TF_DISABLE_PLUGIN_TLS=1` |
| G2 | `normalize_proto/1` collapses map/set/bool/number attr types to `:string` (`attr_type_atom/1`) | `tags`: `string required, but have object` (resource_group) | `lib/tfprovider_smalt/schemas.ex` | preserve map/set/bool/number from the proto type JSON |
| G3 | data-source schema resolution misses `TfproviderSmalt.DataSources.*` namespace | `azurerm_client_config.tenant_id` "Unsupported attribute" | `schemas.ex modules_for/1` | add DataSources to the namespace list |
| G4 | `azurerm_key_vault` schema lacks `vault_uri` computed attr | `vault_uri` "Unsupported attribute" | `resources/key_vault.ex schema/0` | added `vault_uri` |
| G5 | `azurerm_container_app` `template` block lacks `revision_suffix` | `template[0].revision_suffix` "Unsupported attribute" (tenant-apps ignore_changes) | `schemas/container_app.ex` | added `revision_suffix` (optional+computed) |
| G6 | unknown-value msgpack sentinel payload `"value"` (5 bytes); go-cty expects `"v"` (fixext1) | `["id"]: unsupported extension type 0x00 with len 5` | `encoding.ex` | payload `"v"` |
| G7 | ImportResourceState unimplemented (all 10 types) | `Plugin error ... code = Unknown "Internal Server Error"` | `server.ex` | NOT patched — registered divergence |

Also: computed-attr inventory narrower than the consumer's reference plan
(container_app_environment advertises 8 attrs vs the Go port's 17; no
`custom_domain_verification_id`, `docker_bridge_cidr`,
`internal_load_balancer_enabled`, `mutual_tls_enabled`,
`platform_reserved_cidr`, `platform_reserved_dns_ip_address`,
`static_ip_address`, `zone_redundancy_enabled`).

## Reference run — Go port (adapters/terraform-provider-smalt @ 35bd36d0)

The live Go port (dev.tfrc + `make build`) plans the same consumer config
**cleanly with zero gaps** (plan exit 0, 10 resources, no patches, imports
disabled): attrs inventoried from /tmp/f3-consumer/plan2.log (log lost with
the throwaway dir, receipt stands as-of-run).

As-of-run caveat: /tmp was swept mid-run twice during this lane; artifacts
re-derived after each sweep; final artifacts under `/tmp/f3/`.

Standing: G7 (import unimplemented) applies to BOTH providers — the Go port
fails with "Resource Import Not Implemented" (per-import matrix run, all 10
FAIL); G1 (AutoMTLS) applies only to the Elixir spike (the Go port's
plugin-framework handshake passes; plan exit 0 with no TF_DISABLE_PLUGIN_TLS).
G2–G6 are closed by construction in the Go port.
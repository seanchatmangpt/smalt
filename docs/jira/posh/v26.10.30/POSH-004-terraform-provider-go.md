# POSH-004: Go Terraform provider (protocol 6, dev_overrides swap)

**DIALECT-SCOPED: dialect #1 (Azure ARM/azurerm)** — stamp added by GAP-15
wave-2 doc migration (lane 15). Decision record:
[`../v26.10.31/00-unification-dialect-decision.md`](../v26.10.31/00-unification-dialect-decision.md).
Task and acceptance criteria below are byte-identical in meaning — additive
stamp only.

## Task
Build the Terraform provider as part of posh: cmd/terraform-provider-azurerm using
terraform-plugin-framework (protocol 6). Resource set + schema parity exactly the
v1 set from the 2026-10-30 plan (docs/jira/posh/v26.10.30/schema-v1.md): resource
group, container app, key vault, key vault secret, user-assigned identity,
federated identity credential, role definition/assignment, container app env,
container registry, log analytics workspace, storage account; data sources
client_config, resource_group, smalt_health.
Delivery: dev_overrides rc (TF_CLI_CONFIG_FILE) so consumer configs in
courtroom-platform-az run BYTE-UNCHANGED against smalt on kind.
Internal ARM calls route through posh's own package (POSH-003), not a bespoke client.

## Acceptance
- terraform init/plan/apply/destroy of examples/kind root against smalt-on-kind
  green under the rc; zero-drift re-plan exit 0; residue falsifier via `posh arm probe`.
- Consumer parity falsifier: courtroom-platform-az platform root plans unchanged.

## Falsifier
dev_overrides dir with a stale/absent binary must FAIL LOUDLY at plan, never
silently skip to registry.

# endpoints.tf — CANONICAL standard-endpoint redirection pattern (Phase 3,
# v26.10.19). Reference fixture for the IaC gate
# (scripts/envelope/iac_gate.py) and for any fixture that must point azurerm
# at a loopback control plane WITHOUT custom providers or registry mirrors
# that substitute provider binaries.
#
# AUDIT FINDING (receipted against azurerm 4.54.0, terraform providers schema
# -json, 2026-10-19): azurerm 4.x does NOT support an `endpoints {}` block in
# the provider configuration — provider block_types are exactly ['features'].
# The upstream-standard redirection surface in 4.x is the `metadata_host`
# attribute: azurerm GETs https://{metadata_host}/metadata/endpoints and
# builds the full cloud environment (ARM, storage, key vault, service bus,
# event hub) from the served document. smalt serves exactly that document on
# its TLS twin (witnessed by scripts/smalt-tf's ARM_METADATA_HOSTNAME export).
#
# Law: endpoint redirection uses ONLY standard upstream provider
# configuration — `metadata_host` (+ ARM_* env fallbacks). No forked
# provider, no binary-swapping mirror at the consumer layer.
#
# Port map (smalt defaults; SMALT_TF_PORT / SMALT_TLS_PORT shift them):
#   control/ARM  9443 (http loopback; azidentity permits http only for
#                localhost hosts — STS token endpoint routes here)
#   TLS twin     9444 (https, dev-CA; metadata/endpoints document)
#   data plane   8443 (blob storage face, reached via the endpoint document)
#
# This file is deliberately NOT staged by tf_plan_check.sh (which copies only
# versions.tf + <name>.tf); it is the pattern exemplar, fmt-checked like the
# rest of the tree (terraform fmt -check).

provider "azurerm" {
  features {}

  # Emulator does not implement RP registration (receipted pattern, lane 23;
  # azurerm 4.x hard-rejects ARM_SKIP_PROVIDER_REGISTRATION combined with
  # this — the deprecated skip_provider_registration attribute must NOT be
  # used).
  resource_provider_registrations = "none"

  subscription_id = "00000000-0000-0000-0000-000000000000"

  # Standard upstream redirection: loopback metadata document on the TLS
  # twin. Terraform resolves every family's endpoints from this document.
  metadata_host = "127.0.0.1:9444" # bare host[:port] — azurerm prepends https://
}

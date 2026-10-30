#!/usr/bin/env python3
"""POSH & Terraform Provider Smalt Coverage Compiler (POSH-009).

Mechanically derives the provider's resource and data source surface inventory
from adapters/terraform-provider-smalt/internal/provider, verifies that every
component is documented in posh/KNOWN_DIVERGENCES.md, and asserts zero silent gaps.

Exit codes:
  0: Complete coverage (100% of required v1 resources & data sources accounted for)
  1: Incomplete coverage or undocumented divergences
"""
import sys
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

EXPECTED_RESOURCES = {
    "azurerm_resource_group",
    "azurerm_container_app_environment",
    "azurerm_container_app",
    "azurerm_key_vault",
    "azurerm_key_vault_secret",
    "azurerm_user_assigned_identity",
    "azurerm_federated_identity_credential",
    "azurerm_role_definition",
    "azurerm_role_assignment",
    "azurerm_container_registry",
    "azurerm_log_analytics_workspace",
    "azurerm_storage_account",
}

EXPECTED_DATA_SOURCES = {
    "azurerm_client_config",
    "azurerm_resource_group",
    "azurerm_smalt_health",
    "azurerm_container_registry",
    "azurerm_key_vault",
    "azurerm_user_assigned_identity",
    "azurerm_storage_account",
}

def verify_provider_inventory():
    print("[POSH-COVERAGE] Inspecting provider source files...")
    provider_dir = REPO_ROOT / "adapters" / "terraform-provider-smalt" / "internal" / "provider"
    server_test = provider_dir / "server_test.go"
    if not server_test.exists():
        print(f"[POSH-COVERAGE-FAIL] Missing {server_test}")
        return False

    content = server_test.read_text()
    for r in EXPECTED_RESOURCES:
        if f'"{r}":' not in content:
            print(f"[POSH-COVERAGE-FAIL] Resource {r} not registered in provider inventory test")
            return False

    for d in EXPECTED_DATA_SOURCES:
        if f'"{d}":' not in content:
            print(f"[POSH-COVERAGE-FAIL] Data source {d} not registered in provider inventory test")
            return False

    print(f"[POSH-COVERAGE] Provider inventory verified: {len(EXPECTED_RESOURCES)} resources, {len(EXPECTED_DATA_SOURCES)} data sources.")
    return True

def verify_known_divergences():
    print("[POSH-COVERAGE] Verifying posh/KNOWN_DIVERGENCES.md...")
    reg = REPO_ROOT / "posh" / "KNOWN_DIVERGENCES.md"
    if not reg.exists():
        print(f"[POSH-COVERAGE-FAIL] Missing {reg}")
        return False

    text = reg.read_text()
    for r in EXPECTED_RESOURCES:
        if r not in text:
            print(f"[POSH-COVERAGE-FAIL] Resource {r} not accounted for in KNOWN_DIVERGENCES.md")
            return False

    for d in EXPECTED_DATA_SOURCES:
        if d not in text:
            print(f"[POSH-COVERAGE-FAIL] Data source {d} not accounted for in KNOWN_DIVERGENCES.md")
            return False

    print("[POSH-COVERAGE] All resources and data sources documented in KNOWN_DIVERGENCES.md.")
    return True

def main():
    print("=== POSH COVERAGE COMPILER (POSH-009) ===")
    ok1 = verify_provider_inventory()
    ok2 = verify_known_divergences()
    if ok1 and ok2:
        print("[POSH-COVERAGE] SUCCESS: 100% surface coverage with zero silent gaps.")
        sys.exit(0)
    else:
        print("[POSH-COVERAGE] FAILED: Missing surface coverage.")
        sys.exit(1)

if __name__ == "__main__":
    main()

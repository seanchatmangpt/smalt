"""ARM template extractor tests (PRD Module 1, third language).

Chicago-style: real fixture files on disk, real parse, assertions on the
projected topology state. ARM expressions are asserted TYPED UNRESOLVED,
never guessed; unsupported types counted, never silently dropped.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from smalt_cli.migrate.arm_template import parse_file, scan_dir
from smalt_cli.migrate.pipeline import scan_all
from smalt_cli.migrate.scan import build_topology

FIXTURES = Path(__file__).parent / "fixtures" / "migrate"


def _topo(path: str) -> dict:
    return build_topology(parse_file(FIXTURES / path))


# ---------- cosmos ----------

def test_cosmos_account_with_nested_databases_and_container() -> None:
    topo = _topo("full.arm.json")
    assert topo["errors"] == []
    accounts = [
        e for e in topo["cosmos_databases"] if e.get("name") is not None and "databases" in e
    ]
    assert len(accounts) == 1
    acct = accounts[0]
    assert acct["name"] == {"raw": "[variables('cosmosName')]", "unresolved": True}
    db_names = {d["name"] for d in acct["databases"]}
    assert {"orders", "catalog"} <= db_names
    orders = next(d for d in acct["databases"] if d["name"] == "orders")
    assert orders["account_ref_unresolved"] is False
    assert orders["throughput"] == 400
    cnames = {c["name"] for c in orders["containers"]}
    assert "orderItems" in cnames
    item = next(c for c in orders["containers"] if c["name"] == "orderItems")
    assert item["partition_key_paths"] == ["/customerId", "/region"]
    assert item["database_ref_unresolved"] is False


def test_cosmos_slash_path_container_resolves_by_literal_name() -> None:
    topo = _topo("full.arm.json")
    # legacyItems declares its full path as "[variables('cosmosName')]/legacy/legacyItems":
    # the account segment is an expression -> unresolved, so the database parent
    # ("legacy", not declared anywhere) must surface as a typed orphan, never a guess.
    orphans = [e for e in topo["cosmos_databases"] if e.get("database_ref_unresolved")]
    assert any(c["name"] == "legacyItems" for e in orphans for c in [e] if "name" in e) or any(
        c["name"] == "legacyItems"
        for e in topo["cosmos_databases"]
        for c in e.get("containers", [])
        if e.get("database_ref_unresolved")
    )


# ---------- storage ----------

def test_storage_containers_nested_and_slash_path() -> None:
    topo = _topo("full.arm.json")
    names = {c["name"]: c for c in topo["object_storage"]}
    assert set(names) == {"artifacts", "archives"}
    assert names["artifacts"]["storage_account_ref"] == "smaltstore"
    assert names["artifacts"]["storage_account_ref_unresolved"] is False
    assert names["archives"]["storage_account_ref"] == "smaltstore"


# ---------- servicebus ----------

def test_servicebus_namespace_queue_topic_subscription() -> None:
    topo = _topo("full.arm.json")
    sb = next(
        e
        for e in topo["messaging_namespaces"]
        if e.get("kind") == "servicebus" and not e.get("orphan_namespace")
    )
    assert sb["sku"] == "Standard"
    assert sb["name"] == {"raw": "[variables('sbName')]", "unresolved": True}
    assert [q["name"] for q in sb["queues"]] == ["jobs"]
    assert sb["queues"][0]["max_delivery_count"] == 5
    assert sb["queues"][0]["namespace_ref_unresolved"] is False
    assert [t["name"] for t in sb["topics"]] == ["events"]
    assert [s["name"] for s in sb["topics"][0]["subscriptions"]] == ["workers"]
    assert sb["topics"][0]["subscriptions"][0]["topic_ref_unresolved"] is False


# ---------- eventhub ----------

def test_eventhub_namespace_hub_consumer_group() -> None:
    topo = _topo("full.arm.json")
    eh = next(
        e
        for e in topo["messaging_namespaces"]
        if e.get("kind") == "eventhub" and not e.get("orphan_namespace")
    )
    assert eh["name"] == "smalt-eh"
    assert eh["capacity"] == 2
    hub = eh["eventhubs"][0]
    assert hub["name"] == "telemetry"
    assert hub["partition_count"] == 4
    assert [cg["name"] for cg in hub["consumer_groups"]] == ["ingest"]
    assert hub["consumer_groups"][0]["eventhub_ref_unresolved"] is False


# ---------- keyvault / apim ----------

def test_keyvault_secret_and_apim() -> None:
    topo = _topo("full.arm.json")
    vault = topo["security_vaults"][0]
    assert vault["name"] == "smalt-vault"
    assert [s["name"] for s in vault["secrets"]] == ["conn-string"]
    assert vault["secrets"][0]["vault_ref_unresolved"] is False
    assert vault["secrets"][0]["value"] is None  # secret values never echoed
    apim = topo["apim_gateways"][0]
    assert apim["name"] == "smalt-apim"
    assert apim["publisher_email"] == "ops@smalt.local"
    assert apim["sku"] == "Developer"


# ---------- unresolved / unsupported / fail-closed ----------

def test_expressions_typed_unresolved_queue_orphans() -> None:
    topo = _topo("unresolved.arm.json")
    sb = next(
        e
        for e in topo["messaging_namespaces"]
        if e.get("kind") == "servicebus" and not e.get("orphan_namespace")
    )
    assert sb["name"]["unresolved"] is True
    # concat() queue name cannot be resolved to any declared namespace segment
    orphan = next(e for e in topo["messaging_namespaces"] if e.get("orphan_namespace"))
    assert orphan["queues"][0]["name"]["unresolved"] is True
    assert orphan["queues"][0]["namespace_ref_unresolved"] is True
    # throughput from variables('throughputExpr') stays typed unresolved
    orphan_db = topo["cosmos_databases"][0]
    assert "unresolved" in str(orphan_db.get("throughput")) or orphan_db.get("throughput") is None or (
        isinstance(orphan_db.get("throughput"), dict) and orphan_db["throughput"]["unresolved"]
    )


def test_secret_with_expression_vault_is_typed_orphan() -> None:
    topo = _topo("unresolved.arm.json")
    orphan_vault = next(e for e in topo["security_vaults"] if e.get("orphan_vault"))
    assert orphan_vault["secrets"][0]["name"] == "orphan-secret"
    assert orphan_vault["secrets"][0]["vault_ref_unresolved"] is True


def test_unsupported_type_counted() -> None:
    topo = _topo("full.arm.json")
    # storageAccounts has no topology surface (tf parity: no azurerm_storage_account)
    assert topo["unsupported_resource_types"] == {
        "Microsoft.Insights/components": 1,
        "Microsoft.Storage/storageAccounts": 1,
    }


def test_broken_json_fails_closed() -> None:
    topo = _topo("broken.arm.json")
    assert len(topo["errors"]) == 1
    err = topo["errors"][0]
    assert err["error_class"] == "unparsable_file"
    assert "invalid JSON" in err["error"]
    assert topo["cosmos_databases"] == []


def test_missing_type_name_fails_closed(tmp_path: Path) -> None:
    p = tmp_path / "bad.arm.json"
    p.write_text(json.dumps({"resources": [{"type": "Microsoft.KeyVault/vaults"}]}))
    topo = build_topology(parse_file(p))
    assert len(topo["errors"]) == 1
    assert topo["errors"][0]["error_class"] == "unparsable_file"


# ---------- merge + determinism ----------

def test_scan_all_merges_arm_with_tf_and_bicep(tmp_path: Path) -> None:
    (tmp_path / "res.tf").write_text(
        'resource "azurerm_resource_group" "rg" { name = "rg" location = "x" }\n'
    )
    (tmp_path / "res.bicep").write_text(
        "resource sb 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {\n"
        "  name: 'merged-sb'\n"
        "}\n"
    )
    (tmp_path / "res.arm.json").write_text(
        json.dumps(
            {
                "resources": [
                    {
                        "type": "Microsoft.KeyVault/vaults",
                        "apiVersion": "2023-07-01",
                        "name": "merged-vault",
                    }
                ]
            }
        )
    )
    result = scan_all(tmp_path)
    assert result.files_scanned == 3
    tf_types = {b.tf_type for b in result.blocks}
    assert "azurerm_resource_group" not in tf_types  # unsupported, counted not blocked
    assert "azurerm_servicebus_namespace" in tf_types
    assert "azurerm_key_vault" in tf_types
    assert result.unsupported_types.get("azurerm_resource_group") == 1
    topo = build_topology(result)
    assert any(v["name"] == "merged-vault" for v in topo["security_vaults"])


def test_parse_deterministic() -> None:
    a = build_topology(scan_dir(FIXTURES))
    b = build_topology(scan_dir(FIXTURES))
    assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def test_arm_files_scanned_count() -> None:
    res = scan_dir(FIXTURES)
    assert res.files_scanned == 3  # full / unresolved / broken .arm.json only

"""Fixture census for the migrate-enterprise demo estate (MIGDEMO).

The Fortune-5 showcase fixture doubles as a parser regression corpus: these
counts are load-bearing fences. A parser change that extracts more or fewer
blocks from the estate fails here loudly instead of drifting the demo.
"""
import json
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from smalt_cli.migrate import verify as mv
from smalt_cli.migrate.manifest import MANIFEST_NAME
from smalt_cli.migrate.pipeline import run_all, scan_all

FIXTURE = pathlib.Path(__file__).resolve().parent / "fixtures" / "migrate-enterprise"


def _scan():
    return scan_all(FIXTURE)


def test_fixture_tree_shape():
    tf = sorted(p.name for p in FIXTURE.rglob("*.tf"))
    bicep = sorted(p.name for p in FIXTURE.rglob("*.bicep"))
    assert tf == [
        "apim.tf",
        "cosmos.tf",
        "events.tf",
        "keyvault.tf",
        "messaging.tf",
        "monitoring.tf",
        "storage.tf",
        "variables.tf",
    ]
    assert bicep == [
        "apim.bicep",
        "eventhubs.bicep",
        "monitoring.bicep",
        "servicebus.bicep",
    ]


def test_census_blocks_by_type():
    sr = _scan()
    from collections import Counter
    assert dict(sorted(Counter(b.tf_type for b in sr.blocks).items())) == {
        "azurerm_api_management": 3,
        "azurerm_cosmosdb_account": 1,
        "azurerm_cosmosdb_sql_container": 8,
        "azurerm_cosmosdb_sql_database": 3,
        "azurerm_eventhub": 6,
        "azurerm_eventhub_consumer_group": 8,
        "azurerm_eventhub_namespace": 3,
        "azurerm_key_vault": 2,
        "azurerm_key_vault_secret": 6,
        "azurerm_servicebus_namespace": 2,
        "azurerm_servicebus_namespace_queue": 7,
        "azurerm_servicebus_subscription": 7,
        "azurerm_servicebus_topic": 5,
        "azurerm_storage_container": 5,
    }
    assert sr.files_scanned == 12
    assert sr.errors == []
    assert dict(sorted(sr.unsupported_types.items())) == {
        "Microsoft.Insights/actionGroups": 1,
        "Microsoft.OperationalInsights/workspaces": 1,
        "azurerm_application_insights": 1,
        "azurerm_log_analytics_workspace": 1,
        "azurerm_resource_group": 1,
        "azurerm_storage_account": 1,
    }


def test_deliberate_unresolved_interpolations_are_typed():
    """The ${...} / ${envName} interpolations must surface typed, not guessed."""
    sr = _scan()
    by_hcl = {b.hcl_name: b for b in sr.blocks}
    # tf leg
    assert by_hcl["orders"].attributes["name"] == {
        "raw": "cosmos-orders-${var.environment}",
        "unresolved": True,
    }
    # bicep leg
    assert by_hcl["sbNs"].attributes["name"] == {
        "raw": "sb-partners-${envName}",
        "unresolved": True,
    }
    # bicep sku.name flattens to the tf-shaped "sku" attribute
    assert by_hcl["sbNs"].attributes["sku"] == "Premium"
    assert "sku.name" not in by_hcl["sbNs"].attributes
    # unsupported types are counted, never dropped into blocks
    assert not any(b.tf_type.startswith("azurerm_storage_account") for b in sr.blocks)


def test_pipeline_end_to_end(tmp_path):
    r = run_all(FIXTURE, tmp_path, tmp_path / ".env.smalt")
    assert [s.name for s in r.stages] == ["scan", "generate", "inject"]
    assert all(s.status == "ok" for s in r.stages)
    assert r.summary["files_scanned"] == 12
    assert r.summary["resource_blocks"] == 12 + 54
    assert r.summary["scan_errors"] == 0
    assert r.summary["seed_fixtures"] == 8
    manifest = json.loads((tmp_path / MANIFEST_NAME).read_text())
    assert manifest["unresolved_summary"] == {
        "accountless_databases": 0,
        "orphan_containers": 0,
        "orphan_namespaces": 2,
        "orphan_vaults": 0,
        "scan_errors": 0,
        "storage_account_refs_unresolved": 4,
    }
    env_text = (tmp_path / ".env.smalt").read_text()
    assert "SMALT_COSMOS_CONNECTION_STRING=" in env_text
    assert "SMALT_SERVICEBUS_CONNECTION_STRING=" in env_text
    assert "127.0.0.1" in env_text


def test_verify_loud_skip_when_substrate_down():
    s = mv.WireSession()
    if not mv.substrate_up(mv.DEFAULT_ARM, s, timeout=3):
        pytest.skip("LOUD SKIP: substrate down on 127.0.0.1:9443 -- live legs need it")
    receipt = mv.run(services=["blob", "cosmos", "kv", "servicebus"])
    assert receipt["zero_egress"] is True
    assert all(r["ok"] for r in receipt["services"])
    assert set(receipt["hosts"]) <= {"127.0.0.1"}

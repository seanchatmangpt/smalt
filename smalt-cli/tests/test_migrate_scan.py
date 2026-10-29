"""smalt-migrate scan lane (PRD Module 1, REQ-1.1): Terraform .tf -> topology IR.

Offline unit court — no substrate. Uses real .tf fixtures under
tests/fixtures/migrate/ and asserts on the emitted topology JSON (Chicago:
real collaborator = the actual parser, no mocks).
"""
import json
from pathlib import Path

import pytest
from typer.testing import CliRunner

from smalt_cli.migrate.terraform import scan_dir
from smalt_cli.cli import app

FIXTURES = Path(__file__).parent / "fixtures" / "migrate"


@pytest.fixture()
def topology():
    result = scan_dir(FIXTURES)
    from smalt_cli.migrate.scan import build_topology

    return build_topology(result)


def _one(entries, **kw):
    matches = [e for e in entries if all(e.get(k) == v for k, v in kw.items())]
    assert len(matches) == 1, (kw, matches)
    return matches[0]


# ---------- extraction correctness ----------

def test_cosmos_extraction(topology):
    acct = _one(topology["cosmos_databases"], name="smalt-cosmos-acct")
    assert acct["resource_group"] == "rg-smalt"
    db = _one(acct["databases"], name="maindb")
    assert db["throughput"] == 800
    assert db["account_ref_unresolved"] is False
    items = _one(db["containers"], name="items")
    assert items["partition_key_paths"] == ["/pk"]
    assert items["throughput"] == 400
    wide = _one(db["containers"], name="wide")
    assert wide["partition_key_paths"] == ["/tenant", "/id"]


def test_object_storage_extraction(topology):
    c = _one(topology["object_storage"], name="artifacts")
    assert c["storage_account_ref"] == "smaltacct"
    assert c["storage_account_ref_unresolved"] is False


def test_servicebus_extraction(topology):
    ns = _one(
        [m for m in topology["messaging_namespaces"] if m["kind"] == "servicebus"],
        name="smalt-sb-ns",
    )
    assert ns["sku"] == "Standard"
    q = _one(ns["queues"], name="jobs")
    assert q["max_delivery_count"] == 7
    assert q["lock_duration"] == "PT1M"
    topic = _one(ns["topics"], name="events")
    sub = _one(topic["subscriptions"], name="audit")
    assert sub["max_delivery_count"] == 3
    assert sub["topic_ref_unresolved"] is False


def test_eventhub_extraction(topology):
    ns = _one(
        [m for m in topology["messaging_namespaces"] if m["kind"] == "eventhub"],
        name="smalt-eh-ns",
    )
    assert ns["capacity"] == 2
    hub = _one(ns["eventhubs"], name="telemetry")
    assert hub["partition_count"] == 4
    assert hub["message_retention_in_days"] == 1
    cg = _one(hub["consumer_groups"], name="workers")
    assert cg["eventhub_ref_unresolved"] is False


def test_vault_and_apim_extraction(topology):
    vault = _one(topology["security_vaults"], name="smalt-vault")
    sec = _one(vault["secrets"], name="sas-key")
    assert sec["value"] is None  # secret values never echoed
    apim = _one(topology["apim_gateways"], name="smalt-apim")
    assert apim["publisher_email"] == "ops@smalt.local"
    assert apim["sku"] == "Developer_1"


# ---------- interpolation typed unresolved ----------

def test_interpolation_typed_unresolved(topology):
    # orphan bucket: namespace ref "sb-${var.env}" is unresolved
    orphan = _one(topology["messaging_namespaces"], orphan_namespace=True, kind="servicebus")
    q = _one(orphan["queues"], name="interp-queue")
    assert q["namespace_ref_unresolved"] is True
    assert topology["unsupported_resource_types"] == {"azurerm_linux_virtual_machine": 1}


# ---------- fail-closed ----------

def test_unparsable_file_typed_error(topology):
    broken = [e for e in topology["errors"] if e["file"].endswith("broken.tf")]
    assert len(broken) == 1
    assert broken[0]["error_class"] == "unparsable_file"
    assert "unbalanced braces" in broken[0]["error"]
    # the broken file's resource is NOT silently extracted
    assert all(c["name"] != "broken-container" for c in topology["object_storage"])


# ---------- CLI surface ----------

def test_cli_scan_stdout():
    runner = CliRunner()
    res = runner.invoke(app, ["migrate", "scan", str(FIXTURES)])
    assert res.exit_code == 0, res.output
    topo = json.loads(res.output)
    assert topo["schema"] == "smalt-migrate/topology-v1"
    assert topo["files_scanned"] == 6
    assert len(topo["errors"]) == 1


def test_cli_scan_output_file(tmp_path):
    runner = CliRunner()
    out = tmp_path / "topology.json"
    res = runner.invoke(app, ["migrate", "scan", str(FIXTURES), "--output", str(out)])
    assert res.exit_code == 0, res.output
    topo = json.loads(out.read_text())
    assert topo["files_scanned"] == 6

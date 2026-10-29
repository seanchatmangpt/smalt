"""M5 pipeline lane: bicep extraction (REQ-1.1 increment) + `smalt-migrate
all` scan -> generate -> inject pipeline (PRD §4.2) + NFR-2 budget.

Chicago discipline: real fixture files on disk, real artifacts written and
re-read — no mocks.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures" / "migrate"


# ---------------------------------------------------------------- bicep parser

def test_bicep_extracts_all_fixture_types():
    from smalt_cli.migrate.bicep import scan_dir

    r = scan_dir(FIXTURES)
    types = {b.tf_type for b in r.blocks}
    assert "azurerm_cosmosdb_account" in types
    assert "azurerm_cosmosdb_sql_database" in types
    assert "azurerm_cosmosdb_sql_container" in types
    assert "azurerm_storage_container" in types
    assert "azurerm_servicebus_namespace" in types
    assert "azurerm_servicebus_namespace_queue" in types
    assert "azurerm_servicebus_topic" in types
    assert "azurerm_servicebus_subscription" in types
    assert "azurerm_eventhub_namespace" in types
    assert "azurerm_migrate" not in types


def test_bicep_parent_chain_resolution():
    from smalt_cli.migrate.bicep import scan_dir

    r = scan_dir(FIXTURES)
    by = {(b.tf_type, b.hcl_name): b.attributes for b in r.blocks}
    # subscription -> topic -> namespace chain resolves both refs
    sub = by[("azurerm_servicebus_subscription", "eventsSub")]
    assert sub["topic_name"] == "events-topic"
    assert sub["namespace_name"] == "smalt-sb"
    # container -> database -> account
    ctn = by[("azurerm_cosmosdb_sql_container", "ordersContainer")]
    assert ctn["database_name"] == "orders"
    # consumer group -> eventhub -> namespace
    cg = by[("azurerm_eventhub_consumer_group", "telemetryCg")]
    assert cg["eventhub_name"] == "telemetry"
    assert cg["namespace_name"] == "smalt-eh"
    # keyvault secret attaches to the vault by symbol
    assert by[("azurerm_key_vault_secret", "apiSecret")]["key_vault_id"] == "vault"


def test_bicep_unsupported_and_errors_typed():
    from smalt_cli.migrate.bicep import scan_dir

    r = scan_dir(FIXTURES)
    assert r.unsupported_types.get("Microsoft.Compute/virtualMachines") == 1
    assert any("brokenQueue" in e.error for e in r.errors)


def test_bicep_interpolation_is_unresolved_not_guessed():
    from smalt_cli.migrate.bicep import scan_dir

    r = scan_dir(FIXTURES)
    interp = [b for b in r.blocks if b.hcl_name == "interpNs"][0]
    assert interp.attributes["name"] == {"raw": "sb-${environment().name}", "unresolved": True}


# ------------------------------------------------------------------- pipeline

def _pipeline_fixture(tmp_path: Path) -> Path:
    """Copy the per-type .bicep fixtures plus a .tf fixture into a tmp dir."""
    d = tmp_path / "iac"
    d.mkdir()
    for f in FIXTURES.glob("*.bicep"):
        shutil.copy2(f, d / f.name)
    (d / "main.tf").write_text(
        '''
resource "azurerm_cosmosdb_account" "tfAcct" {
  name                = "tf-cosmos"
  resource_group_name = "rg-1"
  location            = "westus"
}

resource "azurerm_storage_container" "tfCtn" {
  name                  = "tf-blobs"
  storage_account_name  = "tfacct"
}
''',
        encoding="utf-8",
    )
    return d


def test_pipeline_end_to_end(tmp_path):
    from smalt_cli.migrate.pipeline import run_all

    iac = _pipeline_fixture(tmp_path)
    out = tmp_path / "out"
    env = tmp_path / ".env.smalt"
    result = run_all(iac, out, env)
    assert [s.name for s in result.stages] == ["scan", "generate", "inject"]
    assert all(s.status in ("ok", "ok_with_errors") for s in result.stages)

    # manifest exists, parses, and is consistent with the scan
    manifest_path = out / "smalt.manifest.json"
    assert manifest_path.exists()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["version"] == 1
    names = []
    for acct in manifest["cosmos_databases"]:
        for db in acct.get("databases", []):
            for c in db.get("containers", []):
                names.append(c["name"])
        for c in acct.get("containers", []):
            names.append(c["name"])
    assert "orderItems" in names

    # env file exists and is consistent with the discovered surface
    assert env.exists()
    env_text = env.read_text(encoding="utf-8")
    assert "SMALT_COSMOS_CONNECTION_STRING=" in env_text
    assert "127.0.0.1" in env_text
    assert "Endpoint=sb://127.0.0.1:5672" in env_text  # servicebus discovered
    assert "AZURE_KEYVAULT_VAULTURI=" in env_text  # keyvault discovered
    # loopback only (NFR-1)
    for line in env_text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        assert "azure.microsoft.com" not in line
        assert "windows.net" not in line


def test_pipeline_env_backup_and_rollback_shape(tmp_path):
    from smalt_cli.migrate.pipeline import run_all

    iac = _pipeline_fixture(tmp_path)
    out = tmp_path / "out"
    env = tmp_path / ".env.smalt"
    env.write_text("PRE_EXISTING=1\n", encoding="utf-8")
    result = run_all(iac, out, env)
    inj = [s for s in result.stages if s.name == "inject"][0]
    assert inj.detail["backup_written"] is True
    assert env.read_text(encoding="utf-8") != "PRE_EXISTING=1\n"
    assert Path(str(env) + ".bak").read_text(encoding="utf-8") == "PRE_EXISTING=1\n"


def test_pipeline_nfr2_50_resources_under_30s(tmp_path):
    """NFR-2: <=30s for 50 resources. 50-resource fixture generated into the
    tmp dir (real files, real pipeline, wall-clock measured)."""
    from smalt_cli.migrate.pipeline import run_all

    d = tmp_path / "iac50"
    d.mkdir()
    chunks = []
    for i in range(10):  # 5 resources per file x 10 files = 50
        chunks.append(
            f'''
resource "azurerm_cosmosdb_account" "acct{i}" {{
  name     = "cosmos-{i}"
  location = "westus"
}}

resource "azurerm_servicebus_namespace" "sb{i}" {{
  name = "sb-{i}"
  sku  = "Standard"
}}

resource "azurerm_servicebus_namespace_queue" "q{i}" {{
  name            = "queue-{i}"
  namespace_name  = "sb-{i}"
  max_delivery_count = 10
}}

resource "azurerm_storage_container" "ctn{i}" {{
  name                 = "ctn-{i}"
  storage_account_name = "acct{i}"
}}

resource "azurerm_key_vault" "kv{i}" {{
  name                = "kv-{i}"
  resource_group_name = "rg-{i}"
  location            = "westus"
}}
'''
        )
    (d / "big.tf").write_text("\n".join(chunks), encoding="utf-8")

    import time

    t0 = time.perf_counter()
    result = run_all(d, tmp_path / "out", tmp_path / ".env.smalt")
    elapsed = time.perf_counter() - t0
    assert result.summary["resource_blocks"] == 50
    assert elapsed < 30.0
    assert result.summary["elapsed_ms"] < 30_000.0


def test_pipeline_cli_command(tmp_path):
    from typer.testing import CliRunner

    from smalt_cli.migrate.pipeline import pipeline_app, pipeline_all_command
    from smalt_cli.migrate.scan import migrate_app

    iac = _pipeline_fixture(tmp_path)
    runner = CliRunner()
    res = runner.invoke(
        pipeline_app,
        ["--iac-dir", str(iac), "--output-dir", str(tmp_path / "out"), "--target", str(tmp_path / ".env.smalt")],
    )
    assert res.exit_code == 0, res.output
    assert "[scan]" in res.output and "[summary]" in res.output
    assert (tmp_path / "out" / "smalt.manifest.json").exists()

    # `smalt-migrate all` registration path (scan.py owns migrate_app)
    migrate_app.command("all")(pipeline_all_command)
    res2 = runner.invoke(
        migrate_app,
        ["all", "--iac-dir", str(iac), "--output-dir", str(tmp_path / "out2"), "--target", str(tmp_path / ".env2.smalt")],
    )
    assert res2.exit_code == 0, res2.output
    assert (tmp_path / "out2" / "smalt.manifest.json").exists()
    assert (tmp_path / ".env2.smalt").exists()

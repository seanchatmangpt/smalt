"""M2 tests: manifest IR sections + NFR-3 byte determinism. Offline."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from typer.testing import CliRunner

from smalt_cli.migrate.manifest import (
    MANIFEST_NAME,
    build_manifest,
    generate,
    render_manifest,
)
from smalt_cli.migrate.terraform import scan_dir

runner = CliRunner()

TF_MAIN = '''\
resource "azurerm_cosmosdb_account" "acct" {
  name                = "m2-cosmos"
  location            = "westus2"
  resource_group_name = "m2-rg"
}
'''

TF_MORE = (
    'resource "azurerm_cosmosdb_sql_database" "db" {\n'
    '  name         = "shop"\n'
    '  account_name = azurerm_cosmosdb_account.acct.name\n'
    '}\n'
    '\n'
    'resource "azurerm_cosmosdb_sql_container" "orders" {\n'
    '  name                = "orders"\n'
    '  account_name        = azurerm_cosmosdb_account.acct.name\n'
    '  database_name       = azurerm_cosmosdb_sql_database.db.name\n'
    '  partition_key_paths = ["/tenantId"]\n'
    '}\n'
    '\n'
    'resource "azurerm_cosmosdb_sql_container" "nested" {\n'
    '  name                = "nested"\n'
    '  account_name        = azurerm_cosmosdb_account.acct.name\n'
    '  database_name       = azurerm_cosmosdb_sql_database.db.name\n'
    '  partition_key_paths = ["/meta/tenant"]\n'
    '}\n'
    '\n'
    'resource "azurerm_cosmosdb_sql_container" "nopk" {\n'
    '  name          = "nopk"\n'
    '  account_name  = azurerm_cosmosdb_by_hand\n'
    '  database_name = azurerm_cosmosdb_sql_database.db.name\n'
    '}\n'
)

TF_MESSAGING = (
    'resource "azurerm_servicebus_namespace" "sb" {\n'
    '  name = "m2-sb"\n'
    '  sku  = "Standard"\n'
    '}\n'
    '\n'
    'resource "azurerm_servicebus_namespace_queue" "q" {\n'
    '  name                = "jobs"\n'
    '  namespace_name      = azurerm_servicebus_namespace.sb.name\n'
    '  max_delivery_count  = 7\n'
    '}\n'
    '\n'
    'resource "azurerm_servicebus_topic" "t" {\n'
    '  name           = "events"\n'
    '  namespace_name = azurerm_servicebus_namespace.sb.name\n'
    '}\n'
    '\n'
    'resource "azurerm_servicebus_subscription" "s" {\n'
    '  name           = "worker"\n'
    '  namespace_name = azurerm_servicebus_namespace.sb.name\n'
    '  topic_name     = azurerm_servicebus_topic.t.name\n'
    '}\n'
    '\n'
    'resource "azurerm_eventhub_namespace" "ehn" {\n'
    '  name            = "m2-eh"\n'
    '  sku             = "Standard"\n'
    '  capacity        = 2\n'
    '}\n'
    '\n'
    'resource "azurerm_eventhub" "eh" {\n'
    '  name                   = "telemetry"\n'
    '  namespace_name         = azurerm_eventhub_namespace.ehn.name\n'
    '  partition_count        = 4\n'
    '  message_retention_in_days = 3\n'
    '}\n'
    '\n'
    'resource "azurerm_eventhub_consumer_group" "cg" {\n'
    '  name            = "reader"\n'
    '  namespace_name  = azurerm_eventhub_namespace.ehn.name\n'
    '  eventhub_name   = azurerm_eventhub.eh.name\n'
    '}\n'
    '\n'
    'resource "azurerm_key_vault" "kv" {\n'
    '  name                = "m2-vault"\n'
    '  resource_group_name = "m2-rg"\n'
    '}\n'
    '\n'
    'resource "azurerm_key_vault_secret" "sec" {\n'
    '  name         = "connstr"\n'
    '  value        = "super-secret"\n'
    '  key_vault_id = azurerm_key_vault.kv.id\n'
    '}\n'
    '\n'
    'resource "azurerm_storage_container" "blob" {\n'
    '  name                 = "docs"\n'
    '  storage_account_name = "m2store"\n'
    '}\n'
    '\n'
    'resource "azurerm_api_management" "apim" {\n'
    '  name                = "m2-apim"\n'
    '  publisher_name      = "Sean"\n'
    '  publisher_email     = "sean@example.com"\n'
    '  sku_name            = "Developer_1"\n'
    '  resource_group_name = "m2-rg"\n'
    '}\n'
)


@pytest.fixture()
def iac_dir(tmp_path: Path) -> Path:
    d = tmp_path / "iac"
    d.mkdir()
    (d / "main.tf").write_text(TF_MAIN + TF_MORE + TF_MESSAGING, encoding="utf-8")
    return d


def _manifest(iac_dir: Path) -> dict:
    from smalt_cli.migrate.scan import build_topology

    return build_manifest(build_topology(scan_dir(iac_dir)))


def test_manifest_sections_present(iac_dir):
    m = _manifest(iac_dir)
    for section in (
        "version",
        "services",
        "unverifiable_services",
        "identity",
        "cosmos_databases",
        "apim_gateways",
        "messaging_namespaces",
        "security_vaults",
        "object_storage",
        "seed_fixtures",
        "unresolved_summary",
    ):
        assert section in m


def test_manifest_services_key_matches_topology(iac_dir):
    from smalt_cli.migrate.inject import discovered_services
    from smalt_cli.migrate.scan import build_topology
    from smalt_cli.migrate.verify import VERIFIERS

    DISCOVERY_TO_VERIFY = {"keyvault": "kv"}
    topo = build_topology(scan_dir(iac_dir))
    m = _manifest(iac_dir)
    discovered = sorted(discovered_services(topo))
    # fixture declares all five: blob, cosmos, eventhubs, keyvault, servicebus
    assert discovered == ["blob", "cosmos", "eventhubs", "keyvault", "servicebus"]
    mapped = [DISCOVERY_TO_VERIFY.get(s, s) for s in discovered]
    # services = the verifiable subset, named in verify.py's canonical vocab
    assert m["services"] == sorted(s for s in mapped if s in VERIFIERS)
    assert m["services"] == ["blob", "cosmos", "kv", "servicebus"]
    # anything left without a verifier (eventhubs) is a typed remainder
    assert m["unverifiable_services"] == ["eventhubs"]
    assert m["services"] == sorted(m["services"])
    assert m["unverifiable_services"] == sorted(m["unverifiable_services"])
    # conservation: verifiable + remainder covers discovery modulo the rename
    covered = set(m["services"]) | set(m["unverifiable_services"])
    assert covered == set(mapped)


def test_manifest_services_empty_topology_defaults_full_surface():
    m = build_manifest({})
    # discovered_services default surface is fully verifiable
    assert m["services"] == ["blob", "cosmos", "kv", "servicebus"]
    assert m["unverifiable_services"] == []


def test_cosmos_nesting_and_seed_documents(iac_dir):
    m = _manifest(iac_dir)
    assert len(m["cosmos_databases"]) == 1
    acct = m["cosmos_databases"][0]
    assert acct["name"] == "m2-cosmos"
    (db,) = acct["databases"]
    assert db["name"] == "shop"
    containers = {c["name"]: c for c in db["containers"]}
    assert set(containers) == {"orders", "nested", "nopk"}

    orders = containers["orders"]
    assert orders["partition_key_paths"] == ["/tenantId"]
    docs = orders["seed_documents"]
    assert len(docs) == 2
    assert docs[0]["id"] == "seed-orders-0001"
    assert docs[0]["tenantId"] == "orders-sample-0001"
    assert docs[1]["tenantId"] == "orders-sample-0002"
    assert docs[0]["_smalt"]["partition_key_path"] == "/tenantId"

    nested = containers["nested"]
    doc = nested["seed_documents"][0]
    assert doc["meta"] == {"tenant": "nested-sample-0001"}

    # nopk resolved its database but declared no pk path: seeded with id-only
    # docs (typed absence), and no unresolved refs anywhere in this fixture
    nopk_docs = containers["nopk"]["seed_documents"]
    assert nopk_docs[0]["id"] == "seed-nopk-0001"
    assert "tenantId" not in nopk_docs[0]
    assert nopk_docs[0]["_smalt"]["partition_key_path"] is None
    assert m["unresolved_summary"]["orphan_containers"] == 0


def test_messaging_section(iac_dir):
    m = _manifest(iac_dir)
    ns = {n["name"]: n for n in m["messaging_namespaces"]}
    assert ns["m2-sb"]["kind"] == "servicebus"
    assert ns["m2-sb"]["queues"][0]["name"] == "jobs"
    topic = ns["m2-sb"]["topics"][0]
    assert topic["name"] == "events"
    assert topic["subscriptions"][0]["name"] == "worker"
    assert ns["m2-eh"]["kind"] == "eventhub"
    hub = ns["m2-eh"]["eventhubs"][0]
    assert hub["name"] == "telemetry"
    assert hub["consumer_groups"][0]["name"] == "reader"


def test_security_vault_secret_value_never_echoed(iac_dir):
    m = _manifest(iac_dir)
    (vault,) = m["security_vaults"]
    assert vault["name"] == "m2-vault"
    (secret,) = vault["secrets"]
    assert secret["name"] == "connstr"
    assert secret["value"] is None
    assert "super-secret" not in render_manifest(m)



def test_apim_and_object_storage(iac_dir):
    m = _manifest(iac_dir)
    (gw,) = m["apim_gateways"]
    assert gw["name"] == "m2-apim"
    assert gw["sku"] == "Developer_1"
    (blob,) = m["object_storage"]
    assert blob["name"] == "docs"
    assert blob["storage_account_ref"] == "m2store"
    assert blob["storage_account_ref_unresolved"] is False
    assert m["identity"] == []


def test_nfr3_determinism_byte_identical(iac_dir, tmp_path):
    out1, out2 = tmp_path / "o1", tmp_path / "o2"
    m1 = generate(iac_dir, out1)
    m2 = generate(iac_dir, out2)
    a = (out1 / MANIFEST_NAME).read_bytes()
    b = (out2 / MANIFEST_NAME).read_bytes()
    assert a == b
    assert m1 == m2
    # no timestamps anywhere in the payload
    text = a.decode()
    for ts_key in ("timestamp", "generated_at", "created", "created_at", "time"):
        assert ts_key not in text.lower().replace("_smalt", "")


def test_render_manifest_sorted_keys_trailing_newline(iac_dir):
    m = _manifest(iac_dir)
    text = render_manifest(m)
    assert text.endswith("}\n")
    assert text == json.dumps(m, indent=2, sort_keys=True) + "\n"
    assert list(json.loads(text)) == sorted(json.loads(text))


def test_cli_generate_via_registered_app(iac_dir, tmp_path):
    import typer

    from smalt_cli.migrate.manifest import generate_command

    cli = typer.Typer()
    cli.command(name="generate")(generate_command)
    out = tmp_path / "out"
    result = runner.invoke(
        cli, ["--iac-path", str(iac_dir), "--output-dir", str(out)]
    )
    assert result.exit_code == 0, result.output
    assert (out / MANIFEST_NAME).exists()
    body = json.loads((out / MANIFEST_NAME).read_text())
    assert body["version"] == 1
    assert len(body["seed_fixtures"]) == 3


def test_cli_requires_both_options():
    import typer

    from smalt_cli.migrate.manifest import generate_command

    cli = typer.Typer()
    cli.command(name="generate")(generate_command)
    result = runner.invoke(cli, [])
    assert result.exit_code != 0

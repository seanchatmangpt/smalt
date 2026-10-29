"""Tests for smalt_cli.migrate.inject (REQ-3.1 inject/rollback, NFR-1 no-egress)."""

from __future__ import annotations

import json
from pathlib import Path

from typer.testing import CliRunner

from smalt_cli.migrate.inject import (
    COSMOS_EMULATOR_KEY,
    build_env,
    dev_key,
    discovered_services,
    render_env,
)
from smalt_cli.migrate.scan import migrate_app

runner = CliRunner()


# ---------- pure helpers ----------

def test_discovered_services_empty_topology_defaults_full_surface():
    assert discovered_services({}) == {"cosmos", "blob", "servicebus", "keyvault"}


def test_discovered_services_maps_scan_sections():
    topo = {
        "cosmos_databases": [{"name": "acct"}],
        "object_storage": [{"name": "c1"}],
        "messaging_namespaces": [
            {"kind": "servicebus", "queues": []},
            {"kind": "eventhub", "eventhubs": []},
        ],
        "security_vaults": [{"name": "kv"}],
    }
    assert discovered_services(topo) == {
        "cosmos",
        "blob",
        "servicebus",
        "eventhubs",
        "keyvault",
    }


def test_dev_key_matches_dev_env_scheme():
    import base64, hashlib

    expected = base64.b64encode(
        hashlib.sha256(b"127.0.0.1smalt-dev-sb").digest()
    ).decode()
    assert dev_key() == expected


# ---------- inject contents ----------

def test_inject_writes_env_with_loopback_connection_strings(tmp_path: Path):
    env = tmp_path / ".env.smalt"
    result = runner.invoke(
        migrate_app, ["inject", "--target", str(env)]
    )
    assert result.exit_code == 0, result.output
    body = env.read_text()
    assert f"AccountEndpoint=http://127.0.0.1:8443;AccountKey={COSMOS_EMULATOR_KEY}" in body
    assert "Endpoint=sb://127.0.0.1:5672" in body
    assert "BlobEndpoint=http://127.0.0.1:8443/smaltacct" in body
    assert "AZURE_KEYVAULT_VAULTURI=http://127.0.0.1:8443" in body
    assert "SMALT_ARM_ENDPOINT=https://127.0.0.1:9443" in body


def test_inject_from_scan_topology_emits_only_discovered_services(tmp_path: Path):
    topo_path = tmp_path / "topology.json"
    topo_path.write_text(
        json.dumps(
            {
                "schema": "smalt-migrate/topology-v1",
                "cosmos_databases": [{"name": "a"}],
                "object_storage": [],
                "messaging_namespaces": [{"kind": "servicebus"}],
                "security_vaults": [],
            }
        )
    )
    env = tmp_path / ".env.smalt"
    result = runner.invoke(
        migrate_app,
        ["inject", "--topology", str(topo_path), "--target", str(env)],
    )
    assert result.exit_code == 0, result.output
    body = env.read_text()
    assert "SMALT_COSMOS_CONNECTION_STRING" in body
    assert "SMALT_SERVICEBUS_CONNECTION_STRING" in body
    assert "AZURE_STORAGE_CONNECTION_STRING" not in body
    assert "AZURE_KEYVAULT_VAULTURI" not in body


def test_inject_uses_storage_account_name_from_topology(tmp_path: Path):
    topo = {
        "object_storage": [
            {"storage_account_ref": {"raw": "stprod001", "unresolved": True}}
        ]
    }
    body = build_env(topo)
    assert "AccountName=stprod001" in body
    assert "BlobEndpoint=http://127.0.0.1:8443/stprod001" in body


# ---------- backup / rollback ----------

def test_inject_backs_up_existing_env_and_rollback_restores(tmp_path: Path):
    env = tmp_path / ".env.smalt"
    env.write_text("PRIOR_STATE=1\n")
    result = runner.invoke(migrate_app, ["inject", "--target", str(env)])
    assert result.exit_code == 0, result.output
    assert env.read_text() != "PRIOR_STATE=1\n"
    bak = tmp_path / ".env.smalt.bak"
    assert bak.read_text() == "PRIOR_STATE=1\n"

    rb = runner.invoke(migrate_app, ["rollback", "--target", str(env)])
    assert rb.exit_code == 0, rb.output
    assert env.read_text() == "PRIOR_STATE=1\n"


def test_rollback_without_bak_removes_injected_file(tmp_path: Path):
    env = tmp_path / ".env.smalt"
    runner.invoke(migrate_app, ["inject", "--target", str(env)])
    assert env.exists()
    rb = runner.invoke(migrate_app, ["rollback", "--target", str(env)])
    assert rb.exit_code == 0, rb.output
    assert not env.exists()


def test_rollback_with_nothing_present_is_noop(tmp_path: Path):
    env = tmp_path / ".env.smalt"
    rb = runner.invoke(migrate_app, ["rollback", "--target", str(env)])
    assert rb.exit_code == 0, rb.output
    assert not env.exists()


# ---------- dry-run ----------

def test_dry_run_prints_without_writing(tmp_path: Path):
    env = tmp_path / ".env.smalt"
    result = runner.invoke(
        migrate_app, ["inject", "--target", str(env), "--dry-run"]
    )
    assert result.exit_code == 0, result.output
    assert "AccountEndpoint=http://127.0.0.1:8443" in result.output
    assert not env.exists()
    assert not (tmp_path / ".env.smalt.bak").exists()


# ---------- idempotence ----------

def test_reinject_is_idempotent(tmp_path: Path):
    env = tmp_path / ".env.smalt"
    first = runner.invoke(migrate_app, ["inject", "--target", str(env)])
    second = runner.invoke(migrate_app, ["inject", "--target", str(env)])
    assert first.exit_code == 0 and second.exit_code == 0
    body1 = env.read_text()
    # simulate an out-of-band re-run: content identical
    runner.invoke(migrate_app, ["inject", "--target", str(env)])
    assert env.read_text() == body1


def test_render_env_never_contains_nonloopback_host():
    body = render_env({"cosmos", "blob", "servicebus", "keyvault", "eventhubs"})
    for line in body.splitlines():
        if line.startswith("#") or not line:
            continue
        assert "127.0.0.1" in line or "localhost" not in line
        assert "azure" not in line.lower() or "AZURE_" in line

"""End-to-end integration court for smalt-migrate (the 80/20 Fortune-5 claim:
IaC in -> verified loopback out).

Real Typer pipeline `all` over the repo's own migrate fixtures into tmp_path,
artifact assertions (manifest + .env.smalt), the real `verify` gate against
the emitted surface (LOUD SKIP when the shared substrate on 9443 is down —
never a fake pass, never a boot), and rollback restore.

Chicago discipline: real files on disk, real wire requests, real artifacts
re-read from disk. No mocks.
"""
from __future__ import annotations

import json
import shutil
import urllib.request
from pathlib import Path

import pytest
from typer.testing import CliRunner

FIXTURES = Path(__file__).parent / "fixtures" / "migrate"
ARM = "http://127.0.0.1:9443"


def _substrate_up() -> bool:
    """1s probe of the shared substrate; never boots one."""
    try:
        with urllib.request.urlopen(f"{ARM}/metadata/endpoints", timeout=1) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001 - any transport failure == down
        return False


SUBSTRATE_UP = _substrate_up()


# ------------------------------------------------------------------- helpers

def _iac_dir(tmp_path: Path) -> Path:
    """The repo's own fixtures: all .bicep + storage.tf into a tmp iac dir."""
    d = tmp_path / "iac"
    d.mkdir()
    for f in FIXTURES.glob("*.bicep"):
        shutil.copy2(f, d / f.name)
    shutil.copy2(FIXTURES / "storage.tf", d / "storage.tf")
    return d


def _run_all(tmp_path: Path):
    from smalt_cli.migrate.pipeline import pipeline_all_command
    from smalt_cli.migrate.scan import migrate_app

    migrate_app.command("all")(pipeline_all_command)
    out = tmp_path / "out"
    env = tmp_path / ".env.smalt"
    res = CliRunner().invoke(
        migrate_app,
        ["all", "--iac-dir", str(_iac_dir(tmp_path)),
         "--output-dir", str(out), "--target", str(env)],
    )
    assert res.exit_code == 0, res.output
    return out, env, res.output


def _verify_services_manifest(out: Path, tmp_path: Path) -> Path:
    """verify's manifest face names services; derive it from the emitted
    smalt.manifest.json (real artifact in, derived gate input out)."""
    manifest = json.loads((out / "smalt.manifest.json").read_text(encoding="utf-8"))
    # The emitted topology names real legs; the gate covers all four services.
    services = ["blob", "cosmos", "kv", "servicebus"]
    p = tmp_path / "verify-manifest.json"
    p.write_text(json.dumps({"services": services,
                             "source_manifest": str(out / "smalt.manifest.json"),
                             "cosmos_in_emitted": bool(manifest.get("cosmos_databases"))}),
                 encoding="utf-8")
    return p


# ----------------------------------------------------------------- pipeline

def test_e2e_all_emits_manifest_and_env(tmp_path):
    from smalt_cli.migrate.pipeline import pipeline_all_command
    from smalt_cli.migrate.scan import migrate_app

    migrate_app.command("all")(pipeline_all_command)  # registration path
    out, env, output = _run_all(tmp_path)
    assert "[scan]" in output and "[generate]" in output and "[inject]" in output
    assert "[summary]" in output

    # manifest artifact: parses, versioned, real resources carried
    manifest = json.loads((out / "smalt.manifest.json").read_text(encoding="utf-8"))
    assert manifest["version"] == 1
    names = []
    for acct in manifest["cosmos_databases"]:
        for db in acct.get("databases", []):
            for c in db.get("containers", []):
                names.append(c["name"])
        for c in acct.get("containers", []):
            names.append(c["name"])
    assert "orderItems" in names  # cosmos.bicep container, per-fixture law

    # env artifact: loopback-only, discovered surface present
    env_text = env.read_text(encoding="utf-8")
    assert "SMALT_COSMOS_CONNECTION_STRING=" in env_text
    assert "Endpoint=sb://127.0.0.1:5672" in env_text
    assert "AZURE_KEYVAULT_VAULTURI=" in env_text
    for line in env_text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        assert "azure.microsoft.com" not in line
        assert "windows.net" not in line


# -------------------------------------------------------------------- verify

@pytest.mark.skipif(
    not SUBSTRATE_UP,
    reason="LOUD SKIP: substrate down on 127.0.0.1:9443 -- never a boot",
)
def test_e2e_verify_gate_and_receipt(tmp_path):
    from smalt_cli.migrate.pipeline import pipeline_all_command
    from smalt_cli.migrate.scan import migrate_app

    migrate_app.command("all")(pipeline_all_command)
    out, env, _ = _run_all(tmp_path)
    vmf = _verify_services_manifest(out, tmp_path)
    receipt_path = tmp_path / "migration-receipt.json"

    res = CliRunner().invoke(
        migrate_app,
        ["verify", "--manifest", str(vmf), "--out", str(receipt_path)],
    )
    assert res.exit_code == 0, res.output

    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    assert receipt["zero_egress"] is True
    assert set(receipt["hosts"]) == {"127.0.0.1"}
    by_svc = {r["service"]: r for r in receipt["services"]}
    assert {"blob", "cosmos", "kv", "servicebus"} <= set(by_svc)
    for svc in ("blob", "cosmos", "kv"):
        assert by_svc[svc]["ok"] is True, by_svc[svc]
        assert by_svc[svc]["all_checks_passed"] is True, by_svc[svc]
    # servicebus leg: KD-131 CBS witness — the substrate boots with the
    # dev_env-derived per-host key, so the AMQP send/receive check is a real
    # pass. The SbKeyUnavailable loud-skip remains the contract for key
    # disagreement, never a silent pass.
    sb = by_svc["servicebus"]
    assert sb["ok"] is True
    assert sb.get("skipped") == [], sb
    sb_checks = {c["name"]: c for c in sb["checks"]}
    assert sb_checks["send_receive_one"]["ok"] is True, sb


# ------------------------------------------------------------------ rollback

def test_e2e_rollback_restores_preexisting_env(tmp_path):
    from smalt_cli.migrate.inject import rollback
    from smalt_cli.migrate.pipeline import pipeline_all_command
    from smalt_cli.migrate.scan import migrate_app

    migrate_app.command("all")(pipeline_all_command)
    env = tmp_path / ".env.smalt"
    env.write_text("PRE_EXISTING=1\n", encoding="utf-8")
    out, env, _ = _run_all(tmp_path)
    runner = CliRunner()

    # pre-existing content was backed up by inject; rollback restores it
    backup = Path(str(env) + ".bak")
    assert backup.read_text(encoding="utf-8") == "PRE_EXISTING=1\n"
    res = runner.invoke(migrate_app, ["rollback", "--target", str(env)])
    assert res.exit_code == 0, res.output
    assert "restored" in res.output
    assert env.read_text(encoding="utf-8") == "PRE_EXISTING=1\n"
    # shipped contract: the .bak is preserved after restore (byte-identical copy2)
    assert backup.read_text(encoding="utf-8") == "PRE_EXISTING=1\n"


def test_e2e_rollback_removes_injection_when_no_prior_env(tmp_path):
    """Without a pre-existing target, rollback removes the injected file —
    nothing persisted (REQ-3.1)."""
    from smalt_cli.migrate.scan import migrate_app

    out, env, _ = _run_all(tmp_path)
    assert env.exists()
    res = CliRunner().invoke(migrate_app, ["rollback", "--target", str(env)])
    assert res.exit_code == 0, res.output
    assert "removed" in res.output
    assert not env.exists()

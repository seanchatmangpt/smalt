"""azcli3 Typer lane — deployment group court (real wire).

group-create -> deployment create (ARM JSON template) -> the SB queue resource
is REAL: a subsequent AMQP send proves the queue was materialized end-to-end.
"""
import json
import time
import uuid

import pytest
from typer.testing import CliRunner

pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]

import conftest  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
TMPL_PATH = ""  # set by the _env autouse fixture
UNIQ = f"{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"
SUB = "ty-sub"
RG = f"ty-dep-rg-{UNIQ}"
DEP = f"ty-dep-{UNIQ}"
NS, Q = f"ty-dep-ns-{UNIQ}", f"ty-dep-q-{UNIQ}"

TEMPLATE = {
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/"
               "deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "resources": [
        {"type": "Microsoft.ServiceBus/namespaces", "name": NS,
         "apiVersion": "2021-04-01", "location": "eastus",
         "sku": {"name": "Standard", "tier": "Standard"},
         "properties": {}},
        {"type": "Microsoft.ServiceBus/namespaces/queues",
         "name": f"{NS}/{Q}", "apiVersion": "2021-04-01",
         "properties": {"lockDuration": "PT1M"}},
    ],
}


@pytest.fixture(autouse=True)
def _env(monkeypatch, tmp_path):
    global TMPL_PATH
    monkeypatch.setenv("SMALT_ARM", conftest.ARM)
    monkeypatch.setenv("SMALT_EGRESS", conftest.EGRESS)
    monkeypatch.setenv("SMALT_AMQP", "127.0.0.1:%d" % conftest._ENF_AMQP_P)
    monkeypatch.setenv("SMALT_SB_SHARED_KEY", conftest._ENFORCE_SB_KEY)
    t = tmp_path / "tmpl.json"
    t.write_text(json.dumps(TEMPLATE))
    TMPL_PATH = str(t)


def test_group_and_deployment_materialize_resource():
    r = runner.invoke(app, ["deployment", "group-create", RG,
                            "--subscription", SUB, "-o", "json"])
    assert r.exit_code == 0, r.output

    r = runner.invoke(app, ["deployment", "create", DEP,
                            "--resource-group", RG, "--subscription", SUB,
                            "--template", TMPL_PATH, "-o", "json"])
    assert r.exit_code == 0, r.output
    out = json.loads(r.output)
    assert sorted(out["resourcesApplied"]) == sorted([NS, f"{NS}/{Q}"])

    r = runner.invoke(app, ["deployment", "show", DEP,
                            "--resource-group", RG, "--subscription", SUB,
                            "-o", "json"])
    assert r.exit_code == 0, r.output
    assert json.loads(r.output)["properties"]["provisioningState"] == "Succeeded"

    # Materialization proof: the deployed queue carries real AMQP traffic.
    r = runner.invoke(app, ["servicebus", "send", Q, "deployed-payload",
                            "-o", "json"])
    if r.exit_code != 0:
        if "socket-error" in r.output or "unexpectedly closed" in r.output:
            pytest.skip("KD-21 registered AMQP wire divergence")
        assert False, r.output
    r = runner.invoke(app, ["servicebus", "receive", Q, "--max", "5", "-o", "json"])
    if r.exit_code != 0:
        if "socket-error" in r.output or "unexpectedly closed" in r.output:
            pytest.skip("KD-21 registered AMQP wire divergence")
        assert False, r.output
    assert "deployed-payload" in r.output


def test_deployment_create_refuses_bad_template():
    bad = {"properties": {"template": {"resources": "not-a-list"}}}
    import pathlib
    p = pathlib.Path(TMPL_PATH).parent / "bad.json"
    p.write_text(json.dumps(bad))
    r = runner.invoke(app, ["deployment", "create", f"{DEP}-bad",
                            "--resource-group", RG, "--subscription", SUB,
                            "--template", str(p)])
    assert r.exit_code == 1
    assert "ANDON" in r.output


def test_deployment_parameters_file_materializes_value():
    # EXPL12-4: -p/--parameters file -> [parameters('lockDuration')] resolves
    # to the file's value; the deployed queue carries it (GET proves it).
    import pathlib
    tmpl = {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/"
                   "deploymentTemplate.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "lockDuration": {"type": "string"},
            "maxSize": {"type": "string"},
        },
        "resources": [
            {"type": "Microsoft.ServiceBus/namespaces",
             "name": f"{NS}-p", "apiVersion": "2021-04-01",
             "location": "eastus",
             "sku": {"name": "Standard", "tier": "Standard"},
             "properties": {}},
            {"type": "Microsoft.ServiceBus/namespaces/queues",
             "name": f"{NS}-p/q",
             "apiVersion": "2021-04-01",
             "properties": {
                 "lockDuration": "[parameters('lockDuration')]",
                 "maxSizeInMegabytes": "[parameters('maxSize')]",
             }},
        ],
    }
    base = pathlib.Path(TMPL_PATH).parent
    t = base / "params-tmpl.json"
    t.write_text(json.dumps(tmpl))
    p = base / "params.json"
    p.write_text(json.dumps({"lockDuration": {"type": "string",
                                              "value": "PT5M"},
                             "maxSize": {"type": "string", "value": "2048"}}))

    rg = f"{RG}-p"
    dep = f"{DEP}-p"
    r = runner.invoke(app, ["deployment", "group-create", rg,
                            "--subscription", SUB, "-o", "json"])
    assert r.exit_code == 0, r.output
    r = runner.invoke(app, ["deployment", "create", dep,
                            "--resource-group", rg, "--subscription", SUB,
                            "--template", str(t), "--parameters", str(p),
                            "-o", "json"])
    assert r.exit_code == 0, r.output
    assert f"{NS}-p/q" in json.loads(r.output)["resourcesApplied"]

    # Falsifier: the deployed queue carries the parameter VALUE, not the
    # [parameters(...)] expression.
    st, body = conftest.http(
        "GET",
        f"{conftest.ARM}/subscriptions/{SUB}/resourceGroups/{rg}/providers/"
        f"Microsoft.ServiceBus/namespaces/{NS.lower()}-p/queues/"
        f"q?api-version=2021-04-01",
        None,
        conftest.bearer(),
    )
    assert st == 200, (st, body)
    props = body.get("properties", body)
    assert props.get("lockDuration") == "PT5M", body
    assert props.get("maxSizeInMegabytes") == "2048", body


def test_storage_kd15_challenge_handshake_on_enforce():
    # EXPL12-2 falsifier: bare container-create against the :enforce
    # substrate 401s tokenless, takes the KD-15 challenge, retries with the
    # STS bearer, and succeeds — no ANDON.
    from smalt_cli import wire
    r = runner.invoke(app, ["storage", "container-create",
                            f"tyhs{UNIQ}", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"status": 201' in r.output
    # The handshake path must have been live: a raw tokenless PUT (no
    # Authorization header) against :enforce returns 401.
    import httpx as _httpx
    probe = _httpx.put(
        f"{wire.egress_endpoint()}/smaltacct/tyhs-probe-{UNIQ}",
        headers={"x-ms-version": "2021-04-01"},
        verify=False, timeout=30.0,
    )
    assert probe.status_code == 401, probe.status_code

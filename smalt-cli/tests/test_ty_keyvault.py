"""azcli3 Typer lane — keyvault group court (real wire).

Secret set/get round-trip; key create (RSA + EC + oct-HSM + release_policy);
PS256 sign with server-side verify.
"""
import time
import uuid

import pytest
from typer.testing import CliRunner

pytestmark = [pytest.mark.anonymous, pytest.mark.usefixtures("anonymous_substrate")]

import conftest  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
UNIQ = f"{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("SMALT_EGRESS", conftest.ANON_EGRESS)
    monkeypatch.setenv("SMALT_ARM", conftest.ANON_ARM)


def test_secret_set_get():
    name = f"ty-sec-{UNIQ}"
    r = runner.invoke(app, ["keyvault", "secret-set", name, "s3cret-value",
                            "-o", "json"])
    assert r.exit_code == 0, r.output
    out = __import__("json").loads(r.output)
    assert out["status"] == 201 and "/secrets/" in out["id"]

    r = runner.invoke(app, ["keyvault", "secret-get", name, "-o", "json"])
    assert r.exit_code == 0, r.output
    assert __import__("json").loads(r.output)["value"] == "s3cret-value"


def test_key_create_rsa_ec_oct():
    for kty, prefix in (("RSA", "rsa"), ("EC", "ec"), ("oct-HSM", "oct")):
        name = f"ty-{prefix}-{UNIQ}"
        r = runner.invoke(app, ["keyvault", "key-create", name,
                                "--kty", kty, "-o", "json"])
        assert r.exit_code == 0, (kty, r.output)
        out = __import__("json").loads(r.output)
        assert out["kid"], (kty, r.output)


def test_key_create_with_release_policy():
    name = f"ty-mhsm-{UNIQ}"
    policy = ('{"anyOf": [{"claim": "cetheader", "equals": "smalt"}],'
              '"dataExecution": true, "exportable": false}')
    r = runner.invoke(app, ["keyvault", "key-create", name, "--kty", "RSA",
                            "--release-policy", policy, "-o", "json"])
    assert r.exit_code == 0, r.output
    assert __import__("json").loads(r.output)["release_policy"] is True


def test_sign_ps256_and_verify():
    name = f"ty-sign-{UNIQ}"
    r = runner.invoke(app, ["keyvault", "key-create", name, "--kty", "RSA"])
    assert r.exit_code == 0, r.output
    r = runner.invoke(app, ["keyvault", "sign", name, " custody-payload ",
                            "--alg", "PS256", "--verify", "-o", "json"])
    assert r.exit_code == 0, r.output
    out = __import__("json").loads(r.output)
    assert out["alg"] == "PS256" and out["valid"] is True and out["signature"]


def test_certificate_create_get():
    name = f"ty-cert-{UNIQ}"
    r = runner.invoke(app, ["keyvault", "certificate-create", name,
                            "--subject", "CN=ty-cert.local", "-o", "json"])
    assert r.exit_code == 0, r.output
    out = __import__("json").loads(r.output)
    assert out["status"] in (200, 201)

    r = runner.invoke(app, ["keyvault", "certificate-get", name, "-o", "json"])
    assert r.exit_code == 0, r.output
    out = __import__("json").loads(r.output)
    assert "cert" in __import__("json").dumps(out) or "cer" in __import__("json").dumps(out) or out.get("id")

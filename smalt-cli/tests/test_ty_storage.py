"""azcli3 Typer lane — storage group court (real wire, no mocks).

Blob container create/list + BlockBlob upload against the anonymous
substrate; etag surfaced from the real response.
"""
import time
import uuid

import pytest
from typer.testing import CliRunner

pytestmark = [pytest.mark.anonymous, pytest.mark.usefixtures("anonymous_substrate")]

import conftest  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
UNIQ = f"ty{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("SMALT_EGRESS", conftest.ANON_EGRESS)
    monkeypatch.setenv("SMALT_ARM", conftest.ANON_ARM)


def test_container_create_and_list():
    r = runner.invoke(app, ["storage", "container-create", UNIQ,
                            "--no-immutable", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"status": 201' in r.output

    r = runner.invoke(app, ["storage", "container-list", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert UNIQ in r.output


def test_blob_upload_etag():
    blob = f"{UNIQ}/evidence.bin"
    r = runner.invoke(app, ["storage", "blob-upload", UNIQ, blob, "wire-bytes",
                            "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"status": 201' in r.output
    assert '"etag": "' in r.output and '"etag": ""' not in r.output


def test_blob_upload_andon_on_missing_container():
    # A fresh upload into a nonexistent container must ANDON (exit 1, red
    # stderr) — 404, never a silent fake pass.
    r = runner.invoke(app, ["storage", "blob-upload", f"{UNIQ}-nope", "b", "x"])
    assert r.exit_code == 1
    assert "ANDON" in r.output


def test_immutable_container_rejects_overwrite_409():
    # EXPL12-1 falsifier: a container created with --immutable must send
    # x-ms-immutable-policy: true (KD-135 opt-in WORM) and refuse blob
    # overwrite with 409 after the first write.
    c = f"{UNIQ}-imm"
    r = runner.invoke(app, ["storage", "container-create", c,
                            "--immutable", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"immutable": true' in r.output

    r = runner.invoke(app, ["storage", "blob-upload", c, "w1", "first"])
    assert r.exit_code == 0, r.output

    r = runner.invoke(app, ["storage", "blob-upload", c, "w1", "overwrite"])
    assert r.exit_code == 1
    assert "ANDON" in r.output


def test_default_container_stays_writable():
    # EXPL12-1: the default leg (no flag) sends the explicit-false form —
    # KD-135 writable default — and accepts overwrite (201, new etag).
    c = f"{UNIQ}-writ"
    r = runner.invoke(app, ["storage", "container-create", c, "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"immutable": false' in r.output

    for payload in ("one", "two"):
        r = runner.invoke(app, ["storage", "blob-upload", c, "w", payload])
        assert r.exit_code == 0, r.output

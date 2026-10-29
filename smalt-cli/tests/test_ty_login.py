"""EXPL12-B — login/logout/account group court (real wire, no mocks).

Real STS round-trip against the anonymous substrate: a real token mint, a
real persisted profile (temp SMALT_CLI_CONFIG), real env>profile fallback.
"""
import time
import uuid

import pytest
from typer.testing import CliRunner

pytestmark = [pytest.mark.anonymous, pytest.mark.usefixtures("anonymous_substrate")]

import conftest  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
UNIQ = f"l{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"


@pytest.fixture(autouse=True)
def _profile_env(monkeypatch, tmp_path):
    monkeypatch.setenv("SMALT_CLI_CONFIG", str(tmp_path / "config.json"))
    monkeypatch.delenv("SMALT_ARM", raising=False)
    monkeypatch.delenv("SMALT_EGRESS", raising=False)


def test_login_verifies_and_persists(monkeypatch):
    r = runner.invoke(app, ["login", "--arm", conftest.ANON_ARM,
                            "--egress", conftest.ANON_EGRESS, "-o", "json"])
    assert r.exit_code == 0, r.output
    assert '"verified": true' in r.output
    assert "config.json" in r.output

    # account show reflects the profile (secret masked).
    r = runner.invoke(app, ["account", "show", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert conftest.ANON_ARM in r.output
    assert '"client_secret": "***"' in r.output

    # env>profile fallback: with NO env endpoints, a wire command rides the
    # profile's arm — `monitor endpoints` hits the profile arm for real.
    r = runner.invoke(app, ["monitor", "endpoints", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert "login" in r.output or "token" in r.output  # discovery face served


def test_logout_removes_profile():
    r = runner.invoke(app, ["login", "--arm", conftest.ANON_ARM,
                            "--egress", conftest.ANON_EGRESS, "-o", "json"])
    assert r.exit_code == 0, r.output
    r = runner.invoke(app, ["logout"])
    assert r.exit_code == 0, r.output
    assert "removed" in r.output

    # account show after logout is an ANDON refusal.
    r = runner.invoke(app, ["account", "show"])
    assert r.exit_code == 1
    assert "ANDON" in r.output


def test_login_sts_refusal_is_andon_no_profile(monkeypatch):
    # Dead port: STS unreachable -> ANDON, and NO profile gets persisted.
    dead = "http://127.0.0.1:1"
    r = runner.invoke(app, ["login", "--arm", dead, "--egress", dead])
    assert r.exit_code == 1
    assert "ANDON" in r.output

    import pathlib
    import os
    p = pathlib.Path(os.environ["SMALT_CLI_CONFIG"])
    assert not p.exists()

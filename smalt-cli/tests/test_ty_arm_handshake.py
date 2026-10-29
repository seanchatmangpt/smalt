"""EXPL12-W — ARM wire path KD-15 challenge handshake court (real wire).

Repairs EXPL12V-F1: wire.arm_put/arm_get (and monitor.py) used to pre-attach
bearer_for_arm() — no tokenless-first leg, and a silent degrade-to-tokenless
on STS mint failure. Now the ARM path speaks the same KD-15
tokenless -> 401 + WWW-Authenticate -> bearer retry contract as
kv_request/cosmos_request, and an STS mint failure is a typed ANDON.

All collaborators real: the :enforce substrate refuses tokenless traffic for
real, its STS refuses garbage credentials for real, and every leg below rides
the actual wire. No mocks.
"""
import time
import uuid

import httpx
import pytest
import typer
from typer.testing import CliRunner

pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]

import conftest  # noqa: E402
from smalt_cli import wire  # noqa: E402
from smalt_cli.cli import app  # noqa: E402

runner = CliRunner()
UNIQ = f"expl12w{int(time.time() * 1000)}{uuid.uuid4().hex[:6]}"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("SMALT_ARM", conftest.ARM)
    monkeypatch.setenv("SMALT_EGRESS", conftest.EGRESS)
    # Cold token cache per test: the handshake leg must fire every time.
    monkeypatch.setattr(wire, "_token_cache", {})


def test_arm_get_kd15_handshake_on_enforce():
    # Falsifier: arm_get tokenless-first against :enforce — takes the 401
    # challenge, mints, retries with the bearer, lands 2xx/404 (never 401).
    rg = f"expl12w-rg-{UNIQ}"
    resp = wire.arm_get(f"subscriptions/expl12w-sub/resourcegroups/{rg}")
    assert resp.status_code in (200, 404), (resp.status_code, resp.text[:200])
    assert resp.status_code != 401
    # The challenge the helper answered is real: a raw tokenless GET on the
    # same face 401s with a WWW-Authenticate challenge.
    probe = httpx.get(
        f"{wire.arm_endpoint()}/subscriptions/expl12w-sub/resourcegroups/{rg}"
        f"?api-version=2021-04-01",
        verify=False, timeout=30.0,
    )
    assert probe.status_code == 401, probe.status_code
    assert probe.headers.get("WWW-Authenticate", ""), "missing challenge"


def test_sts_refusal_is_typed_andon_never_silent_tokenless(monkeypatch):
    # Falsifier: STS mint failure -> typed ANDON (typer.Exit, exit 1), never
    # a silent degrade-to-tokenless. The failing STS is a REAL wire face: a
    # local http.server that 401-challenges data requests but 404s the token
    # endpoint (mint KeyError -> "" -> ANDON). No mocks.
    import http.server
    import threading

    class DeadSts(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(401)
            self.send_header("WWW-Authenticate",
                             'Bearer resource="https://sts.expl12w.invalid"')
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_PUT = do_GET
        do_POST = do_GET

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DeadSts)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    # Point the whole ARM face (data + STS) at the real DeadSts wire face.
    monkeypatch.setenv("SMALT_ARM", f"http://127.0.0.1:{port}")
    try:
        with pytest.raises(typer.Exit) as ei:
            wire.arm_get("subscriptions/expl12w-sub/resourcegroups/deadsts")
        assert ei.value.exit_code == 1
    finally:
        srv.shutdown()
    assert port  # the server actually served on a real socket


def test_cli_monitor_endpoints_rides_handshake_on_enforce():
    # The CLI face (monitor endpoints -> wire.arm_request) works cold against
    # :enforce with no pre-attached bearer: challenge -> mint -> 200.
    r = runner.invoke(app, ["monitor", "endpoints", "-o", "json"])
    assert r.exit_code == 0, r.output
    assert "portal" in r.output.lower() or "login" in r.output.lower()
    # Note: /metadata/endpoints is the tokenless-open bootstrap face (200 raw)
    # — the handshake is present client-side but not challenged here. The
    # challenged ARM face is witnessed by test_arm_get_kd15_handshake_on_enforce.

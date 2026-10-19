"""Py-verify lane: shared substrate fixtures.

Three substrates, all on lane-private ports:
  enforce  — block v1 (substrate-ctl-managed, booted by run.sh): wf1/2/3/4
  anon     — anonymous, booted here (lifted boot-eval pattern, marker+lock+
             deadline-poll): wf2 cosmos/blob legs (SharedKey/master-key auth
             is an anonymous-mode surface)
  throttle — enforce + arm_rate_limit=20 via boot-eval put_env: wf5

Reuse-else-boot with boot markers {pid, booted} + lsof listener-pid identity
check + <=1h age, lifted from docs/jira/v26.10.19/lifts/conftest.py. No fixed
sleeps: every wait is a deadline-bounded poll on a real observable.
"""
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import base64
import ssl

import pytest

REPO = str(pathlib.Path(__file__).resolve().parents[2])

ARM = os.environ.get("SMALT_PY_ARM", "http://127.0.0.1:39712")
EGRESS = os.environ.get("SMALT_PY_EGRESS", "http://127.0.0.1:39713")
TLS = os.environ.get("SMALT_PY_TLS", "https://127.0.0.1:39714")
AMQP = os.environ.get("SMALT_PY_AMQP_PORT", "39710")
EH_PORT = os.environ.get("SMALT_PY_EH_PORT", "39711")
CA_CERT = os.environ.get("SMALT_CERT_DIR", os.path.join(REPO, ".smalt/tls")) + "/ca-cert.pem"

ANON_PORTS = (39730, 39731, 39732, 39733, 39734, 39735)  # amqp eh arm egress tls mcp
THROTTLE_PORTS = (39740, 39741, 39742, 39743, 39744, 39745)

AUD = "https://management.azure.com"
SUB = "py-verify-sub"

sys.path.insert(0, os.path.dirname(__file__))

ssl_ctx = ssl.create_default_context(cafile=CA_CERT)


def http(method, url, body=None, headers=None, timeout=15, ctx=None):
    """Raw JSON wire request. Returns (status, parsed-or-raw-body)."""
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx or ssl_ctx) as r:
            payload = r.read().decode()
            return r.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def sts_token(tenant="py-verify-tenant"):
    """client_credentials grant -> (access_token, claims)."""
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "py-verify-lane",
        "client_secret": "py-verify-lane-secret",
    }).encode()
    req = urllib.request.Request(
        f"{ARM}/oauth2/v2.0/token", data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=15, context=ssl_ctx) as resp:
        tok = json.loads(resp.read())
    token = tok["access_token"]
    payload = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    return token, claims


def bearer():
    token, _ = sts_token()
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Lifted boot (marker + lock + deadline poll) — private-port substrates
# ---------------------------------------------------------------------------

def _port_open(port, timeout=1.0):
    with socket.socket() as s:
        s.settimeout(timeout)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _listener_pids(port):
    try:
        out = subprocess.run(["lsof", "-t", "-iTCP:%d" % port, "-sTCP:LISTEN"],
                             capture_output=True, text=True, timeout=5).stdout
    except subprocess.SubprocessError:
        return set()
    return {int(p) for p in out.split() if p.isdigit()}


def _is_beamish(pid):
    try:
        cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5).stdout
    except subprocess.SubprocessError:
        return False
    return "beam" in cmd or "mix" in cmd


def _sweep(ports):
    for p in ports:
        for pid in _listener_pids(p):
            if _is_beamish(pid):
                try:
                    os.kill(pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if not any(_port_open(p) for p in ports):
            return True
        time.sleep(0.2)
    return False


MAX_REUSE_AGE = 3600


def _identity_ok(marker_path, ports):
    try:
        with open(marker_path) as f:
            marker = json.load(f)
    except (OSError, ValueError):
        return False
    if time.time() - float(marker.get("booted", 0)) > MAX_REUSE_AGE:
        return False
    pid = marker.get("pid")
    return isinstance(pid, int) and pid in _listener_pids(ports[2]) and _port_open(ports[3])


def _ensure_boot(lock_path, ports, boot_eval, log_path, marker_path):
    """Reuse-else-boot. Returns (proc_or_None, reused_bool). Raises RuntimeError
    with a typed prefix on any failure."""
    import fcntl

    def healthy():
        return (all(_port_open(p) for p in (ports[2], ports[3]))
                and _identity_ok(marker_path, ports))

    if healthy():
        return None, True
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
    deadline = time.time() + 20
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                os.close(fd)
                raise RuntimeError(f"SUBSTRATE_LOCK_TIMEOUT: {lock_path}")
            time.sleep(0.5)
    try:
        if healthy():
            return None, True
        if any(_port_open(p) for p in ports):
            if not _sweep(ports):
                raise RuntimeError(f"SUBSTRATE_SWEEP_BLOCKED: ports {ports}")
        env = dict(os.environ, MIX_ENV="test")
        log = open(log_path, "w")
        proc = subprocess.Popen(
            ["/opt/homebrew/bin/mix", "run", "--no-start", "--no-halt", "-e", boot_eval],
            cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            rc = proc.poll()
            if rc is not None:
                tail = open(log_path).read()[-400:]
                raise RuntimeError(f"SUBSTRATE_DIED rc={rc}: {tail}")
            if all(_port_open(p, 0.25) for p in (ports[2], ports[3])):
                with open(marker_path, "w") as mf:
                    json.dump({"pid": proc.pid, "booted": time.time()}, mf)
                return proc, False
            time.sleep(0.25)
        raise RuntimeError(f"SUBSTRATE_TIMEOUT: {log_path}")
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _kill(proc):
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.05)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _mix_eval(extra, ports):
    amqp, eh, arm, egress, tls, mcp = ports
    base = (
        f'Application.put_env(:smalt, :sb_shared_key, "py-verify-sb-key-not-used-by-wire");'
        f'Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:{amqp}");'
        f'Application.put_env(:smalt, :amqp_port, {amqp});'
        f'Application.put_env(:smalt, :event_hubs_port, {eh});'
        f'Application.put_env(:smalt, :arm_port, {arm});'
        f'Application.put_env(:smalt, :egress_port, {egress});'
        f'Application.put_env(:smalt, :arm_tls_port, {tls});'
        f'Application.put_env(:smalt, :mcp_port, {mcp});'
        f'Application.put_env(:smalt, :auth_mode, :{extra.get("auth")});'
    )
    for k, v in extra.get("put_env", []):
        base += f'Application.put_env(:smalt, :{k}, {v});'
    return base + "{:ok, _} = Application.ensure_all_started(:smalt)"


def pytest_configure(config):
    config.addinivalue_line("markers", "anonymous: needs anonymous-auth substrate")
    config.addinivalue_line("markers", "enforce: needs enforce-auth substrate")


def _loud_skip(exc, log_path):
    tail = ""
    try:
        tail = open(log_path).read()[-300:]
    except OSError:
        pass
    pytest.skip(f"substrate unavailable: {exc}; log tail: {tail}", allow_module_level=False)


@pytest.fixture(scope="session")
def enforce_arm():
    """v1 enforce substrate (booted by run.sh via substrate-ctl): reuse, else
    attempt substrate-ctl up, else loud skip."""
    st, _ = http("GET", f"{ARM}/metadata/endpoints", timeout=5)
    if st != 200:
        rc = subprocess.run(
            ["scripts/substrate-ctl", "up", "--block", "v1", "--auth", "enforce"],
            cwd=REPO, capture_output=True, text=True, timeout=240,
        )
        if rc.returncode != 0:
            _loud_skip(f"substrate-ctl up rc={rc.returncode}: {rc.stderr[-300:]}",
                       "/tmp/smalt-substrate-state/logs/v1.log")
    yield ARM


@pytest.fixture(scope="session")
def cred(enforce_arm):
    from azure.identity import CredentialUnavailableError

    from harness.credential import make_credential

    try:
        return make_credential(enforce_arm)
    except CredentialUnavailableError as e:  # azure leg loud-skip
        pytest.skip(f"credential unavailable: {e}")


_ANON_EVAL_EXTRA = {"auth": "anonymous", "put_env": []}
_THROTTLE_EVAL_EXTRA = {
    "auth": "enforce",
    "put_env": [("arm_rate_limit", "20")],
}


@pytest.fixture(scope="session")
def anon_substrate():
    """Anonymous substrate for wf2 cosmos/blob (master-key/SharedKey surfaces).
    Booted here on ports 39730-39735, reuse-else-boot with marker identity."""
    proc = None
    log = "/tmp/py-verify-anon.log"
    marker = "/tmp/py-verify-anon.boot.json"
    try:
        proc, _ = _ensure_boot(
            "/tmp/py-verify-anon.lock", ANON_PORTS,
            _mix_eval(_ANON_EVAL_EXTRA, ANON_PORTS), log, marker,
        )
    except RuntimeError as e:
        _loud_skip(e, log)
    yield {"egress": f"http://127.0.0.1:{ANON_PORTS[3]}", "arm": f"http://127.0.0.1:{ANON_PORTS[2]}"}
    _kill(proc)


@pytest.fixture(scope="session")
def throttle_arm():
    """Enforce substrate with arm_rate_limit=20 (boot-eval put_env) for wf5."""
    proc = None
    log = "/tmp/py-verify-throttle.log"
    marker = "/tmp/py-verify-throttle.boot.json"
    try:
        proc, _ = _ensure_boot(
            "/tmp/py-verify-throttle.lock", THROTTLE_PORTS,
            _mix_eval(_THROTTLE_EVAL_EXTRA, THROTTLE_PORTS), log, marker,
        )
    except RuntimeError as e:
        _loud_skip(e, log)
    yield f"http://127.0.0.1:{THROTTLE_PORTS[2]}"
    _kill(proc)


MESG_PORTS = (39750, 39751, 39752, 39753, 39754, 39755)
MESG_SB_KEY = "cHktdmVyaWZ5LW1lc2ctbGFuZS1zYi1zaGFyZWQta2V5LTIwMjY="


@pytest.fixture(scope="session")
def messaging_substrate():
    """Enforce substrate with a KNOWN sb_shared_key (the substrate-ctl boot
    generates a random, unrecoverable key — CBS SAS verification needs the
    client-side key to match). Ports 39750-39755."""
    proc = None
    log = "/tmp/py-verify-mesg.log"
    marker = "/tmp/py-verify-mesg.boot.json"
    extra = {
        "auth": "enforce",
        "put_env": [("sb_shared_key", '"' + MESG_SB_KEY + '"')],
    }
    try:
        proc, _ = _ensure_boot(
            "/tmp/py-verify-mesg.lock", MESG_PORTS,
            _mix_eval(extra, MESG_PORTS), log, marker,
        )
    except RuntimeError as e:
        _loud_skip(e, log)
    yield {
        "arm": f"http://127.0.0.1:{MESG_PORTS[2]}",
        "amqp": MESG_PORTS[0],
        "eh": MESG_PORTS[1],
    }
    _kill(proc)

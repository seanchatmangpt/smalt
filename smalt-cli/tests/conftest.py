"""CLI-4 SDK test lanes (Gate 1, part A): shared substrate fixture.

Endpoint/auth shapes mirror the repo's real-SDK probes:
  - test/sdk-python/py_arm_resources.py   (STS client_credentials over the ARM
    gateway, Bearer for management plane)
  - test/sdk-python/py_cosmos.py          (Cosmos master-key signing, any
    64-hex key in MIX_ENV=test anonymous mode)
  - test/sdk-python/py_storage_blob.py    (SharedKey conn string, account
    smaltacct, any non-empty key)

Env: SMALT_ARM / SMALT_EGRESS override the defaults
(http://127.0.0.1:39643 / http://127.0.0.1:39644 — this lane's private
substrate, docs/how-to/dev-loop.md private range 39000-39999).

SESSION PROTOCOL (X-6, F-14/DoD-3 fix): substrate provisioning is
fixture-scoped and lazy — NO import-time boot. Two mutually exclusive auth
profiles split the suite into two pytest sessions:

  pytest -m anonymous   blob/cosmos — anonymous substrate 39643/39644,
                        lock /tmp/smalt-substrate-cli4.lock
  pytest -m enforce     identity/resourcegraph/servicebus/eventhub/keyvault
                        — enforce substrate 38654-38656/38672-38673,
                        lock /tmp/smalt-substrate-cli5.lock

Each session fixture (a) probes its port block first and REUSES a healthy
substrate read-only with lane-unique names, else (b) boots a private-port
substrate under its OWN lock (blocking flock w/ timeout), pinned to the auth
mode that session's tests need. Locks are released after boot; teardown kills
only a substrate this session booted.

IDENTITY GUARD (R177b fix, 2026-10-16): "healthy" is no longer port-open-only.
At boot the fixture writes a marker file (/tmp/cli[45]-substrate.boot.json:
{pid, booted}); reuse requires marker-present AND marker age <= MAX_REUSE_AGE
AND marker pid == the actual ARM-port listener (lsof). Ports held by a
process with no valid marker (stale lane leftover, pre-rebuild beam) are
swept (SIGTERM to mix/beam listeners on these lane-private ports) and a
fresh substrate is booted — never adopted on faith.
profiles lazily and sequentially — no shared lock, no cross-lane queue.
"""
import base64
import hashlib
import hmac
import json
import os
import pathlib

REPO_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
import secrets
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

import pytest

ARM = os.environ.get("SMALT_ARM", "http://127.0.0.1:39643")
EGRESS = os.environ.get("SMALT_EGRESS", "http://127.0.0.1:39644")
AUD = "https://management.azure.com"
SUB = "sub-cli4"
TLS_CTX = ssl._create_unverified_context()

BOOT_HINT = (
    "SMALT SUBSTRATE UNREACHABLE at ARM=%s EGRESS=%s — SKIP-PENDING. "
    "Boot one with: cd <smalt-checkout> && flock -x /tmp/smalt-substrate.lock "
    "MIX_ENV=test mix run --no-start --no-halt -e "
    "'Application.put_env(:smalt, :arm_port, <arm_port>); "
    "Application.put_env(:smalt, :egress_port, <egress_port>); "
    "Application.put_env(:smalt, :arm_tls_port, <arm_tls>); "
    "{:ok, _} = Application.ensure_all_started(:smalt)' "
    "(see docs/how-to/dev-loop.md and test/sdk-python/run.sh)" % (ARM, EGRESS)
)


def http(method, url, body=None, headers=None, timeout=15):
    """Raw JSON wire request. Returns (status, parsed-or-raw-body)."""
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=TLS_CTX) as r:
            payload = r.read().decode()
            return r.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def sts_token(tenant="cli4-tenant"):
    """client_credentials grant against the smalt STS -> (access_token, claims)."""
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "cli4-lane",
        "client_secret": "cli4-secret",
    }).encode()
    req = urllib.request.Request(
        f"{ARM}/oauth2/v2.0/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=15, context=TLS_CTX) as resp:
        tok = json.loads(resp.read())
    token = tok["access_token"]
    payload_b64 = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload_b64 + "=" * (-len(payload_b64) % 4)))
    return token, claims


def bearer():
    token, _ = sts_token()
    return {"Authorization": f"Bearer {token}"}


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_jwt(claims, secret=b"py-lane6-known-secret-0123456789abcdef"):
    header = b64u(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64u(json.dumps(claims).encode())
    signing_input = f"{header}.{payload}".encode()
    sig = hmac.new(secret, signing_input, hashlib.sha256).digest()
    return f"{header}.{payload}.{b64u(sig)}"


def blob_conn_string():
    key = base64.b64encode(b"smaltacct-key").decode()
    return (
        f"DefaultEndpointsProtocol=http;AccountName=smaltacct;"
        f"AccountKey={key};BlobEndpoint={EGRESS}/smaltacct;"
    )


def cosmos_client():
    import azure.cosmos.cosmos_client as cc

    return cc.CosmosClient(EGRESS, credential=secrets.token_hex(32))


def _substrate_reachable(url=ARM):
    try:
        st, _ = http("GET", f"{url}/metadata/endpoints", timeout=5)
        return st == 200
    except Exception:
        return False


def _port_open(port):
    import socket

    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) == 0


# R177b: max age of a reusable substrate. A marker older than this (or a
# missing/unverifiable marker) forces a fresh boot — the stale-pre-rebuild-beam
# phantom-repro channel is closed by construction, not by memory.
MAX_REUSE_AGE = 60 * 60  # 1h


def _listener_pids(port):
    """PIDs of processes LISTENing on 127.0.0.1:<port> (empty if unknown)."""
    import subprocess

    try:
        out = subprocess.run(
            ["lsof", "-t", "-iTCP:%d" % port, "-sTCP:LISTEN"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return set()
    return {int(p) for p in out.split() if p.isdigit()}


def _is_beamish(pid):
    """True if pid's command looks like the mix/beam substrate."""
    import subprocess

    try:
        cmd = subprocess.run(
            ["ps", "-o", "command=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return False
    return "beam" in cmd or "mix" in cmd


def _sweep_stale_listeners(ports):
    """Kill mix/beam listeners squatting the lane's private ports (R177b:
    dead-lane leftover substrate). Bounded; falls through to boot either way."""
    import signal
    import subprocess

    victims = set()
    for p in ports:
        victims |= _listener_pids(p)
    for pid in victims:
        if _is_beamish(pid):
            try:
                os.kill(pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
    for _ in range(10):
        if not any(_port_open(p) for p in ports):
            return True
        time.sleep(1)
    return False


def _substrate_identity_ok(marker_path, ports):
    """Reuse only when the marker names the *current* ARM-port listener and is
    fresh. Unverifiable identity -> False -> sweep+boot (fail-closed)."""
    try:
        with open(marker_path) as f:
            marker = json.load(f)
    except (OSError, ValueError):
        return False
    if time.time() - float(marker.get("booted", 0)) > MAX_REUSE_AGE:
        return False
    pid = marker.get("pid")
    return isinstance(pid, int) and pid in _listener_pids(ports[0])


def _lock_holder_pids(lock_path):
    """PIDs holding flock on lock_path (R186: loud skip needs the holder)."""
    import subprocess

    try:
        out = subprocess.run(
            ["lsof", "-t", str(lock_path)], capture_output=True,
            text=True, timeout=5,
        ).stdout
    except Exception:
        return []
    return [p for p in out.split() if p.isdigit()]


def _skip_substrate_unavailable(exc, lock_path, log_path):
    """R186 (D139 shape): a contended/failed substrate is a LOUD SKIP with the
    holder PID + boot-log tail, costing seconds — not a 180s lock wait."""
    holder = _lock_holder_pids(lock_path)
    tail = ""
    try:
        tail = open(log_path).read()[-300:]
    except OSError:
        pass
    reason = (
        f"substrate unavailable: {exc}; lock {lock_path} holder pids="
        f"{holder or 'none-detected'}"
    )
    if tail.strip():
        reason += f"; boot log {log_path} tail: {tail}"
    pytest.skip(reason)


def _ensure_substrate(lock_path, ports, boot_eval, log_path, ready=None,
                      lock_timeout=15, timeout=180, marker_path=None):
    """Probe-then-boot with identity guard. Returns (proc_or_None, reused_bool).

    Reuses the substrate on `ports` read-only ONLY when the boot marker
    verifies identity+freshness against the live port listener; otherwise
    (no marker / stale marker / foreign squatter) sweeps stale listeners and
    boots fresh, writing a new marker. Takes `lock_path` (non-blocking flock,
    bounded by `lock_timeout` — SHORT, so a contended lane skips loudly in
    seconds via _skip_substrate_unavailable; boot itself keeps the full
    `timeout` window) around the re-probe/boot. Lock fd is released after
    boot — it guards construction, not the session. Raises RuntimeError
    (SUBSTRATE_LOCK_TIMEOUT / SUBSTRATE_TIMEOUT) on failure.
    """
    import fcntl
    import subprocess

    marker_path = marker_path or log_path + ".boot.json"

    def healthy():
        return (all(_port_open(p) for p in ports)
                and (ready is None or ready())
                and _substrate_identity_ok(marker_path, ports))

    if healthy():
        return None, True
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
    deadline = time.time() + lock_timeout  # R186: short lock window, loud skip on contention
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                os.close(fd)
                raise RuntimeError(
                    f"SUBSTRATE_LOCK_TIMEOUT: {lock_path} not acquired within "
                    f"{lock_timeout}s (holder: `lsof {lock_path}`)"
                )
            time.sleep(1)
    try:
        if healthy():
            return None, True
        # Ports open but identity unverifiable -> sweep before boot (R177b).
        if any(_port_open(p) for p in ports):
            _sweep_stale_listeners(ports)
        env = dict(os.environ, MIX_ENV="test")
        log = open(log_path, "w")
        proc = subprocess.Popen(
            ["/opt/homebrew/bin/mix", "run", "--no-start", "--no-halt",
             "-e", boot_eval],
            cwd=REPO_ROOT, env=env, stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        up = False
        for _ in range(120):
            if all(_port_open(p) for p in ports) and (ready is None or ready()):
                up = True
                break
            if proc.poll() is not None:
                break
            time.sleep(1)
        if not up:
            tail = open(log_path).read()[-500:]
            raise RuntimeError(
                f"SUBSTRATE_TIMEOUT — boot log {log_path} tail: {tail}"
            )
        # Identity marker: reuse of this substrate is only lawful while the
        # pid it records is still the live ARM-port listener and it is fresh.
        with open(marker_path, "w") as mf:
            json.dump({"pid": proc.pid, "booted": time.time(),
                       "log": log_path}, mf)
        return proc, False
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _kill_substrate(proc):
    import signal

    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    time.sleep(1)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


_ANON_PORTS = (39643, 39644)
_ANON_BOOT = (
    'Application.put_env(:smalt, :arm_port, 39643);'
    'Application.put_env(:smalt, :egress_port, 39644);'
    'Application.put_env(:smalt, :arm_tls_port, 39646);'
    '{:ok, _} = Application.ensure_all_started(:smalt)'
)

_ENFORCE_PORTS = (38672, 38673, 38654, 38655)
_ENFORCE_BOOT_SEED = """
for {q, props} <- [
  {"cli5-batch-q", %{}},
  {"cli5-dlq-q", %{}},
  {"cli5-defer-q", %{}},
  {"cli5-lock-q", %{"lockDuration" => "PT2S"}}
] do
  {:ok, _} = Smalt.Amqp.QueueStore.ensure_queue(q);
  key = "providers/Microsoft.ServiceBus/namespaces/cli5ns/queues/" <> String.downcase(q);
  Smalt.Store.put(:smalt_resources, key, %{"properties" => props})
end
"""
_ENFORCE_SB_KEY = os.environ.get(
    "CLI5_SB_SHARED_KEY", "cli5-local-shared-key-not-used-by-wire-security"
)

_ENFORCE_BOOT = (
    'Application.put_env(:smalt, :sb_shared_key, "' + _ENFORCE_SB_KEY + '");'
    'Application.put_env(:smalt, :sts_signing_secret, '
    '"py-lane6-known-secret-0123456789abcdef");'
    'Application.put_env(:smalt, :auth_mode, :enforce);'
    'Application.put_env(:smalt, :amqp_port, 38672);'
    'Application.put_env(:smalt, :event_hubs_port, 38673);'
    'Application.put_env(:smalt, :arm_port, 38654);'
    'Application.put_env(:smalt, :egress_port, 38655);'
    'Application.put_env(:smalt, :arm_tls_port, 38656);'
    '{:ok, _} = Application.ensure_all_started(:smalt);'
    + " ".join(_ENFORCE_BOOT_SEED.split())
)


def pytest_configure(config):
    config.addinivalue_line("markers", "anonymous: needs anonymous auth substrate")
    config.addinivalue_line("markers", "enforce: needs :enforce auth substrate")


@pytest.fixture(scope="session")
def anonymous_substrate():
    """Anonymous-mode substrate (blob/cosmos). Reuse-else-boot under
    /tmp/smalt-substrate-cli4.lock; kills only what it booted."""
    proc = None  # SHIM-COURT: bound before try so post-yield use is total
    try:
        proc, _reused = _ensure_substrate(
            "/tmp/smalt-substrate-cli4.lock", _ANON_PORTS, _ANON_BOOT,
            "/tmp/cli4-substrate.log",
            marker_path="/tmp/cli4-substrate.boot.json",
        )
    except RuntimeError as e:  # R186: loud skip, holder pid + log tail
        _skip_substrate_unavailable(e, "/tmp/smalt-substrate-cli4.lock",
                                    "/tmp/cli4-substrate.log")
    global ARM, EGRESS
    _old = (ARM, EGRESS)
    ARM, EGRESS = "http://127.0.0.1:39643", "http://127.0.0.1:39644"
    yield {"arm": ARM, "egress": EGRESS, "aud": AUD, "sub": SUB}
    ARM, EGRESS = _old
    if proc is not None:  # SHIM-COURT: total path — skip branch never yields
        _kill_substrate(proc)


@pytest.fixture(scope="session")
def enforce_substrate():
    """:enforce substrate (identity/servicebus/eventhub/keyvault). Reuse-else-
    boot under /tmp/smalt-substrate-cli5.lock — fixture-scoped and lazy, the
    F-14 import-time boot is gone."""
    proc = None  # SHIM-COURT: bound before try so post-yield use is total
    try:
        proc, _reused = _ensure_substrate(
            "/tmp/smalt-substrate-cli5.lock", _ENFORCE_PORTS, _ENFORCE_BOOT,
            "/tmp/cli5-substrate.log",
            marker_path="/tmp/cli5-substrate.boot.json",
        )
    except RuntimeError as e:  # R186: loud skip, holder pid + log tail
        _skip_substrate_unavailable(e, "/tmp/smalt-substrate-cli5.lock",
                                    "/tmp/cli5-substrate.log")
    global ARM, EGRESS
    _old = (ARM, EGRESS)
    ARM, EGRESS = "http://127.0.0.1:38654", "http://127.0.0.1:38655"
    yield {"arm": ARM, "egress": EGRESS, "aud": AUD, "sub": SUB}
    ARM, EGRESS = _old
    if proc is not None:  # SHIM-COURT: total path — skip branch never yields
        _kill_substrate(proc)


def seed_resource(name, rg="cli4-rg", location="eastus"):
    st, body = http(
        "PUT",
        f"{ARM}/subscriptions/{SUB}/resourceGroups/{rg}/providers/"
        f"Microsoft.Storage/storageAccounts/{name}?api-version=2021-04-01",
        {"location": location, "properties": {"skuName": "Standard_LRS"}},
        bearer(),
    )
    assert st in (200, 201, 202), f"seed PUT {name} -> {st}: {body}"
    return st


@pytest.fixture(scope="session")
def seeded_resources():
    """Five storage accounts under one RG for resourcegraph pagination."""
    http("PUT", f"{ARM}/subscriptions/{SUB}/resourceGroups/cli4-rg?api-version=2023-07-01",
         {"location": "eastus"}, bearer())
    names = [f"cli4sa{i}" for i in range(1, 6)]
    for n in names:
        seed_resource(n)
    return names

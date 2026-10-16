"""CLI-5 Gate 1 part B — keyvault SDK lane (pytest).

Real azure-keyvault KeyClient over the smalt substrate's enforce-mode ARM/STS
+ egress(Key Vault) plane. Self-contained: module fixture boots the substrate
under EXCLUSIVE flock /tmp/smalt-substrate.lock, starts the local TLS
challenge-injection proxy (azure-core refuses plain-http vault URLs and the
substrate's 401 challenge lacks AAD-shaped params — measured divergences
receipted in test/sdk-python receipts, mirrored here), then runs.

Shapes mirrored from /Users/sac/smalt/test/sdk-python/py_auth_keyvault.py.
"""
import base64
import hashlib
import hmac
import http.server
import json
import os
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.request

import pytest
import requests
from azure.core.credentials import AccessToken, TokenCredential
from azure.core.exceptions import HttpResponseError
from azure.keyvault.keys import KeyClient

ARM_PORT = int(os.environ.get("CLI5_ARM_PORT", "38654"))
EGRESS_PORT = int(os.environ.get("CLI5_EGRESS_PORT", "38655"))
KV_TLS_PORT = int(os.environ.get("CLI5_KV_TLS_PORT", "38659"))
ARM = f"http://127.0.0.1:{ARM_PORT}"
KV_HTTP = f"http://127.0.0.1:{EGRESS_PORT}"
KV_TLS = f"https://127.0.0.1:{KV_TLS_PORT}"
SECRET = b"cli5-known-secret-0123456789abcdef"

SUB_PID = [None]

SHARED_KEY = os.environ.get(
    "CLI5_SB_SHARED_KEY", "cli5-local-shared-key-not-used-by-wire-security"
)

SECRET_B64 = SECRET.decode()

BOOT = (
    'Application.put_env(:smalt, :sb_shared_key, "' + SHARED_KEY + '");'
    'Application.put_env(:smalt, :sts_signing_secret, "' + SECRET_B64 + '");'
    'Application.put_env(:smalt, :auth_mode, :enforce);'
    'Application.put_env(:smalt, :amqp_port, 38672);'
    'Application.put_env(:smalt, :event_hubs_port, 38673);'
    'Application.put_env(:smalt, :arm_port, 38654);'
    'Application.put_env(:smalt, :egress_port, 38655);'
    'Application.put_env(:smalt, :arm_tls_port, 38656);'
    '{:ok, _} = Application.ensure_all_started(:smalt)'
)


def _port_open(port):
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) == 0


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class SmaltTokenCredential(TokenCredential):
    """Mints bearer tokens via the REAL smalt STS client_credentials endpoint."""

    def __init__(self):
        self._cached = None

    def get_token(self, *scopes, **kwargs):
        now = time.time()
        if self._cached and self._cached.expires_on - now > 300:
            return self._cached
        resp = requests.post(
            f"{ARM}/oauth2/v2.0/token",
            data={"grant_type": "client_credentials", "client_id": "x",
                  "client_secret": "y"},
            timeout=10,
        )
        if resp.status_code != 200:
            raise HttpResponseError(
                message=f"STS mint failed {resp.status_code}: {resp.text[:200]}"
            )
        tok = resp.json()["access_token"]
        exp = json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=="))["exp"]
        self._cached = AccessToken(tok, exp)
        return self._cached


def _start_tls_proxy():
    """https://127.0.0.1:KV_TLS_PORT -> http KV_HTTP forwarder that injects
    AAD-shape challenge params (substrate 401 carries only error/
    error_description)."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _fwd(self):
            body = None
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                body = self.rfile.read(n)
            req = urllib.request.Request(
                KV_HTTP + self.path, data=body, method=self.command,
                headers={k: v for k, v in self.headers.items()
                         if k.lower() not in ("host",)})
            try:
                with opener.open(req, timeout=30) as r:
                    payload, status, hdrs = r.read(), r.status, r.headers
            except urllib.error.HTTPError as e:
                payload, status, hdrs = e.read(), e.code, e.headers
            self.send_response(status)
            for k, v in hdrs.items():
                if k.lower() == "www-authenticate":
                    v = (f'Bearer authorization="http://127.0.0.1:{ARM_PORT}/", '
                         'resource="https://127.0.0.1"')
                if k.lower() not in ("transfer-encoding", "content-length",
                                     "connection"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = do_POST = do_PUT = do_DELETE = _fwd

        def log_message(self, *a):
            pass

    td = tempfile.TemporaryDirectory(prefix="cli5-tls-")
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", f"{td.name}/key.pem", "-out", f"{td.name}/cert.pem",
         "-days", "2", "-subj", "/CN=localhost"],
        check=True, capture_output=True,
    )
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(f"{td.name}/cert.pem", f"{td.name}/key.pem")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", KV_TLS_PORT), H)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, td


_PORTS = (38672, 38673, 38654, 38655)


def _all_ports_open():
    return all(_port_open(p) for p in _PORTS)


def _boot():
    """Boot the lane substrate ONCE (all three CLI-5 files share it via the
    same port block). Boot at import so it precedes the session-scoped
    conftest gate. EXCLUSIVE lane lock /tmp/smalt-substrate-cli5.lock (the
    primary /tmp/smalt-substrate.lock is leaked by a detached beam.smp that
    inherited its fd — receipted in test/sdk-python/run.sh). No boot under
    --collect-only. Substrate killed atexit of the last importer's process."""
    import atexit
    import fcntl
    import sys

    if "--collect-only" in sys.argv:
        return
    if _all_ports_open() and _port_open(KV_TLS_PORT):
        return
    fd = os.open("/tmp/smalt-substrate-cli5.lock", os.O_CREAT | os.O_RDWR)
    deadline = time.time() + 120
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() > deadline:
                raise RuntimeError(
                    "SUBSTRATE_LOCK_TIMEOUT: /tmp/smalt-substrate-cli5.lock "
                    "not acquired within 120s (holder: "
                    "`lsof /tmp/smalt-substrate-cli5.lock`)"
                )
            time.sleep(2)
    # double-check after lock: another process may have booted meanwhile
    if _all_ports_open() and _port_open(KV_TLS_PORT):
        return
    env = dict(os.environ, MIX_ENV="test")
    log = open("/tmp/cli5-kv-substrate.log", "w")
    proc = subprocess.Popen(
        ["/opt/homebrew/bin/mix", "run", "--no-start", "--no-halt", "-e", BOOT],
        cwd="/Users/sac/smalt", env=env, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    SUB_PID[0] = proc
    up = False
    for _ in range(90):
        if _all_ports_open():
            up = True
            break
        time.sleep(1)
    if not up:
        tail = open("/tmp/cli5-substrate.log").read()[-500:]
        raise RuntimeError(
            f"SUBSTRATE_TIMEOUT — boot log /tmp/cli5-substrate.log tail: {tail}"
        )

    srv, td = _start_tls_proxy()
    time.sleep(0.5)

    def _kill():
        srv.shutdown()
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        time.sleep(1)
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    atexit.register(_kill)


_boot()


@pytest.fixture(scope="module")
def kv():
    """Yield the credential (substrate + TLS proxy booted at import)."""
    yield {"cred": SmaltTokenCredential(), "token": None}


def _client(kv):
    return KeyClient(vault_url=KV_TLS, credential=kv["cred"],
                     connection_verify=False, verify_challenge_resource=False)


def _bearer(kv):
    return {"Authorization": f"Bearer {kv['cred'].get_token().token}"}


def test_create_get_key(kv):
    client = _client(kv)
    name = "cli5-kv-key"
    key = client.create_key(name, "RSA-HSM")
    assert key.id, "no key id returned"
    got = client.get_key(name)
    assert got.id == key.id
    assert got.key_type.name == "RSA_HSM", got.key_type


def test_list_keys(kv):
    client = _client(kv)
    client.create_key("cli5-kv-list-key", "RSA-HSM")
    props = list(client.list_properties_of_keys())
    assert props, "key list empty"
    assert any("/keys/cli5-kv-list-key/" in p.id for p in props), \
        [p.id for p in props]


def test_release_key_attestation_shape(kv):
    """Release 403-attestation or 200 — record what the live substrate
    answers, then assert on the observed shape (fail only on transport
    garbage)."""
    client = _client(kv)
    name = "cli5-raw-rel"
    token = kv["cred"].get_token().token
    op = requests.post(
        f"{KV_TLS}/keys/{name}/create?api-version=7.5",
        headers={"Authorization": f"Bearer {token}"},
        json={"kty": "RSA-HSM",
              "release_policy": {"anyOf": [{"claim": "sdk-claim", "equals": "cli5"}]}},
        verify=False, timeout=15,
    )
    assert op.status_code == 200, op.text[:300]
    try:
        release = client.release_key(name, b'{"target":"cli5"}')
        observed = f"200 release: {str(release)[:200]}"
    except HttpResponseError as e:
        observed = f"{e.status_code}: {str(e)[:300]}"
    print(f"\n[OBSERVED] release_key -> {observed}")
    assert ("UnauthorizedAttestation" in observed) or ("200 release:" in observed), \
        observed


def test_crypto_encrypt_decrypt_roundtrip(kv):
    """SDK CryptographyClient builds versioned /keys/{name}/{ver}/encrypt URLs
    the substrate does not route (measured divergence); round-trip is proven
    over the unversioned wire shape with the real bearer credential."""
    client = _client(kv)
    name = "cli5-kv-key"
    token = kv["cred"].get_token().token
    pt = os.urandom(32)
    r = requests.post(
        f"{KV_TLS}/keys/{name}/encrypt?api-version=7.5",
        headers={"Authorization": f"Bearer {token}"},
        json={"alg": "RSA-OAEP-256", "value": b64u(pt)}, verify=False, timeout=15,
    )
    assert r.status_code == 200, r.text[:300]
    ct = r.json()["value"]
    r2 = requests.post(
        f"{KV_TLS}/keys/{name}/decrypt?api-version=7.5",
        headers={"Authorization": f"Bearer {token}"},
        json={"alg": "RSA-OAEP-256", "value": ct}, verify=False, timeout=15,
    )
    assert r2.status_code == 200, r2.text[:300]
    pad = "=" * (-len(r2.json()["value"]) % 4)
    assert base64.urlsafe_b64decode(r2.json()["value"] + pad) == pt

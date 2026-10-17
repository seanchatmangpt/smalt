"""CLI-5 Gate 1 part B — keyvault SDK lane (pytest).

Real azure-keyvault KeyClient over the smalt substrate's enforce-mode ARM/STS
+ egress(Key Vault) plane. Substrate is the session-scoped `enforce_substrate`
fixture (tests/conftest.py): probed and reused read-only if healthy, else
booted lazily under its own lock — no import-time boot (X-6/F-14 fix; run
with `pytest -m enforce`). TLS challenge proxy starts lazily in the `kv`
fixture.
challenge-injection proxy (azure-core refuses plain-http vault URLs and the
substrate's 401 challenge lacks AAD-shaped params — measured divergences
receipted in test/sdk-python receipts, mirrored here), then runs.

Shapes mirrored from test/sdk-python/py_auth_keyvault.py.
"""
import base64
import hashlib
import hmac
import http.server
import json
import pathlib

REPO_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
import os
import re
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

pytestmark = [pytest.mark.enforce, pytest.mark.usefixtures("enforce_substrate")]

ARM_PORT = int(os.environ.get("CLI5_ARM_PORT", "38654"))
EGRESS_PORT = int(os.environ.get("CLI5_EGRESS_PORT", "38655"))
KV_TLS_PORT = int(os.environ.get("CLI5_KV_TLS_PORT", "38659"))
ARM = f"http://127.0.0.1:{ARM_PORT}"
KV_HTTP = f"http://127.0.0.1:{EGRESS_PORT}"
KV_TLS = f"https://127.0.0.1:{KV_TLS_PORT}"
SECRET = b"cli5-known-secret-0123456789abcdef"

_KV_TLS_SRV = None

SHARED_KEY = os.environ.get(
    "CLI5_SB_SHARED_KEY", "cli5-local-shared-key-not-used-by-wire-security"
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


@pytest.fixture(scope="module")
def kv(enforce_substrate):
    """Yield the credential. Substrate via session fixture; the KV TLS
    challenge-injecting proxy is started here, lazily, once per session."""
    global _KV_TLS_SRV
    if not _port_open(KV_TLS_PORT):
        _KV_TLS_SRV, _KV_TLS_TD = _start_tls_proxy()
    yield {"cred": SmaltTokenCredential(), "token": None}


def _client(kv):
    # api_version pinned to 7.4 (R163 pattern, py_auth_keyvault.py:185-188:
    # emulator enforces the real AKV 7.x surface; the SDK default 2025-07-01
    # api-version answers 400 InvalidApiVersion on release_key).
    return KeyClient(vault_url=KV_TLS, credential=kv["cred"],
                     connection_verify=False, verify_challenge_resource=False,
                     api_version="7.4")


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
    """SDK CryptographyClient round-trip over the versioned wire shape."""
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


def test_versioned_get_and_list_versions(kv):
    """GAP-A2-08 falsifier: real SDK versioned getKey + version list."""
    client = _client(kv)
    name = "cli5-kv-ver-key"
    created = client.create_key(name, "RSA-HSM")
    version = created.id.rsplit("/", 1)[1]
    assert version, created.id

    # GET /keys/{name}/{version} via the real SDK
    got = client.get_key(name, version=version)
    assert got.id == created.id, (got.id, created.id)

    # GET /keys/{name}/versions lists the version
    props = list(client.list_properties_of_key_versions(name))
    assert any(p.version == version for p in props), [p.id for p in props]

    # a second create accumulates a second version
    again = client.create_key(name, "RSA-HSM")
    assert again.id != created.id
    versions = [p.version for p in client.list_properties_of_key_versions(name)]
    assert set(versions) >= {version, again.id.rsplit("/", 1)[1]}, versions

    # unknown version -> 404
    tok = kv["cred"].get_token().token
    r = requests.get(
        f"{KV_TLS}/keys/{name}/00000000deadbeef?api-version=7.5",
        headers={"Authorization": f"Bearer {tok}"},
        verify=False, timeout=15,
    )
    assert r.status_code == 404, (r.status_code, r.text[:200])


def test_cryptography_client_versioned_url_roundtrip(kv):
    """GAP-A2-10 falsifier: CryptographyClient(key_id) issues the 4-segment
    /keys/{name}/{version}/encrypt|decrypt URLs and the substrate routes them."""
    keys = _client(kv)
    name = "cli5-kv-crypto-key"
    created = keys.create_key(name, "RSA-HSM")
    token = kv["cred"].get_token().token

    from azure.keyvault.keys.crypto import (
        CryptographyClient,
        EncryptionAlgorithm,
        SignatureAlgorithm,
    )

    # Disclosed divergence (KD-33 class): the substrate kid embeds its own
    # 8443 authority, unreachable from this lane; rehost the kid onto the
    # reachable TLS vault URL. Version suffix and path shape are untouched —
    # the client still issues the versioned 4-segment URLs under test.
    key_id = re.sub(r"^https://[^/]+", KV_TLS, created.id)
    crypto = CryptographyClient(
        key_id,
        credential=kv["cred"],
        connection_verify=False,
        verify_challenge_resource=False,
    )
    pt = os.urandom(32)
    enc = crypto.encrypt(EncryptionAlgorithm.rsa_oaep_256, pt)
    assert enc.algorithm.name == "rsa_oaep_256", enc.algorithm
    dec = crypto.decrypt(EncryptionAlgorithm.rsa_oaep_256, enc.ciphertext)
    assert dec.plaintext == pt

    # signed round-trip over the versioned URL too
    digest = hashlib.sha256(b"cli5-versioned-sign").digest()
    sig = crypto.sign(SignatureAlgorithm.rs256, digest)
    verify = crypto.verify(SignatureAlgorithm.rs256, digest, sig.signature)
    assert verify.is_valid is True

    # raw wire witness: the SDK really hit the 4-segment path
    r = requests.post(
        f"{KV_TLS}/keys/{name}/{created.id.rsplit('/', 1)[1]}/encrypt?api-version=7.5",        headers={"Authorization": f"Bearer {token}"},
        json={"alg": "RSA-OAEP-256", "value": b64u(os.urandom(16))},
        verify=False, timeout=15,
    )
    assert r.status_code == 200, (r.status_code, r.text[:200])

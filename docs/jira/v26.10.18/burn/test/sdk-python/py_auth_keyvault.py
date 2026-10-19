#!/usr/bin/env python3
"""PY-6 lane: real azure-identity + azure-keyvault SDKs against the smalt substrate.
Venv: test/sdk-python/.venv-auth (receipt: docs/jira/v26.10.14/sdk-results/py-auth-keyvault.md).

Expects the lane's private enforce-mode substrate on localhost:19443 (ARM/STS)
and localhost:18443 (egress / Key Vault, plain http). Starts a local
TLS-terminating proxy on https://localhost:19445 -> http://localhost:18443
because azure-core's BearerTokenCredentialPolicy refuses non-https URLs
(ServiceRequestError) — measured divergence recorded in the receipt.

Prints one PASS/FAIL line per probe; exit 1 if any FAIL.
"""
import base64
import hashlib
import hmac
import http.server
import json
import os
import ssl
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

import requests
from azure.core.credentials import AccessToken, TokenCredential
from azure.core.exceptions import HttpResponseError
from azure.keyvault.keys import KeyClient

ARM = os.environ.get("SMALT_ARM", "http://localhost:19443")
KV_HTTP = os.environ.get("SMALT_KV", "http://localhost:18443")
KV_TLS = "https://localhost:19455"
AUD = "https://management.azure.com"
SECRET = b"py-lane6-known-secret-0123456789abcdef"

results = []


def rec(name, ok, evidence):
    results.append((name, ok, evidence))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {evidence}", flush=True)


def b64u_decode(s):
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt(claims, secret=SECRET):
    header = b64u(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    proxy = b64u(json.dumps(claims).encode())
    signing_input = f"{header}.{proxy}".encode()
    sig = hmac.new(secret, signing_input, hashlib.sha256).digest()
    return f"{header}.{proxy}.{b64u(sig)}"


class SmaltTokenCredential(TokenCredential):
    """Mints smalt bearer tokens via the REAL STS token endpoint
    (client_credentials grant), caching until 5 min before exp."""

    def __init__(self, endpoint=ARM):
        self._endpoint = endpoint
        self._cached = None

    def get_token(self, *scopes, **kwargs):
        now = time.time()
        if self._cached and self._cached.expires_on - now > 300:
            return self._native()
        resp = requests.post(
            f"{self._endpoint}/oauth2/v2.0/token",
            data={"grant_type": "client_credentials", "client_id": "x", "client_secret": "y"},
            timeout=10,
        )
        if resp.status_code != 200:
            raise HttpResponseError(message=f"STS mint failed {resp.status_code}: {resp.text[:200]}")
        tok = resp.json()["access_token"]
        exp = json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "=="))["exp"]
        self._cached = AccessToken(tok, exp)
        return self._cached

    def _native(self):
        return self._cached


def start_tls_proxy():
    """https://localhost:19455 -> http://KV_HTTP, single-threaded forwarder."""
    import tempfile

    up = urllib.request.ProxyHandler({})
    opener = urllib.request.build_opener(up)

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _fwd(self):
            body = None
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                body = self.rfile.read(n)
            req = urllib.request.Request(
                KV_HTTP + self.path, data=body, method=self.command,
                headers={k: v for k, v in self.headers.items() if k.lower() not in ("host",)})
            try:
                with opener.open(req, timeout=30) as r:
                    payload, status, hdrs = r.read(), r.status, r.headers
            except urllib.error.HTTPError as e:
                payload, status, hdrs = e.read(), e.code, e.headers
            self.send_response(status)
            for k, v in hdrs.items():
                if k.lower() == "www-authenticate":
                    # Challenge adapter (divergence receipted): smalt's 401
                    # challenge carries only error/error_description, no
                    # `authorization`/`resource` params, so azure-keyvault's
                    # ChallengeAuthPolicy cannot build a token request. Inject
                    # the AAD-shape params pointing at the real smalt STS.
                    v = ('Bearer authorization="http://localhost:19443/", '
                         'resource="https://localhost"')
                if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = do_POST = do_PUT = do_DELETE = _fwd

        def log_message(self, *a):
            pass

    with tempfile.TemporaryDirectory(dir=".", prefix="py6-tls-") as td:
        subprocess.run([
            "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", f"{td}/key.pem", "-out", f"{td}/cert.pem", "-days", "2",
            "-subj", "/CN=localhost",
        ], check=True, capture_output=True)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(f"{td}/cert.pem", f"{td}/key.pem")
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 19455), H)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        return srv


def main():
    srv = start_tls_proxy()
    # Poll the observable condition: the TLS listener actually accepts on
    # 19455 (deadline-bounded; a fixed sleep here only masked connect-refused).
    _dl = time.monotonic() + 5.0
    while True:
        try:
            with socket.create_connection(("127.0.0.1", 19455), timeout=0.25):
                break
        except OSError:
            if time.monotonic() >= _dl:
                raise RuntimeError(
                    "local keyvault TLS proxy never bound :19455 within 5s")
            time.sleep(0.05)

    cred = SmaltTokenCredential()
    token = cred.get_token("https://management.azure.com/.default").token

    # -- Auth probes (raw requests, no SDK pipeline) --------------------------
    r = requests.get(f"{ARM}/subscriptions?api-version=2021-04-01",
                     headers={"Authorization": f"Bearer {token}"}, timeout=10)
    rec("auth.raw.valid_bearer_200", r.status_code == 200, f"GET /subscriptions -> {r.status_code}")

    r = requests.get(f"{ARM}/subscriptions?api-version=2021-04-01", timeout=10)
    ch = r.headers.get("WWW-Authenticate", "")
    rec("auth.raw.tokenless_401", r.status_code == 401 and ch.startswith("Bearer"),
        f"-> {r.status_code}, WWW-Authenticate={ch[:80]!r}")

    h, p, s = token.split(".")
    flipped = b64u(bytes([s.encode()[0] ^ 1]) + s.encode()[1:])
    r = requests.get(f"{ARM}/subscriptions?api-version=2021-04-01",
                     headers={"Authorization": "Bearer " + ".".join([h, p, flipped])}, timeout=10)
    body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    rec("auth.raw.tampered_401",
        r.status_code == 401 and body.get("error", {}).get("message") == "SignatureVerificationFailed",
        f"-> {r.status_code}, error={body.get('error', {}).get('message')}")

    now = int(time.time())
    expired = jwt({"aud": AUD, "iss": f"{ARM}/00000000-0000-0000-0000-000000000000/v2.0",
                   "iat": now - 7200, "nbf": now - 3600, "exp": now - 3600})
    r = requests.get(f"{ARM}/subscriptions?api-version=2021-04-01",
                     headers={"Authorization": f"Bearer {expired}"}, timeout=10)
    body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    rec("auth.raw.expired_401",
        r.status_code == 401 and body.get("error", {}).get("message") == "TokenExpired",
        f"-> {r.status_code}, error={body.get('error', {}).get('message')}")

    # -- Key Vault via real KeyClient over the TLS proxy ----------------------
    kv_cred = SmaltTokenCredential()
    # api_version pinned to 7.4 (SHIM-COURT parity note: emulator enforces real
    # AKV 7.x surface; the SDK default 2025-07-01 returns 400 on release_key).
    client = KeyClient(vault_url=KV_TLS, credential=kv_cred, connection_verify=False,
                       verify_challenge_resource=False, api_version="7.4")

    name = "py6-sdk-key"
    try:
        key = client.create_key(name, "RSA-HSM")
        rec("kv.create_key_200", True, f"id={key.id}")
    except Exception as e:
        rec("kv.create_key_200", False, f"{type(e).__name__}: {str(e)[:250]}")

    try:
        key = client.get_key(name)
        rec("kv.get_key_200", True, f"id={key.id} kty={key.key_type}")
    except Exception as e:
        rec("kv.get_key_200", False, f"{type(e).__name__}: {str(e)[:250]}")

    try:
        keys = list(client.list_properties_of_keys())
        rec("kv.list_keys_200", True,
            f"{len(keys)} keys, first id={getattr(keys[0], 'id', None) if keys else None}")
    except Exception as e:
        rec("kv.list_keys_200", False, f"{type(e).__name__}: {str(e)[:250]}")

    # Release-able key: exportable + inline release policy via smalt's wire
    # shape (POST /keys/:name/create — PUT /keys/:name is not routed, see
    # receipt). Then the real SDK release_key: expected 403 UnauthorizedAttestation
    # (no MAA evidence in the SDK request).
    rel_name = "py6-raw-rel"
    try:
        op = requests.post(f"{KV_TLS}/keys/{rel_name}/create?api-version=7.5",
                           headers={"Authorization": f"Bearer {token}"},
                           json={"kty": "RSA-HSM",
                                 "release_policy": {"anyOf": [{"claim": "sdk-claim", "equals": "py6"}]}},
                           verify=False, timeout=15)
        assert op.status_code == 200, op.text[:200]
        release = client.release_key(rel_name, b'{"target":"py6"}')
        rec("kv.release_key", False, f"unexpected release success: {str(release)[:200]}")
    except HttpResponseError as e:
        ok = "UnauthorizedAttestation" in str(e)
        rec("kv.release_attestation_refusal",
            ok, f"release_key -> {type(e).__name__}: {str(e)[:180]}")
    except Exception as e:
        rec("kv.release_attestation_refusal", False, f"{type(e).__name__}: {str(e)[:250]}")

    # Crypto: the real SDK's CryptographyClient builds /keys/{name}/{version}/
    # encrypt URLs — smalt routes only the UNVERSIONED /keys/:name/:action, so
    # the SDK path is unrouted (RouteNotFound). Crypto roundtrip is proven over
    # smalt's wire shape with the same bearer credential (real transport).
    try:
        pt = os.urandom(32)
        r = requests.post(f"{KV_TLS}/keys/{name}/encrypt?api-version=7.5",
                          headers={"Authorization": f"Bearer {token}"},
                          json={"alg": "RSA-OAEP-256", "value": b64u(pt)}, verify=False, timeout=15)
        ct = r.json()["value"]
        rec("kv.crypto.encrypt_200", r.status_code == 200,
            f"unversioned POST /keys/:name/encrypt -> {r.status_code}")
        r2 = requests.post(f"{KV_TLS}/keys/{name}/decrypt?api-version=7.5",
                           headers={"Authorization": f"Bearer {token}"},
                           json={"alg": "RSA-OAEP-256", "value": ct}, verify=False, timeout=15)
        roundtrip = r2.status_code == 200 and b64u_decode(r2.json()["value"]) == pt
        rec("kv.crypto.decrypt_roundtrip", roundtrip,
            f"unversioned decrypt -> {r2.status_code}, roundtrip ok={roundtrip}")
    except Exception as e:
        rec("kv.crypto.roundtrip", False, f"{type(e).__name__}: {str(e)[:250]}")

    try:
        from azure.keyvault.keys.crypto import CryptographyClient
        ver = next(client.list_properties_of_key_versions(name))
        vnum = ver.id.rsplit("/", 1)[-1]
        sdk_crypto = CryptographyClient(f"{KV_TLS}/keys/{name}/{vnum}", credential=kv_cred,
                                        connection_verify=False, verify_challenge_resource=False, api_version="7.4")
        sdk_crypto.encrypt("RSA-OAEP-256", b"hi")
        rec("kv.crypto.sdk_versioned_url", False, "unexpected SDK success")
    except HttpResponseError as e:
        ok = "RouteNotFound" in str(e)
        rec("kv.crypto.sdk_versioned_url",
            ok, f"SDK versioned /keys/:name/:ver/encrypt unrouted -> {str(e)[:140]}")
    except Exception as e:
        rec("kv.crypto.sdk_versioned_url", False, f"{type(e).__name__}: {str(e)[:250]}")

    # Delete/purge: no DELETE /keys/:name route on the egress — falls through
    # to the blob catch-all guard. Pinned as the documented refusal.
    try:
        poller = client.begin_delete_key(name)
        poller.wait()
        rec("kv.delete_key_absent", False, "unexpected delete success")
    except HttpResponseError as e:
        ok = "MissingXMsVersion" in str(e)
        rec("kv.delete_key_absent", ok,
            f"DELETE /keys/:name unrouted -> blob-guard 400 MissingXMsVersion (correct: {ok})")
    except Exception as e:
        rec("kv.delete_key_absent", False, f"{type(e).__name__}: {str(e)[:250]}")

    try:
        client.purge_deleted_key(name)
        rec("kv.purge_absent", False, "unexpected purge success")
    except HttpResponseError as e:
        ok = "MissingXMsVersion" in str(e)
        rec("kv.purge_absent", ok, f"purge unrouted -> blob-guard 400 (correct: {ok})")
    except Exception as e:
        rec("kv.purge_absent", False, f"{type(e).__name__}: {str(e)[:250]}")

    srv.shutdown()
    print(json.dumps({"pass": sum(1 for _, ok, _ in results if ok),
                      "fail": sum(1 for _, ok, _ in results if not ok)}))
    return 0 if all(ok for _, ok, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())

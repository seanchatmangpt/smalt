"""Gateway tests: STS token shape, interceptor refusal, proxy round-trip.

Zero egress beyond 127.0.0.1: every live HTTP hop in this module targets a
loopback stub server, and the proxy constructor refuses non-loopback
substrates outright.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from smalt_cli.gateway.interceptor import (
    FORBIDDEN_ENVELOPE_TYPE,
    MUTATION_VERBS,
    MutationInterceptor,
    refusal_envelope,
)
from smalt_cli.gateway.proxy import DEFAULT_SUBSTRATE, GatewayProxy
from smalt_cli.gateway.sts import LocalSTS


def _b64url_decode(seg: str) -> bytes:
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


class STSTests(unittest.TestCase):
    def test_token_header_and_signature_verify(self) -> None:
        sts = LocalSTS(secret=b"test-secret")
        token = sts.issue("client-a")
        header_b64, payload_b64, sig_b64 = token.split(".")
        header = json.loads(_b64url_decode(header_b64))
        self.assertEqual(header["alg"], "HS256")
        self.assertEqual(header["typ"], "JWT")
        # independently recompute the HMAC from the standard library
        expected = base64.urlsafe_b64encode(
            hmac.new(b"test-secret", f"{header_b64}.{payload_b64}".encode(), hashlib.sha256).digest()
        ).rstrip(b"=").decode()
        self.assertEqual(expected, sig_b64)

    def test_claims_shape_and_configurability(self) -> None:
        sts = LocalSTS(
            issuer="https://sts.smalt.local/test",
            audience="https://mgmt.smalt.local/",
            tenant_id="tid-fixed",
        )
        fixed_now = 1_700_000_000
        token = sts.issue(
            "client-a", oid="oid-1", tid="tid-override", extra={"roles": ["reader"]}, now=fixed_now
        )
        _, claims = sts.decode(token, verify=False)  # fixed_now is historical
        self.assertEqual(claims["iss"], "https://sts.smalt.local/test")
        self.assertEqual(claims["aud"], "https://mgmt.smalt.local/")
        self.assertEqual(claims["oid"], "oid-1")
        self.assertEqual(claims["tid"], "tid-override")
        self.assertEqual(claims["nbf"], fixed_now)
        self.assertEqual(claims["exp"], fixed_now + sts.ttl_seconds)
        self.assertEqual(claims["roles"], ["reader"])

    def test_bad_signature_rejected_and_expiry_enforced(self) -> None:
        sts = LocalSTS(ttl_seconds=60)
        token = sts.issue("c")
        forged = token[:-4] + ("AAAA" if not token.endswith("AAAA") else "BBBB")
        with self.assertRaises(ValueError):
            sts.decode(forged)
        expired = sts.issue("c", ttl_seconds=1, now=1_000_000)
        with self.assertRaises(ValueError):
            sts.decode(expired)

    def test_client_credentials_response_shape(self) -> None:
        resp = LocalSTS().client_credentials("c")
        self.assertEqual(resp["token_type"], "Bearer")
        self.assertEqual(resp["expires_in"], 3600)
        self.assertIn(".", resp["access_token"])


class InterceptorTests(unittest.TestCase):
    def test_put_refused_with_typed_403(self) -> None:
        seen: list[dict] = []
        it = MutationInterceptor(ledger=seen.append)
        result = it.check("PUT", "/blob/container/blob")
        self.assertIsNotNone(result)
        status, envelope = result  # type: ignore[misc]
        self.assertEqual(status, 403)
        self.assertEqual(envelope["type"], FORBIDDEN_ENVELOPE_TYPE)
        self.assertEqual(envelope["error"]["code"], "MutationRefused")
        self.assertEqual(envelope["error"]["method"], "PUT")
        self.assertEqual(len(seen), 1, "ledger callback must see the refusal")

    def test_get_passes_through(self) -> None:
        seen: list[dict] = []
        it = MutationInterceptor(ledger=seen.append)
        self.assertIsNone(it.check("GET", "/blob/container"))
        self.assertIsNone(it.check("HEAD", "/"))
        self.assertEqual(seen, [])

    def test_all_mutation_verbs_refused(self) -> None:
        it = MutationInterceptor()
        for verb in sorted(MUTATION_VERBS):
            self.assertEqual(it.check(verb)[0], 403, verb)  # type: ignore[index]

    def test_ledger_failure_does_not_block_refusal(self) -> None:
        def boom(_env: dict) -> None:
            raise RuntimeError("ledger down")

        it = MutationInterceptor(ledger=boom)
        status, _ = it.check("DELETE", "/x")  # type: ignore[misc]
        self.assertEqual(status, 403)

    def test_envelope_shape_helper(self) -> None:
        env = refusal_envelope("post", "/p")
        self.assertEqual(env["error"]["method"], "POST")


class _StubSubstrate(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        body = json.dumps({"path": self.path, "host": self.headers.get("Host")}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Stub", "substrate")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        pass


class ProxyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _StubSubstrate)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def test_round_trip_get_through_proxy_core(self) -> None:
        proxy = GatewayProxy(substrate=f"http://127.0.0.1:{self.port}")
        status, headers, body = proxy.forward(
            "GET", "/blob/c1?restype=container&comp=list", [("X-Client", "smalt-cli")], b""
        )
        self.assertEqual(status, 200)
        self.assertIn(("X-Stub", "substrate"), headers)
        payload = json.loads(body)
        self.assertEqual(payload["path"], "/blob/c1?restype=container&comp=list")
        self.assertTrue(payload["host"].startswith("127.0.0.1"), "Host rewritten to substrate")

    def test_mutation_never_reaches_substrate(self) -> None:
        proxy = GatewayProxy(substrate=f"http://127.0.0.1:{self.port}")
        status, headers, body = proxy.forward("PUT", "/blob/c1/blob", [], b"data")
        self.assertEqual(status, 403)
        envelope = json.loads(body)
        self.assertEqual(envelope["type"], FORBIDDEN_ENVELOPE_TYPE)
        self.assertIn("Content-Type", {k for k, _ in headers})

    def test_zero_egress_non_loopback_substrate_refused(self) -> None:
        with self.assertRaises(ValueError):
            GatewayProxy(substrate="https://smalt.example.com")
        with self.assertRaises(ValueError):
            GatewayProxy(substrate="http://10.1.2.3:8080")

    def test_default_substrate_is_loopback(self) -> None:
        self.assertTrue(DEFAULT_SUBSTRATE.startswith("http://127.0.0.1"))

    def test_http_server_handler_end_to_end(self) -> None:
        import urllib.request

        proxy = GatewayProxy(substrate=f"http://127.0.0.1:{self.port}")
        gw = proxy.serve("127.0.0.1", 0)
        gt = threading.Thread(target=gw.serve_forever, daemon=True)
        gt.start()
        try:
            gport = gw.server_address[1]
            with urllib.request.urlopen(f"http://127.0.0.1:{gport}/cosmos/dbs/db1") as resp:
                self.assertEqual(resp.status, 200)
                payload = json.loads(resp.read())
                self.assertEqual(payload["path"], "/cosmos/dbs/db1")
        finally:
            gw.shutdown()
            gw.server_close()


if __name__ == "__main__":
    unittest.main()

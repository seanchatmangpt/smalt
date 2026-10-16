"""Stdlib reverse proxy: Azure SDK HTTP -> smalt substrate endpoints.

``http.server`` based (no asyncio). Forwards requests to the substrate URL
from env config, strips hop-by-hop headers, streams the response body back in
chunks. Reads-only policy enforcement is delegated to
:class:`smalt_cli.gateway.interceptor.MutationInterceptor`.
"""

from __future__ import annotations

import os
import urllib.request
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from smalt_cli.gateway.interceptor import MutationInterceptor

__all__ = ["GatewayProxy", "HOP_BY_HOP", "DEFAULT_SUBSTRATE"]

HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "proxy-connection",
    }
)

DEFAULT_SUBSTRATE = "http://127.0.0.1:8080"

_ENV_SUBSTRATE = "SMALT_SUBSTRATE_URL"
_ENV_BIND = "SMALT_GATEWAY_BIND"
_ENV_PORT = "SMALT_GATEWAY_PORT"


def substrate_url() -> str:
    return os.environ.get(_ENV_SUBSTRATE, DEFAULT_SUBSTRATE)


class GatewayProxy:
    """Configurable reverse-proxy core; ``http.server`` handler factories."""

    def __init__(
        self,
        substrate: str | None = None,
        interceptor: MutationInterceptor | None = None,
    ) -> None:
        self.substrate = (substrate or substrate_url()).rstrip("/")
        _enforce_loopback(self.substrate)
        self.interceptor = interceptor or MutationInterceptor()

    # -- request translation -------------------------------------------------

    def build_upstream_request(self, method: str, path: str, headers: list[tuple[str, str]],
                               body: bytes) -> urllib.request.Request:
        req_headers = {
            k: v for k, v in headers if k.lower() not in HOP_BY_HOP and k.lower() != "host"
        }
        req_headers["Host"] = _host_of(self.substrate)
        req = urllib.request.Request(self.substrate + path, data=body or None, method=method)
        for k, v in req_headers.items():
            req.add_header(k, v)
        return req

    def forward(self, method: str, path: str, headers: list[tuple[str, str]],
                body: bytes) -> tuple[int, list[tuple[str, str]], bytes]:
        """One proxy hop: returns ``(status, response_headers, body)``."""
        blocked = self.interceptor.check(method, path)
        if blocked is not None:
            status, envelope = blocked
            return status, [("Content-Type", "application/json")], _json_bytes(envelope)
        req = self.build_upstream_request(method, path, headers, body)
        try:
            with urllib.request.urlopen(req) as resp:  # noqa: S310 - loopback substrate
                return resp.status, list(resp.getheaders()), resp.read()
        except urllib.error.HTTPError as err:
            return err.code, list(err.headers.items()), err.read()

    # -- server wiring -------------------------------------------------------

    def handler_class(self) -> type[BaseHTTPRequestHandler]:
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _relay(self, verb: str) -> None:
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                status, resp_headers, resp_body = proxy.forward(
                    verb, self.path, list(self.headers.items()), body
                )
                self.send_response(status)
                sent = {"server", "date"}
                for k, v in resp_headers:
                    if k.lower() not in HOP_BY_HOP and k.lower() not in sent:
                        sent.add(k.lower())
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(resp_body)))
                self.end_headers()
                self.wfile.write(resp_body)

            def do_GET(self) -> None:
                self._relay("GET")

            def do_HEAD(self) -> None:
                self._relay("HEAD")

            def do_POST(self) -> None:
                self._relay("POST")

            def do_PUT(self) -> None:  # pragma: no cover - refusal path covered via POST
                self._relay("PUT")

            def do_PATCH(self) -> None:
                self._relay("PATCH")

            def do_DELETE(self) -> None:
                self._relay("DELETE")

            def do_OPTIONS(self) -> None:
                self._relay("OPTIONS")

            def log_message(self, fmt: str, *args: Any) -> None:
                pass  # quiet in tests

        return Handler

    def serve(self, bind: str = "127.0.0.1", port: int = 18443) -> ThreadingHTTPServer:
        server = ThreadingHTTPServer((bind, port), self.handler_class())
        return server


def _enforce_loopback(url: str) -> None:
    """Zero-egress gate: the substrate must be loopback (127.0.0.1/localhost)."""
    host = urlsplit(url).hostname or ""
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError(
            f"egress refused: substrate host {host!r} is not loopback "
            "(zero-egress policy: only 127.0.0.1 is permitted)"
        )


def _host_of(url: str) -> str:
    parts = urlsplit(url)
    return parts.netloc or url


def _json_bytes(obj: Any) -> bytes:
    import json

    return json.dumps(obj).encode("utf-8")

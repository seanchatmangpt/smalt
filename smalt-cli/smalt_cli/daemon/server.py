"""smalt-cli daemon bridge server — stdlib-only, loopback-only.

Two transports, one dispatch:

- RFC6455 WebSocket on ``GET /ws``: minimal handshake (``Sec-WebSocket-Accept``
  = base64(sha1(key + GUID))), masked client text-frame decode (fragmentation
  and control frames handled), server text-frame encode (server frames never
  masked). One JSON-RPC request per frame, one response per frame.
- HTTP POST ``/rpc`` fallback: identical JSON-RPC body semantics.

Loopback-only: the listener binds ``127.0.0.1`` explicitly, never ``0.0.0.0``.

JSON-RPC 2.0 methods (payload shapes in ``daemon/__init__.py``):

- ``tree.snapshot``       -> NavNode-compatible hierarchy
- ``node.telemetry {id}`` -> telemetry dict from the source seam
- ``ledger.tail {n}``     -> last n records + tailHash + intact
- ``hw.status``           -> serial gateway status envelope
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import socketserver
import struct
import sys
import threading
from typing import Any, Callable, Dict, List, Optional, Tuple

from smalt_cli.daemon.source import TelemetrySource, load_source

HOST = "127.0.0.1"
PORT = 18742
WS_PATH = "/ws"
RPC_PATH = "/rpc"
_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

__all__ = [
    "HOST", "PORT", "WS_PATH", "RPC_PATH", "JsonRpcError",
    "json_rpc_dispatch", "build_method_table",
    "DaemonHTTPRequestHandler", "DaemonServer", "serve", "main",
]


class JsonRpcError(Exception):
    """Typed JSON-RPC error; methods raise it, the dispatcher renders it."""

    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def json_rpc_dispatch(
    method_table: Dict[str, Callable[[dict], Any]],
    raw: str,
) -> Dict[str, Any]:
    """Dispatch one JSON-RPC 2.0 request string -> response dict.

    Total over all input strings: every failure mode becomes a typed error
    object (-32700 parse error, -32600 invalid request, -32601 method not
    found, -32602 invalid params, -32603 internal error with no traceback
    leakage). Verified in smalt_cli/test_daemon.py.
    """
    try:
        req = json.loads(raw)
    except (json.JSONDecodeError, ValueError, TypeError):
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
    if (
        not isinstance(req, dict)
        or req.get("jsonrpc") != "2.0"
        or not isinstance(req.get("method"), str)
    ):
        rid = req.get("id") if isinstance(req, dict) else None
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32600, "message": "Invalid Request"}}
    rid = req.get("id")
    handler = method_table.get(req["method"])
    if handler is None:
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {"code": -32601, "message": "Method not found: %s" % req["method"]},
        }
    params = req.get("params") or {}
    if not isinstance(params, dict):
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {"code": -32602, "message": "Invalid params: params must be an object"},
        }
    try:
        result = handler(params)
    except JsonRpcError as exc:
        error: Dict[str, Any] = {"code": exc.code, "message": exc.message}
        if exc.data is not None:
            error["data"] = exc.data
        return {"jsonrpc": "2.0", "id": rid, "error": error}
    except Exception as exc:  # noqa: BLE001 - dispatcher is total
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "Internal error: %s" % exc}}
    return {"jsonrpc": "2.0", "id": rid, "result": result}


# ---------------------------------------------------------------------------
# tree.snapshot payload
# ---------------------------------------------------------------------------

_VEHICLE_NAMES = ("kestrel", "merlin", "osprey")


def _payload_node(parent_id: str, pi: int) -> Dict[str, Any]:
    return {
        "id": "%s-payload-%d" % (parent_id, pi),
        "label": "Payload %c%d" % (chr(ord("A") + pi), pi),
        "kind": "payload",
        "expandable": False,
    }


def _vehicle_node(parent_id: str, vi: int) -> Dict[str, Any]:
    vid = "%s-vehicle-%s" % (parent_id, _VEHICLE_NAMES[vi % len(_VEHICLE_NAMES)])
    return {
        "id": vid,
        "label": _VEHICLE_NAMES[vi % len(_VEHICLE_NAMES)].capitalize(),
        "kind": "vehicle",
        "expandable": True,
        "declaredChildCount": 2,
        "children": [_payload_node(vid, p) for p in range(2)],
    }


def _squadron_node(parent_id: str, si: int) -> Dict[str, Any]:
    sid = "%s-squadron-%d" % (parent_id, si)
    return {
        "id": sid,
        "label": "Squadron %d" % si,
        "kind": "squadron",
        "expandable": True,
        "declaredChildCount": len(_VEHICLE_NAMES),
        "children": [_vehicle_node(sid, v) for v in range(len(_VEHICLE_NAMES))],
    }


def deterministic_tree() -> List[Dict[str, Any]]:
    """Deterministic constellation->squadron->vehicle->payload hierarchy.

    Field names aligned with workspace/lib/navigator/tree-model.ts
    (``id``/``label``/``kind``/``expandable``/``declaredChildCount``/``children``).
    """
    cid = "constellation-0"
    return [{
        "id": cid,
        "label": "Constellation 0",
        "kind": "constellation",
        "expandable": True,
        "declaredChildCount": 2,
        "children": [_squadron_node(cid, si) for si in range(2)],
    }]


def build_method_table(
    source: TelemetrySource,
    ledger_path: Optional[str] = None,
) -> Dict[str, Callable[[dict], Any]]:
    """Wire method names to implementations (transport-independent, testable)."""

    def tree_snapshot(params: dict) -> Any:
        return {"roots": deterministic_tree()}

    def node_telemetry(params: dict) -> Any:
        node_id = params.get("id")
        if not isinstance(node_id, str) or not node_id:
            raise JsonRpcError(-32602, "Invalid params: 'id' must be a non-empty string")
        return source.telemetry(node_id)

    def ledger_tail(params: dict) -> Any:
        n = params.get("n", 50)
        if not isinstance(n, int) or isinstance(n, bool) or n < 1 or n > 10_000:
            raise JsonRpcError(-32602, "Invalid params: 'n' must be an integer in [1, 10000]")
        return ledger_tail_read(ledger_path, n)

    def hw_status(params: dict) -> Any:
        return {
            "serial": _serial_status(),
            "telemetrySource": getattr(source, "name", "unknown"),
            "uptime_s": None,
        }

    return {
        "tree.snapshot": tree_snapshot,
        "node.telemetry": node_telemetry,
        "ledger.tail": ledger_tail,
        "hw.status": hw_status,
    }


def ledger_tail_read(path: Optional[str], n: int) -> Dict[str, Any]:
    """Last ``n`` records of a JSONL audit ledger + chain-head ``tailHash``.

    Mirrors smalt_cli/ledger.py record shape. Never raises: a missing file is
    an empty ledger; malformed lines are surfaced via ``malformedLines``.
    """
    records: List[Dict[str, Any]] = []
    malformed = 0
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    malformed += 1
                    continue
                if isinstance(rec, dict):
                    records.append(rec)
    tail = records[-n:] if n < len(records) else records
    tail_hash = "GENESIS"
    if records:
        last = records[-1]
        tail_hash = last["hash"] if isinstance(last.get("hash"), str) else "GENESIS"
    return {
        "records": tail,
        "tailHash": tail_hash,
        "count": len(tail),
        "total": len(records),
        "malformedLines": malformed,
        "intact": malformed == 0,
    }


def _serial_status() -> Dict[str, Any]:
    """Report the serial backend without hard-requiring pyserial."""
    try:
        import serial  # type: ignore import-not-found

        return {"status": "READY", "backend": "pyserial", "version": getattr(serial, "VERSION", None)}
    except Exception:  # noqa: BLE001 - degradation, not failure
        return {"status": "UNSUPPORTED", "backend": "none", "reason": "pyserial unavailable"}


# ---------------------------------------------------------------------------
# RFC6455 frame codec
# ---------------------------------------------------------------------------

_OP_CONT = 0x0
_OP_TEXT = 0x1
_OP_CLOSE = 0x8
_OP_PING = 0x9
_OP_PONG = 0xA


def ws_accept_key(client_key: str) -> str:
    """RFC6455 section 4.2.2 accept-key derivation."""
    digest = hashlib.sha1((client_key + _WS_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def ws_encode_text(payload: str) -> bytes:
    """Encode one unmasked text frame (server->client)."""
    data = payload.encode("utf-8")
    header = bytearray([0x80 | _OP_TEXT])  # FIN + text
    n = len(data)
    if n < 126:
        header.append(n)
    elif n < 65_536:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    return bytes(header) + data


def ws_decode_frame(buf: bytes) -> Tuple[Optional[Tuple[int, bytes]], int]:
    """Decode one client frame from ``buf``.

    Returns ``((opcode, payload), consumed)`` or ``(None, 0)`` when the buffer
    holds an incomplete frame. Client frames must be masked (RFC6455 5.3);
    unmasked frames raise ``ValueError``.
    """
    if len(buf) < 2:
        return None, 0
    b0, b1 = buf[0], buf[1]
    opcode = b0 & 0x0F
    masked = bool(b1 & 0x80)
    length = b1 & 0x7F
    offset = 2
    if length == 126:
        if len(buf) < offset + 2:
            return None, 0
        length = struct.unpack(">H", buf[offset:offset + 2])[0]
        offset += 2
    elif length == 127:
        if len(buf) < offset + 8:
            return None, 0
        length = struct.unpack(">Q", buf[offset:offset + 8])[0]
        offset += 8
    mask = b""
    if masked:
        if len(buf) < offset + 4:
            return None, 0
        mask = buf[offset:offset + 4]
        offset += 4
    if len(buf) < offset + length:
        return None, 0
    payload = buf[offset:offset + length]
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return (opcode, payload), offset + length


class _WsConnection:
    """Frame-level session over a duplex socket: decode loop, ping/close."""

    def __init__(self, rfile, wfile) -> None:
        self.rfile = rfile
        self.wfile = wfile
        self._outbuf = b""

    def send_text(self, text: str) -> None:
        self.wfile.write(ws_encode_text(text))
        self.wfile.flush()

    def _send_pong(self, payload: bytes) -> None:
        self.wfile.write(bytes([0x80 | _OP_PONG, len(payload)]) + payload)
        self.wfile.flush()

    def _send_close(self, code: int = 1000) -> None:
        self.wfile.write(bytes([0x80 | _OP_CLOSE, 2]) + struct.pack(">H", code))
        self.wfile.flush()

    def recv_message(self) -> Optional[str]:
        """Next complete text message, or ``None`` on close/error."""
        chunks: List[bytes] = []
        while True:
            frame = _read_frame(self.rfile)
            if frame is None:
                return None
            opcode, payload = frame
            if opcode == _OP_TEXT:
                chunks = [payload]
            elif opcode == _OP_CONT:
                chunks.append(payload)
            elif opcode == _OP_PING:
                self._send_pong(payload)
                continue
            elif opcode in (_OP_CLOSE,):
                self._send_close()
                return None
            else:
                continue
            try:
                return b"".join(chunks).decode("utf-8")
            except UnicodeDecodeError:
                return None


def _read_frame(rfile) -> Optional[Tuple[int, bytes]]:
    """Read one frame from a file object; ``None`` on EOF/protocol error."""
    try:
        head = rfile.read(2)
        if len(head) < 2:
            return None
        b0, b1 = head[0], head[1]
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        length = b1 & 0x7F
        if length == 126:
            ext = rfile.read(2)
            if len(ext) < 2:
                return None
            length = struct.unpack(">H", ext)[0]
        elif length == 127:
            ext = rfile.read(8)
            if len(ext) < 8:
                return None
            length = struct.unpack(">Q", ext)[0]
        mask = b""
        if masked:
            mask = rfile.read(4)
            if len(mask) < 4:
                return None
        payload = rfile.read(length) if length else b""
        if len(payload) < length:
            return None
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return opcode, payload
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------
# HTTP server wiring both transports
# ---------------------------------------------------------------------------


class DaemonHTTPRequestHandler(http.server.BaseHTTPRequestHandler):
    """Handles GET /ws (upgrade) and POST /rpc (fallback)."""

    server_version = "smalt-daemon/0.1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        pass  # loopback bridge; silent by default

    # -- WebSocket ----------------------------------------------------------

    def do_GET(self) -> None:
        if self.path.split("?")[0] != WS_PATH:
            self._plain(404, {"error": "not found"})
            return
        key = self.headers.get("Sec-WebSocket-Key")
        upgrade = (self.headers.get("Upgrade") or "").lower()
        if not key or upgrade != "websocket":
            self._plain(400, {"error": "expected WebSocket upgrade"})
            return
        accept = ws_accept_key(key)
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.connection.settimeout(30)
        conn = _WsConnection(self.rfile, self.wfile)
        table = self.server.method_table  # type: ignore attr-defined
        while True:
            message = conn.recv_message()
            if message is None:
                return
            response = json_rpc_dispatch(table, message)
            conn.send_text(json.dumps(response, sort_keys=True))

    # -- HTTP JSON-RPC fallback ----------------------------------------------

    def do_POST(self) -> None:
        if self.path.split("?")[0] != RPC_PATH:
            self._plain(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        body = self.rfile.read(length).decode("utf-8", errors="replace") if length else ""
        response = json_rpc_dispatch(self.server.method_table, body)  # type: ignore attr-defined
        self._plain(200, response)

    def _plain(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class DaemonServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Loopback-bound HTTP server carrying the daemon method table."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: Tuple[str, int] = (HOST, PORT),
        source: Optional[TelemetrySource] = None,
        ledger_path: Optional[str] = None,
    ) -> None:
        super().__init__(address, DaemonHTTPRequestHandler)
        self.method_table = build_method_table(
            source if source is not None else load_source(),
            ledger_path if ledger_path is not None else os.environ.get("SMALT_LEDGER_FILE"),
        )


def serve(
    host: str = HOST,
    port: int = PORT,
    source: Optional[TelemetrySource] = None,
    ledger_path: Optional[str] = None,
) -> DaemonServer:
    """Construct (not run) the daemon server for the given bind address."""
    return DaemonServer((host, port), source=source, ledger_path=ledger_path)


def main(argv: Optional[List[str]] = None) -> int:
    """Entry point: ``python -m smalt_cli.daemon``."""
    host = os.environ.get("SMALT_DAEMON_HOST", HOST)
    port = int(os.environ.get("SMALT_DAEMON_PORT", str(PORT)))
    if host != HOST:
        # Egress guard: this bridge is loopback-only by contract.
        print("smalt-daemon: refusing non-loopback bind %s" % host, file=sys.stderr)
        return 2
    httpd = serve(host, port)
    print("smalt-daemon: ws://127.0.0.1:%d%s rpc:http://127.0.0.1:%d%s" % (port, WS_PATH, port, RPC_PATH))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())

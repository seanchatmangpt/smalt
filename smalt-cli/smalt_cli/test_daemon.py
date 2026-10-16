"""Daemon bridge tests: JSON-RPC dispatch units + real HTTP and WS round trips.

Chicago-style: the HTTP/WS tests run the real server on a loopback port with
real sockets; the telemetry seam uses a real temp JSONL file, not a mock.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

import pytest

from smalt_cli.daemon import server as daemon_server
from smalt_cli.daemon.server import (
    HOST,
    JsonRpcError,
    build_method_table,
    deterministic_tree,
    json_rpc_dispatch,
    ledger_tail_read,
    serve,
    ws_accept_key,
    ws_decode_frame,
    ws_encode_text,
)
from smalt_cli.daemon.source import (
    DeterministicTelemetrySource,
    FileTailTelemetrySource,
    load_source,
)


# ---------------------------------------------------------------------------
# JSON-RPC dispatch units
# ---------------------------------------------------------------------------


class TestJsonRpcDispatch:
    def test_ok_roundtrip(self):
        table = {"ping": lambda p: {"pong": True}}

        resp = json_rpc_dispatch(table, '{"jsonrpc":"2.0","id":7,"method":"ping"}')

        assert resp == {"jsonrpc": "2.0", "id": 7, "result": {"pong": True}}

    def test_parse_error(self):
        resp = json_rpc_dispatch({}, "not json{")
        assert resp["error"]["code"] == -32700
        assert resp["id"] is None

    def test_invalid_request(self):
        resp = json_rpc_dispatch({}, '{"jsonrpc":"1.0","method":"x"}')
        assert resp["error"]["code"] == -32600

    def test_method_not_found(self):
        resp = json_rpc_dispatch({}, '{"jsonrpc":"2.0","id":1,"method":"nope"}')
        assert resp["error"]["code"] == -32601
        assert resp["id"] == 1

    def test_non_dict_params_rejected(self):
        table = {"m": lambda p: p}
        resp = json_rpc_dispatch(table, '{"jsonrpc":"2.0","id":1,"method":"m","params":[1,2]}')
        assert resp["error"]["code"] == -32602

    def test_invalid_params_via_typed_error(self):
        table = build_method_table(DeterministicTelemetrySource())

        resp = json_rpc_dispatch(table, '{"jsonrpc":"2.0","id":2,"method":"node.telemetry","params":{}}')

        assert resp["error"]["code"] == -32602
        assert "id" in resp["error"]["message"]

    def test_internal_error_is_total_no_traceback_leak(self):
        def boom(params):
            raise RuntimeError("secret stack detail")

        resp = json_rpc_dispatch({"m": boom}, '{"jsonrpc":"2.0","id":3,"method":"m"}')
        assert resp["error"]["code"] == -32603
        assert "RuntimeError" not in json.dumps(resp)

    def test_totality_fuzz(self):
        table = build_method_table(DeterministicTelemetrySource())
        garbage = [None, "", "{", "[]", "3", '"s"', '{"jsonrpc":"2.0"}',
                   '{"jsonrpc":"2.0","method":42}', '{"jsonrpc":"2.0","id":1,"method":"x"}']
        for raw in garbage:
            resp = json_rpc_dispatch(table, raw)
            assert "result" in resp or "error" in resp


# ---------------------------------------------------------------------------
# Method payloads
# ---------------------------------------------------------------------------


class TestTreeSnapshot:
    def test_navnode_shape(self):
        tree = deterministic_tree()

        assert tree, "tree must be non-empty"
        roots = tree

        def walk(node):
            assert set(node) >= {"id", "label", "kind", "expandable"}
            assert node["kind"] in ("constellation", "squadron", "vehicle", "payload")
            assert isinstance(node["expandable"], bool)
            for child in node.get("children", []):
                walk(child)

        for root in roots:
            walk(root)

    def test_determinism(self):
        assert json.dumps(deterministic_tree(), sort_keys=True) == json.dumps(
            deterministic_tree(), sort_keys=True
        )

    def test_kind_ladder(self):
        tree = deterministic_tree()
        kinds = set()

        def walk(node):
            kinds.add(node["kind"])
            for child in node.get("children", []):
                walk(child)

        for root in tree:
            walk(root)
        assert kinds == {"constellation", "squadron", "vehicle", "payload"}


class TestNodeTelemetry:
    def test_deterministic_source_stable(self):
        src = DeterministicTelemetrySource()
        assert src.telemetry("node-1") == src.telemetry("node-1")
        t = src.telemetry("node-1")
        assert t["status"] == "ok"
        assert t["id"] == "node-1"
        assert set(t["metrics"]) == {"cpu", "mem", "temp", "volt"}

    def test_file_tail_last_event_wins(self, tmp_path):
        f = tmp_path / "events.jsonl"
        f.write_text(
            '{"id":"v1","temp":10}\n{"id":"v2","temp":99}\n{"id":"v1","temp":42}\n',
            encoding="utf-8",
        )
        src = FileTailTelemetrySource(str(f))

        assert src.telemetry("v1")["temp"] == 42
        assert src.telemetry("v2")["temp"] == 99

    def test_file_tail_missing_file_no_data(self, tmp_path):
        src = FileTailTelemetrySource(str(tmp_path / "absent.jsonl"))
        t = src.telemetry("v1")
        assert t["status"] == "no_data"

    def test_file_tail_malformed_lines_skipped(self, tmp_path):
        f = tmp_path / "events.jsonl"
        f.write_text('{"id":"v1","temp":1}\nCORRUPT LINE\n{"id":"v1","temp":5}\n', encoding="utf-8")
        src = FileTailTelemetrySource(str(f))
        assert src.telemetry("v1")["temp"] == 5

    def test_load_source_env_selects_file(self, tmp_path):
        f = tmp_path / "events.jsonl"
        f.write_text('{"id":"a","ok":true}\n', encoding="utf-8")

        src = load_source({"SMALT_TELEMETRY_FILE": str(f)})
        assert isinstance(src, FileTailTelemetrySource)
        src2 = load_source({})
        assert isinstance(src2, DeterministicTelemetrySource)


class TestLedgerTail:
    def test_tail_and_hash(self, tmp_path):
        p = tmp_path / "audit.jsonl"
        recs = []
        prev = "GENESIS"
        for i in range(5):
            rec = {"ts": "t%d" % i, "op": "op%d" % i, "actor": "a",
                   "params_digest": "d%d" % i, "prev_hash": prev}
            rec["hash"] = hashlib.sha256(
                (prev + json.dumps(rec, sort_keys=True, separators=(",", ":"))).encode()
            ).hexdigest()
            recs.append(rec)
            prev = rec["hash"]
        p.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in recs), encoding="utf-8")

        out = ledger_tail_read(str(p), 2)

        assert out["count"] == 2
        assert out["total"] == 5
        assert out["tailHash"] == recs[-1]["hash"]
        assert out["records"] == recs[-2:]
        assert out["intact"] is True

    def test_missing_file_is_empty_genesis(self, tmp_path):
        out = ledger_tail_read(str(tmp_path / "none.jsonl"), 10)
        assert out == {
            "records": [], "tailHash": "GENESIS", "count": 0,
            "total": 0, "malformedLines": 0, "intact": True,
        }

    def test_malformed_line_reported_not_fatal(self, tmp_path):
        p = tmp_path / "audit.jsonl"
        p.write_text('{"hash":"h1"}\nGARBAGE\n', encoding="utf-8")
        out = ledger_tail_read(str(p), 10)
        assert out["malformedLines"] == 1
        assert out["intact"] is False
        assert out["tailHash"] == "h1"

    def test_n_bounds_enforced(self):
        table = build_method_table(DeterministicTelemetrySource())
        for bad in (0, -1, True, "5", 10_001):
            resp = json_rpc_dispatch(
                table,
                json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ledger.tail", "params": {"n": bad}}),
            )
            assert resp["error"]["code"] == -32602, bad


# ---------------------------------------------------------------------------
# RFC6455 codec units
# ---------------------------------------------------------------------------


class TestWsCodec:
    def test_accept_key_rfc_example(self):
        assert ws_accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    def test_text_frame_roundtrip_unmasked(self):
        frame = ws_encode_text("hello")
        (op, payload), consumed = ws_decode_frame(frame)
        assert op == 0x1
        assert payload == b"hello"
        assert consumed == len(frame)

    def test_masked_client_frame_roundtrip(self):
        payload = b'{"jsonrpc":"2.0"}'
        mask = b"\x11\x22\x33\x44"
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        frame = bytes([0x81, 0x80 | len(payload)]) + mask + masked
        (op, decoded), _ = ws_decode_frame(frame)
        assert (op, decoded) == (0x1, payload)

    def test_extended_16bit_length(self):
        payload = b"x" * 300
        frame = ws_encode_text(payload.decode())
        (op, decoded), _ = ws_decode_frame(frame)
        assert op == 0x1 and decoded == payload

    def test_incomplete_frame_returns_none(self):
        assert ws_decode_frame(ws_encode_text("hello")[:-1]) == (None, 0)
        assert ws_decode_frame(b"\x81") == (None, 0)


# ---------------------------------------------------------------------------
# Real transport round trips (loopback sockets, real server)
# ---------------------------------------------------------------------------


@pytest.fixture()
def daemon(tmp_path):
    ledger = tmp_path / "audit.jsonl"
    ledger.write_text('{"hash":"abc123","op":"demo"}\n', encoding="utf-8")
    httpd = serve(port=0, ledger_path=str(ledger))
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield "http://127.0.0.1:%d" % httpd.server_address[1], httpd
    httpd.shutdown()
    httpd.server_close()


class TestHttpRoundtrip:
    def test_post_rpc_tree_snapshot(self, daemon):
        base, _ = daemon
        req = urllib.request.Request(
            base + "/rpc",
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tree.snapshot"}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            assert resp.status == 200
            body = json.loads(resp.read())

        assert body["id"] == 1
        roots = body["result"]["roots"]
        assert roots and roots[0]["kind"] in ("constellation", "squadron")
        assert all("label" in r for r in roots)

    def test_post_rpc_hw_status(self, daemon):
        base, _ = daemon
        req = urllib.request.Request(
            base + "/rpc",
            data=json.dumps({"jsonrpc": "2.0", "id": 2, "method": "hw.status"}).encode(),
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read())
        assert body["result"]["serial"]["status"] in ("READY", "UNSUPPORTED")

    def test_post_rpc_ledger_tail(self, daemon):
        base, _ = daemon
        req = urllib.request.Request(
            base + "/rpc",
            data=json.dumps({"jsonrpc": "2.0", "id": 3, "method": "ledger.tail", "params": {"n": 5}}).encode(),
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read())
        assert body["result"]["tailHash"] == "abc123"


class TestWsHandshakeAndRoundtrip:
    def test_handshake_and_text_roundtrip(self, daemon):
        base, _ = daemon
        host, port = urllib.parse.urlparse(base).hostname, urllib.parse.urlparse(base).port
        sock = socket.create_connection((host, port), timeout=5)
        try:
            key = base64.b64encode(os.urandom(16)).decode()
            request = (
                "GET /ws HTTP/1.1\r\n"
                "Host: 127.0.0.1:%d\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Key: %s\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n" % (port, key)
            )
            sock.sendall(request.encode())
            response = b""
            while b"\r\n\r\n" not in response:
                response += sock.recv(4096)
            head, _, rest = response.partition(b"\r\n\r\n")
            head_text = head.decode()
            assert "101" in head_text.split("\r\n")[0]
            expected = ws_accept_key(key)
            assert ("Sec-WebSocket-Accept: " + expected) in head_text

            buffered = [rest]

            def send_msg(text):
                frame = ws_encode_text(text)
                # client frames must be masked
                mask = b"\xaa\xbb\xcc\xdd"
                payload = frame[2:]
                masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                client_frame = bytes([frame[0], frame[1] | 0x80]) + mask + masked
                sock.sendall(client_frame)

            def recv_msg():
                buf = bytearray(buffered[0])
                buffered[0] = b""
                while True:
                    decoded, consumed = daemon_server.ws_decode_frame(bytes(buf))
                    op, payload = decoded if decoded is not None else (None, b"")
                    if op is None:
                        chunk = sock.recv(4096)
                        if not chunk:
                            return None
                        buf += chunk
                        continue
                    del buf[:consumed]
                    buffered[0] = bytes(buf)
                    if op == 0x1:
                        return payload.decode()
                    if op == 0x8:
                        return None
                    # ping/pong/other: keep reading

            send_msg(json.dumps({"jsonrpc": "2.0", "id": 9, "method": "tree.snapshot"}))
            reply = json.loads(recv_msg())
            assert reply["id"] == 9
            assert reply["result"]["roots"]

            send_msg(json.dumps({"jsonrpc": "2.0", "id": 10, "method": "node.telemetry", "params": {"id": "v1"}}))
            reply2 = json.loads(recv_msg())
            assert reply2["result"]["id"] == "v1"
        finally:
            sock.close()

    def test_get_wrong_path_404(self, daemon):
        base, _ = daemon
        try:
            with urllib.request.urlopen(base + "/nope", timeout=5) as resp:
                code = resp.status
        except urllib.error.HTTPError as e:
            code = e.code
        assert code == 404

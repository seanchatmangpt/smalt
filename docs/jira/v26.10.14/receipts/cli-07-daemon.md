# CLI-7 Receipt — smalt-cli Daemon Bridge

- **Date**: 2026-10-15
- **Lane**: CLI-7
- **Subject**: `/Users/sac/smalt/smalt-cli/smalt_cli/daemon/` (exact files below)
- **Base**: smalt main @ 3fc2543 (session start)

## Files (all absolute, all session-created)

- `/Users/sac/smalt/smalt-cli/smalt_cli/daemon/__init__.py` — package doc = bridge contract.
- `/Users/sac/smalt/smalt-cli/smalt_cli/daemon/server.py` — RFC6455 WS (`GET /ws`) + HTTP
  POST `/rpc` fallback, JSON-RPC 2.0 dispatch, method table, loopback bind guard.
- `/Users/sac/smalt/smalt-cli/smalt_cli/daemon/source.py` — telemetry seam:
  `TelemetrySource` protocol, `DeterministicTelemetrySource` (pure function of id),
  `FileTailTelemetrySource` (JSONL tail via `SMALT_TELEMETRY_FILE`), `load_source`.
- `/Users/sac/smalt/smalt-cli/smalt_cli/daemon/__main__.py` — `python -m smalt_cli.daemon`.
- `/Users/sac/smalt/smalt-cli/smalt_cli/test_daemon.py` — 30 tests.

## Bridge contract

- **Bind**: `127.0.0.1:18742` only. `main()` refuses non-loopback `SMALT_DAEMON_HOST`
  (exit 2). No egress beyond loopback; all methods are read-only over local state.
- **Transports** (one dispatch, two carriers):
  - `GET /ws` RFC6455: handshake (`Sec-WebSocket-Accept = base64(sha1(key + GUID))`,
    verified against the RFC example vector), masked client text frames, ping→pong,
    close handling. One JSON-RPC request per text frame, one response frame back.
  - `POST /rpc`: identical JSON-RPC body in / body out, one request per POST.
- **JSON-RPC 2.0 methods**:
  - `tree.snapshot` → `{"roots": [NavNode...]}` — NavNode-compatible with
    `workspace/lib/navigator/tree-model.ts`: `{id, label, kind, expandable,
    declaredChildCount?, children?}`; kinds constellation→squadron→vehicle→payload
    (constellation-0 → 2 squadrons → 3 vehicles each → 2 payloads each).
  - `node.telemetry {id}` → `{source, id, status, seq?, metrics?}`. Source seam:
    `SMALT_TELEMETRY_FILE` (JSONL, last event per id wins, malformed lines skipped,
    missing file → `status:"no_data"`) else deterministic generator (pure function of
    the id — stable across restarts).
  - `ledger.tail {n}` → `{records, tailHash, count, total, malformedLines, intact}`;
    ledger path from `SMALT_LEDGER_FILE`; missing file = empty ledger, tailHash
    `"GENESIS"`; shape mirrors `smalt_cli/ledger.py`. `n` bounds-checked [1,10000].
  - `hw.status` → `{serial: {status, backend, ...}, telemetrySource, uptime_s}`;
    serial backend probed (pyserial import); degrades to
    `{"status":"UNSUPPORTED"}` without it, never throws.
- **Totality**: dispatcher is total over all input strings — `-32700 / -32600 / -32601 /
  -32602 / -32603` all typed, no traceback leakage (fuzz-tested).
- **Stdlib only**; no new dependencies.

## Verification (executed this session)

1. Unit + transport tests: `python3 -m pytest smalt_cli/test_daemon.py -q`
   → `30 passed in 2.65s`.
2. Full package regression: `python3 -m pytest smalt_cli -q` → `101 passed in 8.69s`
   (30 daemon + 71 pre-existing policy tests; zero failures, zero pre-existing
   failures introduced).
3. Live entrypoint smoke on the contract port:
   `python3 -m smalt_cli.daemon` → binds 127.0.0.1:18742;
   `curl -X POST http://127.0.0.1:18742/rpc -d '{"jsonrpc":"2.0","id":1,"method":"tree.snapshot"}'`
   → `{"id": 1, "jsonrpc": "2.0", "result": {"roots": [...]}}` with full
   constellation→payload hierarchy;
   `hw.status` → `{"serial": {"backend": "none", ..., "status": "UNSUPPORTED"}, ...}`.

## Standing

ALIVE for the bridge contract: both transports, all four methods, totality paths, WS
handshake against the RFC vector, and live 18742 smoke — all executed this session.
UNVERIFIED: the workspace Next.js consumer rendering `tree.snapshot` in the actual
Navigator component (consumer-side integration is ws-02/ws-06's surface; payload shape
was built and asserted against `tree-model.ts` field names).

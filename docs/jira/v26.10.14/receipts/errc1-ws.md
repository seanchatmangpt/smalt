# ERRC Lane 1 (Eliminate) — Daemon WebSocket: Bandit vs hand-rolled

Verdict: **KEEP** (option b, with evidence)

Subject: `smalt-cli/smalt_cli/daemon/server.py` (512 lines, stdlib-only, loopback-only).

## Evaluated

Option (a) — Bandit WebSocket endpoint in `lib/smalt/`:
- Bandit 1.12.5 is already in `mix.exs` (`{:bandit, "~> 1.6"}`), with `websock_adapter` in
  the lock — the Elixir side is ready.
- But the behavior pins are Python-side: `smalt_cli/test_daemon.py`'s 30 tests pin the
  JSON-RPC dispatch, the method payloads, and the codec units directly
  (`ws_accept_key` RFC 7692 example, masking, 16-bit extended lengths, incomplete-frame
  totality). Those codec unit tests cannot port — the codec is what gets deleted.
- Reuse-by-HTTP (Elixir WS -> proxy to Python `/rpc`) keeps the Python HTTP server
  running anyway; net deletion is only the ~150-line codec, against ~100+ lines of new
  Elixir plug + proxy, a second always-running process, and a cross-process hop for
  every CLI frame.
- Porting the dispatch table to Elixir duplicates a 30-test-pinned contract — N
  implementations of one JSON-RPC contract -> O(N^2) drift (dfcm-composition law).
- The loopback-only egress guard (`main` refuses non-127.0.0.1 bind) lives in the
  Python entry point; a Bandit endpoint moves the listener into a different substrate
  process without preserving that guard's placement.

Option (b) — keep with evidence:
- The codec is 150 lines of the 512; the remainder (dispatch, payloads, ledger read,
  telemetry seam) is the real capital and is transport-agnostic and fully test-pinned.
- stdlib-only, zero deps, zero new attack surface beyond loopback.
- The "real library" already serves this path: Python's `http.server` is the library;
  Bandit would be an added moving part, not a removed dependency.

## Witness (live WS round trip, real socket, 2026-10-15)

Real `DaemonServer` on an ephemeral loopback port, real TCP socket, masked client
frames, RFC6455 handshake:

```
HANDSHAKE: HTTP/1.1 101 Switching Protocols | accept ok: True
tree.snapshot id=1 roots=1 first_kind=constellation
ledger.tail tailHash=witness-abc intact=True
node.telemetry id=v1 status=ok
```

## Test receipts

- smalt-cli full Python suite: **101 passed** (`pytest -q`, 8.58s) — includes
  test_daemon.py's 30 daemon tests, all green pre- and post-evaluation.
- Elixir `mix test`: 1 doctest, 1910 tests, 21 failures — **pre-existing**, session
  introduced zero edits to the Elixir tree (only write this session is this receipt).
  Failure classes: ErrorCodes doc projection, CbsRouter token-type 400,
  StoreDets restore replay, EgressDispatch KD-15/SKR header classes.

## LOC accounting

Deleted 0 / added 0 production lines; deleted 0 / added 1 receipt doc.

## Falsifier

A replacement that passes all 30 test_daemon.py tests unchanged, serves
`tree.snapshot` over a live WS socket, and nets negative LOC (deleted > added) would
overturn this verdict.

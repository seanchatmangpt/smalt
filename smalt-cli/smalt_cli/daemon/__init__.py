"""smalt-cli daemon bridge — localhost-only JSON-RPC 2.0 server (stdlib only).

Serves ``127.0.0.1:18742`` with:

- a minimal RFC6455 WebSocket endpoint (``/ws``): handshake, text-frame
  encode/decode, ping/pong/close handling;
- an HTTP POST fallback (``/rpc``) carrying the identical JSON-RPC dispatch.

No egress beyond 127.0.0.1: the listener binds the loopback interface
explicitly and every method is read-only over local state.

JSON-RPC 2.0 methods
--------------------
``tree.snapshot``
    Node hierarchy for the Navigator. Payload is ``NavNode``-compatible:
    ``{id, label, kind, expandable, declaredChildCount, children?}`` — the
    same field names as ``workspace/lib/navigator/tree-model.ts`` (``label``
    is the tree-model field name; ``expandable`` matches ``isExpandable``).

``node.telemetry {id}``
    Telemetry for one node id, from a pluggable source
    (:mod:`smalt_cli.daemon.source`).

``ledger.tail {n}``
    Last ``n`` records of the append-only audit ledger plus ``tailHash``
    (sha256 chain head, ``"GENESIS"`` when empty) and an ``intact`` flag.

``hw.status``
    Hardware/serial gateway status envelope.

See ``smalt_cli/test_daemon.py`` for the verification ladder.
"""

from __future__ import annotations

__all__ = ["server", "source"]

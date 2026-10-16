"""Telemetry source seam for the smalt-cli daemon.

A source answers one question: "what is the telemetry for node ``id``?"
The daemon server has no opinion about *where* telemetry comes from; it
holds a source behind the :class:`TelemetrySource` seam so tests and the
workspace can substitute real emulators, the OCEL event stream, or fixtures.

Sources (selected by env, in priority order):

- ``SMALT_TELEMETRY_FILE``: JSONL events file, one event per line, shape
  ``{"id": <node id>, ...}``.  File-tailed: only the last event matching the
  id wins.  A missing file degrades to ``{"source": "file", "status":
  "no_data"}`` per unknown id (never raises).
- default: :class:`DeterministicTelemetrySource` — pure function of the id
  (stable across restarts, no clock, no randomness).

Stdlib only.
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any, Dict, Optional, Protocol

TELEMETRY_FILE_ENV = "SMALT_TELEMETRY_FILE"

__all__ = [
    "TELEMETRY_FILE_ENV",
    "TelemetrySource",
    "DeterministicTelemetrySource",
    "FileTailTelemetrySource",
    "load_source",
]


class TelemetrySource(Protocol):
    """Structural seam: anything with ``telemetry(id) -> dict``."""

    def telemetry(self, node_id: str) -> Dict[str, Any]:
        ...  # pragma: no cover


class DeterministicTelemetrySource:
    """Pure-function telemetry: stable given the same node id.

    Values derive from the sha256 of the id — no clock, no randomness — so
    two calls with the same id return equal payloads (property asserted in
    ``test_daemon.py``).
    """

    name = "deterministic"

    def telemetry(self, node_id: str) -> Dict[str, Any]:
        digest = hashlib.sha256(node_id.encode("utf-8")).hexdigest()
        return {
            "source": self.name,
            "id": node_id,
            "status": "ok",
            "seq": int(digest[:8], 16),
            "metrics": {
                "cpu": round(int(digest[8:16], 16) % 10_000 / 100, 2),
                "mem": round(int(digest[16:24], 16) % 65_536 / 100, 2),
                "temp": round(20 + int(digest[24:32], 16) % 6_000 / 100, 2),
                "volt": round(3.0 + int(digest[32:40], 16) % 100 / 100, 2),
            },
        }

    def __eq__(self, other: object) -> bool:
        return type(other) is DeterministicTelemetrySource


class FileTailTelemetrySource:
    """Tail a JSONL events file; last matching event for an id wins.

    Malformed lines are skipped (tolerant tail — a partial writer line must
    not take down the bridge).  The file is re-read per query; telemetry
    files at the intended scale (tail N of an audit/event stream) are small
    enough for this and it keeps the source stateless.
    """

    name = "file"

    def __init__(self, path: str) -> None:
        self.path = path

    def telemetry(self, node_id: str) -> Dict[str, Any]:
        match: Optional[Dict[str, Any]] = None
        try:
            with open(self.path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(event, dict) and event.get("id") == node_id:
                        match = event
        except FileNotFoundError:
            pass
        if match is None:
            return {
                "source": self.name,
                "id": node_id,
                "status": "no_data",
            }
        out = dict(match)
        out.setdefault("source", self.name)
        out.setdefault("status", "ok")
        return out

    def __eq__(self, other: object) -> bool:
        return type(other) is FileTailTelemetrySource and self.path == other.path


def load_source(env: Optional[Dict[str, str]] = None) -> TelemetrySource:
    """Build the telemetry source from the environment (default ``os.environ``)."""
    environ = os.environ if env is None else env
    path = environ.get(TELEMETRY_FILE_ENV)
    if path:
        return FileTailTelemetrySource(path)
    return DeterministicTelemetrySource()

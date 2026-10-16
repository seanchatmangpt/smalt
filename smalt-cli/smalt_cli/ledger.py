"""NIST AU-10 append-only audit ledger (smalt-cli).

Immutable JSONL manifest with a rolling SHA-256 block hash chain.

Record shape (one JSON object per line, keys sorted, fixed separators):

    {"actor": ..., "hash": ..., "op": ..., "params_digest": ...,
     "prev_hash": ..., "ts": ...}

- ``params_digest`` = sha256 of the canonical JSON of the op params.
- ``prev_hash``     = GENESIS for the first record, else the previous record's
  ``hash``.
- ``hash``          = sha256(prev_hash + canonical(record-without-hash)).

Determinism (NFR-PY-05): same record sequence -> byte-identical file.
Canonical JSON is ``json.dumps(..., sort_keys=True, separators=(",", ":"))``
encoded UTF-8.

Totality: :func:`verify_manifest` never raises on malformed input; a bad line
becomes a typed ``{"intact": false, "reason": ...}`` result.

Stdlib only.
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any, Dict, Optional

GENESIS = "GENESIS"
MANIFEST_FILENAME = "audit_manifest.jsonl"

__all__ = [
    "GENESIS",
    "MANIFEST_FILENAME",
    "canonical_json",
    "params_digest",
    "compute_record_hash",
    "build_record",
    "append_record",
    "verify_manifest",
]


def canonical_json(obj: Any) -> str:
    """Deterministic JSON encoding: sorted keys, fixed separators."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def params_digest(params: Any) -> str:
    """sha256 of the canonical JSON of ``params``."""
    return _sha256_hex(canonical_json(params))


def compute_record_hash(prev_hash: str, record_no_hash: Dict[str, Any]) -> str:
    """Rolling block hash: sha256(prev_hash + canonical(record-without-hash))."""
    return _sha256_hex(prev_hash + canonical_json(record_no_hash))


def build_record(op: str, actor: str, params: Any, ts: str, prev_hash: str) -> Dict[str, Any]:
    """Build a complete ledger record (including ``hash``)."""
    record: Dict[str, Any] = {
        "ts": ts,
        "op": op,
        "actor": actor,
        "params_digest": params_digest(params),
        "prev_hash": prev_hash,
    }
    record["hash"] = compute_record_hash(prev_hash, record)
    return record


def append_record(path: str, op: str, actor: str, params: Any, ts: str) -> Dict[str, Any]:
    """Append one record to the JSONL manifest; returns the written record.

    Atomic-ish: line-buffered open in append mode, single write, explicit
    flush + fsync so a completed append is fully on disk.
    """
    prev_hash = _last_hash(path)
    record = build_record(op, actor, params, ts, prev_hash)
    line = canonical_json(record) + "\n"
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(line)
        fh.flush()
        os.fsync(fh.fileno())
    return record


def _last_hash(path: str) -> str:
    """Hash of the last well-formed record, or GENESIS for an empty/absent manifest."""
    if not os.path.exists(path):
        return GENESIS
    last = GENESIS
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                if isinstance(obj, dict) and isinstance(obj.get("hash"), str):
                    last = obj["hash"]
    except OSError:
        return GENESIS
    return last


def verify_manifest(path: str) -> Dict[str, Any]:
    """Full-chain recomputation. Total: malformed input yields typed results.

    Returns::

        {"intact": bool, "count": int, "first_break": Optional[int],
         "reason": Optional[str]}

    ``first_break`` is the 0-based line index of the first violation
    (bad hash, chain break, or malformed line); ``None`` when intact.
    A malformed line also carries a ``"line"`` field with the raw text.
    Missing file: ``{"intact": false, "reason": "missing_manifest",
    "count": 0, "first_break": None}``.
    """
    if not os.path.exists(path):
        return {"intact": False, "count": 0, "first_break": None,
                "reason": "missing_manifest"}

    prev_hash = GENESIS
    count = 0
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line_no = count
            line = raw.strip()
            if not line:
                # Tolerate blank separators but do not count them as records.
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError) as exc:
                return {"intact": False, "count": count, "first_break": line_no,
                        "reason": f"malformed_json: {exc}", "line": line}
            if not isinstance(obj, dict):
                return {"intact": False, "count": count, "first_break": line_no,
                        "reason": "record_not_object", "line": line}
            for field in ("ts", "op", "actor", "params_digest", "prev_hash", "hash"):
                if field not in obj:
                    return {"intact": False, "count": count, "first_break": line_no,
                            "reason": f"missing_field: {field}", "line": line}
            if obj["prev_hash"] != prev_hash:
                return {"intact": False, "count": count, "first_break": line_no,
                        "reason": "chain_break", "line": line}
            no_hash = {k: v for k, v in obj.items() if k != "hash"}
            expected = compute_record_hash(prev_hash, no_hash)
            if obj["hash"] != expected:
                return {"intact": False, "count": count, "first_break": line_no,
                        "reason": "hash_mismatch", "line": line}
            prev_hash = obj["hash"]
            count += 1
    return {"intact": True, "count": count, "first_break": None, "reason": None}

"""Tests for the NIST AU-10 audit ledger (smalt_cli.ledger). Stdlib + pytest."""

import json
import os

from smalt_cli import ledger


def _append(tmp_path, op, params, ts, actor="tester"):
    return ledger.append_record(
        str(tmp_path / ledger.MANIFEST_FILENAME), op, actor, params, ts
    )


def _read_lines(tmp_path):
    path = tmp_path / ledger.MANIFEST_FILENAME
    with open(path, "r", encoding="utf-8") as fh:
        return [ln for ln in fh.read().splitlines() if ln]


# --- append + verify green -------------------------------------------------


def test_append_and_verify_green(tmp_path):
    _append(tmp_path, "blob.list", {"container": "c", "prefix": ""}, "2026-10-15T00:00:00Z")
    _append(tmp_path, "cosmos.read", {"db": "d", "coll": "x"}, "2026-10-15T00:00:01Z")
    result = ledger.verify_manifest(str(tmp_path / ledger.MANIFEST_FILENAME))
    assert result["intact"] is True
    assert result["count"] == 2
    assert result["first_break"] is None


def test_record_shape(tmp_path):
    rec = _append(tmp_path, "op.a", {"k": 1}, "t0")
    assert set(rec) == {"ts", "op", "actor", "params_digest", "prev_hash", "hash"}
    assert rec["prev_hash"] == ledger.GENESIS
    assert rec["params_digest"] == ledger.params_digest({"k": 1})
    assert len(rec["hash"]) == 64
    second = _append(tmp_path, "op.b", {"k": 2}, "t1")
    assert second["prev_hash"] == rec["hash"]


# --- tamper detection ------------------------------------------------------


def test_tamper_one_byte_detected_at_exact_line(tmp_path):
    _append(tmp_path, "op.a", {"k": 1}, "t0")
    _append(tmp_path, "op.b", {"k": 2}, "t1")
    _append(tmp_path, "op.c", {"k": 3}, "t2")
    path = tmp_path / ledger.MANIFEST_FILENAME
    lines = _read_lines(tmp_path)

    # Flip one byte in the middle record (op name "op.b" -> "op.X").
    tampered = lines[1].replace('"op.b"', '"op.X"')
    assert tampered != lines[1]
    lines[1] = tampered
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    result = ledger.verify_manifest(str(path))
    assert result["intact"] is False
    assert result["first_break"] == 1
    assert result["reason"] == "hash_mismatch"
    assert result["line"] == tampered


# --- empty / GENESIS handling ----------------------------------------------


def test_empty_manifest_genesis(tmp_path):
    path = tmp_path / ledger.MANIFEST_FILENAME
    path.write_text("", encoding="utf-8")
    result = ledger.verify_manifest(str(path))
    assert result == {"intact": True, "count": 0, "first_break": None, "reason": None}


def test_missing_manifest_typed_failure(tmp_path):
    result = ledger.verify_manifest(str(tmp_path / "nope.jsonl"))
    assert result["intact"] is False
    assert result["reason"] == "missing_manifest"
    assert result["count"] == 0


# --- totality: malformed lines never raise ---------------------------------


def test_malformed_line_is_typed_not_exception(tmp_path):
    _append(tmp_path, "op.a", {"k": 1}, "t0")
    path = tmp_path / ledger.MANIFEST_FILENAME
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("{not json at all\n")
    result = ledger.verify_manifest(str(path))
    assert result["intact"] is False
    assert result["first_break"] == 1
    assert result["reason"].startswith("malformed_json")


def test_chain_break_detected(tmp_path):
    _append(tmp_path, "op.a", {"k": 1}, "t0")
    _append(tmp_path, "op.b", {"k": 2}, "t1")
    lines = _read_lines(tmp_path)
    recs = [json.loads(ln) for ln in lines]
    # Drop the first record: second's prev_hash no longer matches GENESIS.
    path = tmp_path / ledger.MANIFEST_FILENAME
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(lines[1] + "\n")
    result = ledger.verify_manifest(str(path))
    assert result["intact"] is False
    assert result["first_break"] == 0
    assert result["reason"] == "chain_break"
    assert recs[1]["prev_hash"] != ledger.GENESIS


# --- determinism (NFR-PY-05) ------------------------------------------------


def test_determinism_two_runs_byte_identical(tmp_path):
    entries = [
        ("blob.list", {"container": "c", "prefix": "p/", "limit": 10}, "2026-10-15T00:00:00Z"),
        ("cosmos.read", {"db": "d", "coll": "x", "id": "i1"}, "2026-10-15T00:00:01Z"),
        ("auth.issue", {"scope": "read", "ttl": 60}, "2026-10-15T00:00:02Z"),
    ]
    outs = []
    for run in (0, 1):
        d = tmp_path / f"run{run}"
        d.mkdir()
        for op, params, ts in entries:
            ledger.append_record(str(d / ledger.MANIFEST_FILENAME), op, "tester", params, ts)
        outs.append((d / ledger.MANIFEST_FILENAME).read_bytes())
    assert outs[0] == outs[1]
    # And each line is canonical JSON (sorted keys, no spaces).
    for line in outs[0].decode("utf-8").splitlines():
        obj = json.loads(line)
        assert line == json.dumps(obj, sort_keys=True, separators=(",", ":"))


def test_params_digest_order_insensitive():
    assert ledger.params_digest({"a": 1, "b": 2}) == ledger.params_digest({"b": 2, "a": 1})

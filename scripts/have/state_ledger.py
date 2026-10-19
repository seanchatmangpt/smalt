#!/usr/bin/env python3
"""HAVE L1 — run_state.jsonl state ledger (component 1).

Atomic-append JSONL ledger + RP-01 step-3 sanitizer + heartbeat file.

State schema (one JSON object per line):
    {"ts": <float epoch>, "kind": "heartbeat|dispatch|receipt|alert",
     "subject": <str>, "detail": <str>}

Paths (gitignored under tmp/have/):
    tmp/have/run_state.jsonl
    tmp/have/have_l1.heartbeat

Zero sleeps. CLI:
    python3 scripts/have/state_ledger.py sanitize   # truncate + report retained count
    python3 scripts/have/state_ledger.py append --kind receipt --subject S --detail D
    python3 scripts/have/state_ledger.py heartbeat  # touch + read
    python3 scripts/have/state_ledger.py read
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from typing import Any, Dict, List, Tuple

LEDGER_PATH = os.path.join("tmp", "have", "run_state.jsonl")
HEARTBEAT_PATH = os.path.join("tmp", "have", "have_l1.heartbeat")

KINDS = ("heartbeat", "dispatch", "receipt", "alert")


def _repo_root() -> str:
    # This file lives at <root>/scripts/have/state_ledger.py.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _path(p: str) -> str:
    if os.path.isabs(p):
        return p
    return os.path.join(_repo_root(), p)


# ---------------------------------------------------------------- schema

def make_entry(kind: str, subject: str, detail: str = "", ts: float | None = None) -> Dict[str, Any]:
    if kind not in KINDS:
        raise ValueError("invalid kind %r; expected one of %s" % (kind, KINDS))
    return {"ts": time.time() if ts is None else ts, "kind": kind,
            "subject": subject, "detail": detail}


# ---------------------------------------------------------------- atomic append

def append_entry(entry: Dict[str, Any], path: str = LEDGER_PATH) -> int:
    """Append one JSON line atomically: write tmp file in same dir + rename.

    Rename is atomic on POSIX, so a crash mid-append can never expose a
    partially written record under the ledger path. Returns byte offset of the
    new line start.
    """
    line = (json.dumps(entry, sort_keys=True) + "\n").encode("utf-8")
    full = _path(path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    offset = os.path.getsize(full) if os.path.exists(full) else 0
    fd, tmp = tempfile.mkstemp(prefix=".state_ledger-", dir=os.path.dirname(full))
    try:
        # Copy existing content, then append the new line, then rename over.
        if offset:
            with open(full, "rb") as src, os.fdopen(fd, "wb") as dst:
                dst.write(src.read())
                dst.write(line)
        else:
            with os.fdopen(fd, "wb") as dst:
                dst.write(line)
        os.replace(tmp, full)  # atomic on POSIX
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return offset


def read_entries(path: str = LEDGER_PATH) -> List[Dict[str, Any]]:
    full = _path(path)
    if not os.path.exists(full):
        appends = []
    else:
        with open(full, "r", encoding="utf-8") as f:
            appends = [json.loads(l) for l in f if l.strip()]
    return appends


# ---------------------------------------------------------------- RP-01 step-3 sanitizer

def sanitize_truncated_lines(path: str = LEDGER_PATH) -> Tuple[int, int]:
    """Truncate trailing half-written JSON lines; report retained count.

    A trailing line is "half-written" if the file does not end with '\n', or if
    any trailing line fails to parse as a complete JSON object. The file is
    rewritten atomically (tmp + rename) with only the retained prefix.

    Returns (retained, dropped).
    """
    full = _path(path)
    if not os.path.exists(full):
        return 0, 0
    with open(full, "rb") as f:
        raw = f.read()
    lines = raw.split(b"\n")
    # A trailing empty element means the file ended with a newline (complete).
    trailing_partial = bool(lines[-1]) if lines else False
    end = len(lines) - 1  # number of newline-terminated lines
    retained = end
    while retained > 0:
        try:
            json.loads(lines[retained - 1].decode("utf-8"))
            break
        except (ValueError, UnicodeDecodeError):
            retained -= 1
    retained_bytes = sum(len(lines[i]) + 1 for i in range(retained))
    dropped = end - retained
    if trailing_partial:
        dropped += 1
    if dropped == 0 and retained == end:
        return retained, 0  # nothing to do; leave file untouched
    fd, tmp = tempfile.mkstemp(prefix=".state_ledger-", dir=os.path.dirname(full))
    try:
        with os.fdopen(fd, "wb") as dst:
            dst.write(raw[:retained_bytes])
        os.replace(tmp, full)
    except BaseException:
        if os.path.exists(truncated_tmp := tmp):
            os.unlink(tmp)
        raise
    return retained, dropped


# ---------------------------------------------------------------- heartbeat

def heartbeat_touch(path: str = HEARTBEAT_PATH) -> float:
    full = _path(path)
    os.makedirs(os.path.dirname(full), same := os.path.dirname(full) or ".") or os.makedirs(os.path.dirname(full), exist_ok=True)
    now = time.time()
    fd, tmp = tempfile.mkstemp(prefix=".have_hb-", dir=os.path.dirname(full))
    with os.fdopen(fd, "w") as f:
        f.write("%.6f\n" % now)
    os.replace(tmp, full)
    return now


def heartbeat_age(path: str = HEARTBEAT_PATH) -> float | None:
    """Seconds since last heartbeat touch; None if never touched."""
    full = _path(path)
    if not os.path.exists(full):
        return None
    with open(full, "r") as f:
        return max(0.0, time.time() - float(f.read().strip()))


# ---------------------------------------------------------------- CLI

def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="HAVE L1 state ledger")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_san = sub.add_parser("sanitize", help="truncate trailing half-written lines; print retained count")
    p_san.add_argument("--path", default=LEDGER_PATH)

    p_app = sub.add_parser("append", help="append one state entry")
    p_app.add_argument("--kind", required=True, choices=KINDS)
    p_app.add_argument("--subject", required=True)
    p_app.add_argument("--detail", default="")
    p_app.add_argument("--path", default=LEDGER_PATH)

    sub.add_parser("heartbeat", help="touch heartbeat and print age")
    sub.add_parser("read", help="print ledger entries as JSON")

    args = ap.parse_args(argv)
    if args.cmd == "sanitize":
        retained, dropped = sanitize_truncated_lines(args.path)
        print("retained=%d dropped=%d" % (retained, dropped))
        return 0
    if args.cmd == "append":
        off = append_entry(make_entry(args.kind, args.subject, args.detail), args.path)
        print("appended at offset %d" % off)
        return 0
    if args.cmd == "heartbeat":
        heartbeat_touch()
        print("heartbeat age=%.3fs" % heartbeat_age())
        return 0
    if args.cmd == "read":
        print(json.dumps(read_entries(), indent=2))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())

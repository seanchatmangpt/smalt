#!/usr/bin/env python3
"""HAVE component 6 — RP-02 deterministic storage recovery probe.

Read-only storage probe over smalt's DETS mirror files. NEVER repairs:
recovery belongs to DetsMirror.restore (lib/smalt/store/dets_mirror.ex).

Modes
-----
--inspect-headers --data-dir DIR
    Read each *.dets file header. Reports per table:
      OK            magic present (00 ab cd ef at offset 4)
      CORRUPT_HEADER  magic missing/wrong or unreadable short file
    (Header inspection is heuristic; --verify-clean-open is authoritative.)

--verify-clean-open --data-dir DIR
    Strict fail-closed open of every mirror file with repair: false via a
    real dets collaborator (escript). Typed verdicts reuse the i24/i25
    probe_rows tuple-shape matcher pattern:
      OK              {:ok, _} from dets:open_file(repair: false)
      NEEDS_REPAIR    {:error, {:needs_repair, _}}          (torn write)
      CORRUPT_HEADER  {:error, {not_a_dets_file, _}}        (bad magic)
      OPEN_ERROR      any other typed error tuple
    Exit 0 iff every table is OK.

--quarantine
    With --verify-clean-open (or --inspect-headers): when any table is
    corrupt, tar the data dir to
    tmp/have/quarantine/corrupt_state_<ts>.tar.gz before exiting nonzero.

--ledger-pointer
    Name the latest verified hash-chained ledger source (RP-02 replay
    pointer): smalt-cli audit_manifest.jsonl, falling back to the
    docs/jira/v26.10.18/receipts/ court receipts.

Exit codes: 0 all-clean, 1 corrupt table found (or probe error), 3 usage.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QUARANTINE_DIR = os.path.join(REPO_ROOT, "tmp", "have", "quarantine")
LEDGER_POINTER = os.path.join("smalt-cli", "audit_manifest.jsonl")

DETS_MAGIC = b"\x00\xab\xcd\xef"

ES = r'''#!/usr/bin/env escript
%% RP-02 storage probe: strict fail-closed dets open (repair: false).
main([DataDir]) ->
    Files = filelib:wildcard(filename:join(DataDir, "*.dets")),
    case Files of
        [] -> io:format("OPEN_ERROR\tno .dets files in ~s~n", [DataDir]);
        _  -> ok
    end,
    [probe(F) || F <- Files].
probe(F) ->
    case dets:open_file(have_probe, [{file, F}, {repair, false}]) of
        {ok, P} ->
            ok = dets:close(P),
            io:format("OK\t~s~n", [F]);
        {error, {needs_repair, _}} ->
            io:format("NEEDS_REPAIR\t~s~n", [F]);
        {error, {not_a_dets_file, _}} ->
            io:format("CORRUPT_HEADER\t~s~n", [F]);
        {error, Other} ->
            io:format("OPEN_ERROR\t~s\t~p~n", [F, Other])
    end.
'''

def _escript() -> str:
    for cand in (
        os.path.expanduser("~/.asdf/installs/erlang/29.1.2/bin/escript"),
        os.path.expanduser("~/.erlmcp/otp-28.3.1/bin/escript"),
        shutil.which("escript") or "",
    ):
        if cand and os.path.exists(cand):
            return cand
    return "escript"

def run_dets_probe(data_dir: str) -> list[tuple[str, str, str]]:
    """Run the escript probe over data_dir; returns [(status, path, extra)]."""
    root = _escript()
    fd, es_path = tempfile.mkstemp(prefix="have_probe_", suffix=".erl", dir=os.path.join(REPO_ROOT, "tmp"))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(ES)
        os.chmod(es_path, 0o755)
        proc = subprocess.run([root, es_path, os.path.abspath(data_dir)],
                              capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            raise RuntimeError("escript probe failed: " + proc.stderr.strip())
    finally:
        os.unlink(es_path)
    rows = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            rows.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    return rows

def inspect_headers(data_dir: str) -> list[tuple[str, str]]:
    rows = []
    for name in sorted(os.listdir(data_dir)):
        if not name.endswith(".dets"):
            continue
        path = os.path.join(data_dir, name)
        try:
            with open(path, "rb") as f:
                head = f.read(8)
        except OSError as exc:
            rows.append((name, "CORRUPT_HEADER"))
            print("  %-24s CORRUPT_HEADER  (unreadable: %s)" % (name, exc))
            continue
        if len(head) < 8 or head[4:8] != DETS_MAGIC:
            rows.append((name, "CORRUPT_HEADER"))
            print("  %-24s CORRUPT_HEADER  (magic %s)" % (name, head[4:8].hex() or "none"))
        else:
            rows.append(header_state(path, name))
    return rows

def header_state(path: str, name: str) -> tuple[str, str]:
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
    if size == 0:
        print("  %-24s CORRUPT_HEADER  (zero-length)" % name)
        return (name, "CORRUPT_HEADER")
    print("  %-24s OK  (%d bytes, magic 00abcdef)" % (name, size))
    return (name, "OK")

def verify_clean_open(data_dir: str) -> list[tuple[str, str, str]]:
    rows = run_dets_probe(data_dir)
    for status, path, _ in rows:
        print("  %-24s %s" % (os.path.basename(path), status))
    return rows

def quarantine(data_dir: str) -> str:
    os.makedirs(QUARANTINE_DIR, exist_ok=True)
    ts = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    dest = os.path.join(QUARANTINE_DIR, "corrupt_state_%s.tar.gz" % ts)
    with tarfile.open(dest, "w:gz") as tar:
        for name in sorted(os.listdir(data_dir)):
            tar.add(os.path.join(data_dir, name), arcname=name)
    return dest

def ledger_pointer() -> int:
    print("RP-02 replay-from-ledger pointer:")
    abs_ledger = os.path.join(REPO_ROOT, LEDGER_POINTER)
    if os.path.exists(abs_ledger):
        print("  verified hash-chained ledger: %s" % abs_ledger)
        last = ""
        sha = ""
        with open(abs_ledger, "rb") as f:
            for line in f:
                if line.strip():
                    last = line
        try:
            import json
            entry = json.loads(last)
            sha = entry.get("entry_hash") or entry.get("hash") or ""
            print("  latest entry_hash: %s" % (sha or "(absent from last entry)"))
        except Exception:
            print("  latest line: %s..." % last[:72])
    else:
        print("  ledger absent at %s — replay authority falls back to" % LEDGER_POINTER)
        print("  docs/jira/v26.10.18/receipts/ court receipts (i24-store-dets-torn.md et al.)")
    return 0

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="RP-02 deterministic storage recovery probe (read-only; never repairs)")
    ap.add_argument("--inspect-headers", action="store_true")
    ap.add_argument("--verify-clean-open", action="store_true")
    ap.add_argument("--data-dir")
    ap.add_argument("--quarantine", action="store_true")
    ap.add_argument("--ledger-pointer", action="store_true")
    args = ap.parse_args(argv)

    if args.ledger_pointer:
        return ledger_pointer()

    if not (args.inspect_headers or args.verify_clean_open) or not args.data_dir:
        ap.print_usage()
        print("storage_probe: need --inspect-headers and/or --verify-clean-open with --data-dir")
        return 3

    corrupt = False
    if args.inspect_headers:
        print("== header inspection: %s" % args.data_dir)
        for _, state in inspect_headers(args.data_dir):
            corrupt = corrupt or (state != "OK")
    if args.verify_clean_open:
        print("== verify clean open (repair: false): %s" % args.data_dir)
        try:
            rows = verify_clean_open(args.data_dir)
        except RuntimeError as exc:
            print("  PROBE_ERROR %s" % exc)
            corrupt = True
        else:
            for status, _, _ in rows:
                corrupt = corrupt or (status != "OK")
    if corrupt and args.quarantine:
        dest = quarantine(args.data_dir)
        print("== quarantined corrupt state: %s" % dest)
    return 1 if corrupt else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

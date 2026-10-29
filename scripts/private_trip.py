#!/usr/bin/env python3
"""COURT-PRIVATE-TRIP: fail-closed private-token tripwire over the source tree.

Scans committed files (git ls-files) in source dirs for:
  1. absolute home paths of the form /Users/<name>/ (structural pattern)
  2. env-supplied tokens via PRIVATE_TRIP_TOKENS (comma-separated)

Exit 0 = clean, 1 = hits (file:line list), 2 = VACUOUS GATE (self-test
failed to refuse). The committed config carries NO private name; operator
supplies names per-invocation via env.
"""

import os
import re
import subprocess
import sys
import tempfile
import shutil

HOME_PATH_RE = re.compile(r"/Users/[a-z]+/")

# Source dirs only; docs/ excluded (receipts quote commands with sandbox paths).
SOURCE_DIRS = ("lib/", "test/", "workspace/", "scripts/", "justfile.d/", "popcorn_demo/lib/")

SELF = os.path.basename(__file__)


def committed_files():
    out = subprocess.run(
        ["git", "ls-files", "--", *SOURCE_DIRS],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(f"PRIVATE-TRIP REFUSE: git ls-files failed: {out.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return [f for f in out.stdout.splitlines() if os.path.basename(f) != SELF]


def scan_file(path, extra_tokens):
    hits = []
    try:
        with open(path, "rb") as raw:
            if b"\x00" in raw.read(8192):
                return hits  # binary file — line scan is meaningless, skip
        with open(path, encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                if HOME_PATH_RE.search(line):
                    hits.append((path, lineno, "home-path", line.rstrip()[:160]))
                for tok in extra_tokens:
                    if tok and tok in line:
                        hits.append((path, lineno, f"token:{tok[:24]}", line.rstrip()[:160]))
    except FileNotFoundError:
        pass  # deleted in worktree but still indexed — nothing on disk to leak
    except OSError as exc:
        print(f"PRIVATE-TRIP REFUSE: unreadable {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    return hits


def scan_tree(root, files, extra_tokens):
    hits = []
    for rel in files:
        hits.extend(scan_file(os.path.join(root, rel), extra_tokens))
    return hits


def self_test():
    """Non-vacuity: the scan logic must REFUSE a planted token in a temp dir."""
    tmp = tempfile.mkdtemp(prefix="private-trip-selftest-")
    try:
        probe = os.path.join(tmp, "probe.ex")
        with open(probe, "w") as fh:
            fh.write("defmodule Probe do\n  # /Users/nobody/probe\nend\n")
        hits = scan_tree(tmp, ["probe.ex"], [])
        home_refused = any(kind == "home-path" for _, _, kind, _ in hits)

        probe2 = os.path.join(tmp, "probe2.ex")
        with open(probe2, "w") as fh:
            fh.write("token = \"tripwire_secret_token\"\n")
        hits2 = scan_tree(tmp, ["probe2.ex"], ["tripwire_secret_token"])
        token_refused = any(kind.startswith("token:") for _, _, kind, _ in hits2)

        if not (home_refused and token_refused):
            print("PRIVATE-TRIP VACUOUS GATE: self-test scan did not refuse planted tokens", file=sys.stderr)
            print(f"  home-path refused: {home_refused}; token refused: {token_refused}", file=sys.stderr)
            sys.exit(2)
        print("PRIVATE-TRIP self-test: REFUSE witnessed (home-path + env token) — gate non-vacuous")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if "--self-test" in sys.argv[1:]:
        self_test()
        return

    extra_tokens = [t.strip() for t in os.environ.get("PRIVATE_TRIP_TOKENS", "").split(",") if t.strip()]
    files = committed_files()
    hits = scan_tree(os.getcwd(), files, extra_tokens)

    if hits:
        print(f"PRIVATE-TRIP REFUSE: {len(hits)} hit(s) in {len({h[0] for h in hits})} file(s)")
        for path, lineno, kind, line in hits:
            print(f"  {path}:{lineno}: [{kind}] {line}")
        sys.exit(1)
    print(f"PRIVATE-TRIP PASS: clean ({len(files)} source files scanned)")


if __name__ == "__main__":
    main()

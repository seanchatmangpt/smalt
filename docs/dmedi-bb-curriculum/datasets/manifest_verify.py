#!/usr/bin/env python3
"""BB-19 coherence-court D7: verify datasets/MANIFEST.md registered checksums.

Parses the "Registered checksums" block in datasets/MANIFEST.md (sha256sum-style
`<sha256>  <path>` lines), hashes each on-disk CSV from the curriculum root, and
diffs against the recorded digest. Zero mismatches = exit 0.

Missing files are reported as SKIP (in-flight lanes may not have landed), never
as a silent pass — a skip is loud. Any digest mismatch exits 1.

Run from the curriculum root: python3 datasets/manifest_verify.py
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "datasets" / "MANIFEST.md"


def parse_checksums():
    text = MANIFEST.read_text()
    m = re.search(r"```(?:sh|bash|shell)?\n((?:[0-9a-f]{64}  \S+\n)+)```", text)
    if not m:
        print("FAIL: no checksum block found in", MANIFEST)
        sys.exit(1)
    entries = []
    for line in m.group(1).splitlines():
        digest, path = line.split("  ")
        entries.append((digest, path))
    return entries


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    entries = parse_checksums()
    passed, skipped, failed = [], [], []
    for digest, rel in entries:
        path = ROOT / rel
        if not path.exists():
            skipped.append(rel)
            continue
        got = sha256(path)
        if got == digest:
            passed.append(rel)
        else:
            failed.append((rel, digest, got))
    print(f"manifest_verify: {len(passed)} PASS, {len(skipped)} SKIP, {len(failed)} FAIL")
    for rel in passed:
        print(f"  [PASS] {rel}")
    for rel in skipped:
        print(f"  [SKIP] {rel} (missing on disk — in-flight?)")
    for rel, want, got in failed:
        print(f"  [FAIL] {rel}\n         recorded {want}\n         on-disk  {got}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()

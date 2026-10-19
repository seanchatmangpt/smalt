#!/usr/bin/env python3
"""S-4 wire-norm court shim: revert ONE landed edit semantically, in place.

Usage: wire_norm_shim.py <kd01|kd03|kd07> <subject-file>

One-line shims (each target line must appear exactly once, else exit 2
without writing):

  kd01: neutralize the comp==metadata branch condition so blob PUT
        ?comp=metadata falls back into the read_body/put_blob arm (the old
        wire: 201 + JSON debug body).
  kd03: pass `created` through unformatted (old wire: ISO-8601 echo).
  kd07: pass `docs` through instead of the ReadFeed envelope (old wire:
        bare JSON array).
"""
import sys

SHIMS = {
    # KD-01 PUT arm only: the GET comp=metadata arm (KD-60) carries the same
    # one-line shape, so anchor on the KD-01 comment block above the PUT arm
    # (re-anchored 2026-10-18 after the KD-60 GET arm landed).
    "kd01": (
        (
            '          # KD-01 wire normalization (Azure Put Blob Metadata): comp=metadata is\n'
            '          # answered BEFORE the body read \u2014 200 EMPTY with etag, never the old\n'
            '          # 201 + JSON debug body (which also silently emptied the content).\n'
            '          if conn.query_params["comp"] == "metadata" do'
        ),
        (
            '          # KD-01 wire normalization (Azure Put Blob Metadata): comp=metadata is\n'
            '          # answered BEFORE the body read \u2014 200 EMPTY with etag, never the old\n'
            '          # 201 + JSON debug body (which also silently emptied the content).\n'
            '          if false and conn.query_params["comp"] == "metadata" do  # SHIM-COURT'
        ),
    ),
    "kd03": (
        '          "last-modified" => rfc1123(record["created"]),',
        '          "last-modified" => record["created"],  # SHIM-COURT',
    ),
    "kd07": (
        # Either KD-07 hunk variant (payload v3 or envelope v1).
        None,
        '          cosmos_respond(conn, {:ok, status, headers, docs})  # SHIM-COURT',
    ),
}

def main():
    kd, path = sys.argv[1], sys.argv[2]
    old, shimmed = SHIMS[kd]
    s = open(path).read()
    if kd == "kd07":
        candidates = [
            '          cosmos_respond(conn, {:ok, status, headers, payload})',
            '          cosmos_respond(conn, {:ok, status, headers, envelope})',
        ]
        hits = [c for c in candidates if s.count(c) == 1]
        if not hits:
            print(f"[FAIL:SHIM] kd07: no unique respond line found: {path}", file=sys.stderr)
            sys.exit(2)
        old = hits[0]
    n = s.count(old)
    if n != 1:
        print(f"[FAIL:SHIM] {kd}: target line found {n}x (need exactly 1): {path}", file=sys.stderr)
        sys.exit(2)
    open(path, "w").write(s.replace(old, shimmed, 1))

if __name__ == "__main__":
    main()

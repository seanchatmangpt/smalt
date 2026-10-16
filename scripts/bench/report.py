#!/usr/bin/env python3
"""bench-report: aggregate docs/jira/v26.10.14/bench/*.jsonl -> BENCH_RESULTS.md.

Part of the B-1 shared bench infra (scripts/bench/). Stdlib-only.

Usage: python3 scripts/bench/report.py
"""
import glob
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULTS_DIR = os.path.join(REPO, "docs/jira/v26.10.14/bench")
OUT = os.path.join(REPO, "docs/jira/v26.10.14/BENCH_RESULTS.md")


def is_op_row(r):
    """An op row has an "op" key and a numeric ops_per_sec."""
    return isinstance(r.get("op"), str) and isinstance(r.get("ops_per_sec"), (int, float))


def iter_jsonl(path):
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                pass


def parse_line(line):
    """json.loads with one minimal recovery: a row truncated mid-record
    (trailing comma before the cut, e.g. the b8 rerun rows cut inside the
    machine block) is repaired only if every op-row field survives the cut."""
    try:
        return json.loads(line), False
    except json.JSONDecodeError:
        s = line.rstrip().rstrip(",")
        if s.endswith("}"):
            s = s[:-1]
        s += "}"
        for depth in (s.count("{") - s.count("}"),):
            s += "}" * depth
        try:
            r = json.loads(s)
        except json.JSONDecodeError:
            return None, True
        if is_op_row(r):
            return r, False
        return None, True


def classify_event(r):
    """Short label for a non-op record."""
    if "phases" in r:
        return "phase-record"
    if "bench" in r:
        return r["bench"]
    if "event" in r:
        return r["event"]
    if "proc_count" in r and "binary_leak_delta" in r:
        return "mem-telemetry-sample"
    if "op" in r:
        return str(r["op"])
    return "?"


def main():
    files = sorted(glob.glob(os.path.join(RESULTS_DIR, "*.jsonl")))
    if not files:
        print(f"no .jsonl results in {RESULTS_DIR}", file=sys.stderr)
        return 1

    # Group rows by (lane, surface). Two record classes:
    #   op rows: have "op" key + numeric ops_per_sec -> rendered as table rows
    #   event records: bench/event meta (chaos runs, meta lines, phase blobs) ->
    #     summarized per section, never rendered as fake op rows
    sections = {}
    skipped = 0
    for path in files:
        lane_file = os.path.basename(path)
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r, recovered = parse_line(line)
                except json.JSONDecodeError:
                    r, recovered = None, True
                if r is None:
                    skipped += 1
                    print(f"[WARN] skipping malformed line in {path}: {line[:80]}", file=sys.stderr)
                    continue
                if recovered:
                    print(f"[INFO] recovered truncated op row in {path}: {r.get('op')}", file=sys.stderr)
                if not is_op_row(r):
                    continue
                key = (r.get("lane", "?"), r.get("surface", "?"))
                sections.setdefault(key, []).append(r)
    if skipped:
        print(f"[WARN] {skipped} malformed line(s) skipped", file=sys.stderr)

    # Event-class records: summarize by lane file, never restate numbers.
    event_files = sorted(
        p for p in files if any(not is_op_row(r) for r in iter_jsonl(p))
    )

    lines = [
        "# Bench Results — v26.10.14",
        "",
        "Aggregated from `docs/jira/v26.10.14/bench/*.jsonl` by `just bench-report`",
        "(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.",
        "",
        "## Methodology",
        "",
        "Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,",
        "errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure",
        "SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.",
        "SDK-vs-BEAM multiplier narrative lives in the per-lane receipts",
        "(`docs/jira/v26.10.14/receipts/bench-*.md`), not restated here. Non-op record",
        "classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,",
        "not rendered as op rows.",
        "",
    ]
    for (lane, surface), rows in sorted(sections.items()):
        lines += [f"## {lane} — {surface}", "",
                  "| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |",
                  "|---|---|---|---|---|---|---|"]
        for r in rows:
            lines.append(
                "| {op} | {n} | {ops_per_sec:.0f} | {p50_ms:.2f} | {p95_ms:.2f} | {p99_ms:.2f} | {errors} |".format(
                    op=r.get("op", "?"),
                    n=r.get("n", 0),
                    ops_per_sec=float(r.get("ops_per_sec", 0)),
                    p50_ms=float(r.get("p50_ms", 0)),
                    p95_ms=float(r.get("p95_ms", 0)),
                    p99_ms=float(r.get("p99_ms", 0)),
                    errors=r.get("errors", 0),
                )
            )
    if event_files:
        lines += ["## Non-op records", ""]
        for p in event_files:
            recs = [r for r in iter_jsonl(p) if not is_op_row(r)]
            if not recs:
                continue
            kinds = sorted({classify_event(r) for r in recs})
            lines.append(
                "- `{}`: {} non-op record(s) ({}) — see file for full run data.".format(
                    os.path.basename(p), len(recs), ", ".join(kinds)
                )
            )
        lines.append("")

    lines += ["---", "End of generated bench report."]
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"[BENCH-REPORT] {len(files)} file(s), {sum(len(v) for v in sections.values())} rows -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

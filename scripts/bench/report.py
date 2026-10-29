#!/usr/bin/env python3
"""bench-report: aggregate docs/jira/v<window>/bench/*.jsonl -> BENCH_RESULTS.md.

Part of the B-1 shared bench infra (scripts/bench/). Stdlib-only.

Multi-window (2026-10-16): every docs/jira/v*/bench dir gets its own
BENCH_RESULTS.md next to it. Set BENCH_RESULTS_DIR (and optionally
BENCH_REPORT_OUT) to reproduce a single window byte-identically.

Usage: python3 scripts/bench/report.py
"""
import glob
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JIRA = os.path.join(REPO, "docs/jira")


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


def render_window(results_dir, out, version):
    """Aggregate one window's bench/*.jsonl into `out`. Returns exit code."""
    all_files = sorted(glob.glob(os.path.join(results_dir, "*.jsonl")))
    # SHIM-COURT-adjacent law: wave-telemetry.jsonl is fleet run telemetry,
    # not bench lane output — its rows have no op/ops_per_sec shape and would
    # degrade to "?" sections. Split it out and tag it explicitly instead.
    files = [p for p in all_files if not os.path.basename(p).startswith("wave-telemetry")]
    wave_files = [p for p in all_files if os.path.basename(p).startswith("wave-telemetry")]
    # Window-root wave telemetry (some windows keep it outside bench/).
    root_wave = sorted(
        p
        for p in glob.glob(os.path.join(os.path.dirname(results_dir), "wave-telemetry*.jsonl"))
        if os.path.isfile(p)
    )
    wave_files += root_wave
    if not files and not wave_files:
        # Empty bench dir is a legitimate wrap-window state (e.g. a fresh
        # window with only README.md) — skip loudly, not fail-closed.
        print(f"[BENCH-REPORT] {version}: no jsonl — skipped", file=sys.stderr)
        return 0

    # Group rows by (lane, surface). Two record classes:
    #   op rows: have "op" key + numeric ops_per_sec -> rendered as table rows
    #   event records: bench/event meta (chaos runs, meta lines, phase blobs) ->
    #     summarized per section, never rendered as fake op rows
    sections = {}
    skipped = 0
    for path in files:
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
        f"# Bench Results — {version}",
        "",
        f"Aggregated from `docs/jira/{version}/bench/*.jsonl` by `just bench-report`",
        "(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.",
        "",
        "## Methodology",
        "",
        "Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,",
        "errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure",
        "SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.",
        "SDK-vs-BEAM multiplier narrative lives in the per-lane receipts",
        f"(`docs/jira/{version}/receipts/bench-*.md`), not restated here. Non-op record",
        "classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,",
        "not rendered as op rows.",
        "",
    ]
    for (lane, surface), rows in sorted(sections.items()):
        # Verdict-carrying rows (verdict-carrying n==0 correctness probes from
        # the enclave-loop harnesses: PASS / FAIL / SKIP-LOUD) are NOT op rows —
        # rendering them in the throughput table would silently present a
        # zero-throughput correctness verdict as a measured op. They get their
        # own verdict table so FAIL/SKIP rows are visibly separated.
        vrows = [r for r in rows if "verdict" in r]
        orows = [r for r in rows if "verdict" not in r]

        lines += [f"## {lane} — {surface}", ""]
        if orows:
            lines += [
                "| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |",
                "|---|---|---|---|---|---|---|",
            ]
            for r in orows:
                # None-safe coercion: historical lane rows carry explicit
                # nulls for fields that don't apply (e.g. memory probes with
                # no ops/sec) — a bare float(None) crashes the whole report.
                def num(v):
                    return float(v) if isinstance(v, (int, float)) else 0.0

                lines.append(
                    "| {op} | {n} | {ops_per_sec:.0f} | {p50_ms:.2f} | {p95_ms:.2f} | {p99_ms:.2f} | {errors} |".format(
                        op=r.get("op", "?"),
                        n=r.get("n", 0),
                        ops_per_sec=num(r.get("ops_per_sec")),
                        p50_ms=num(r.get("p50_ms")),
                        p95_ms=num(r.get("p95_ms")),
                        p99_ms=num(r.get("p99_ms")),
                        errors=r.get("errors", 0),
                    )
                )
        if vrows:
            lines += [
                "",
                "### Verdict rows (correctness probes, not throughput ops)",
                "",
                "| op | verdict | n | errors | reason/note |",
                "|---|---|---|---|---|",
            ]
            for r in vrows:
                reason = (
                    r.get("reason")
                    or r.get("note")
                    or ""
                )
                reason = str(reason).replace("|", "\\|")
                lines.append(
                    "| {op} | {verdict} | {n} | {errors} | {reason} |".format(
                        op=r.get("op", "?"),
                        verdict=r.get("verdict", "?"),
                        n=r.get("n", 0),
                        errors=r.get("errors", 0),
                        reason=reason,
                    )
                )
        if vrows:
            lines.append("")
    if not sections:
        lines += [
            "No op rows (records with `op` + numeric `ops_per_sec`, per REGISTRY.md)",
            "were present in this window's bench data yet. Sections below summarize",
            "the record classes that DO exist — nothing is fabricated into op tables.",
            "",
        ]
    if event_files or wave_files:
        lines += ["## Non-op records", ""]
        for p in wave_files:
            n = sum(1 for _ in iter_jsonl(p))
            loc = os.path.relpath(p, os.path.dirname(results_dir))
            lines.append(
                "- `{}`: wave-telemetry (fleet run telemetry, EXCLUDED from bench "
                "aggregation) — {} record(s), see file for full run data.".format(
                    loc, n
                )
            )
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
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"[BENCH-REPORT] {version}: {len(files)} file(s), {sum(len(v) for v in sections.values())} rows -> {out}")
    # Fail-closed: malformed rows mean the aggregation is incomplete — the
    # report is still written, but the caller must see the defect.
    if skipped:
        print(f"[BENCH-REPORT] FAIL({version}): {skipped} malformed row(s) skipped; report incomplete", file=sys.stderr)
        return 1
    return 0


def main():
    # Legacy single-window mode: byte-identical to the pre-multi-window report
    # for the window it pins.
    if os.environ.get("BENCH_RESULTS_DIR"):
        results_dir = os.environ["BENCH_RESULTS_DIR"]
        version = os.path.basename(os.path.dirname(results_dir))
        out = os.environ.get(
            "BENCH_REPORT_OUT", os.path.join(os.path.dirname(results_dir), "BENCH_RESULTS.md")
        )
        return render_window(results_dir, out, version)

    bench_dirs = sorted(glob.glob(os.path.join(JIRA, "v*", "bench")))
    if not bench_dirs:
        print(f"no docs/jira/v*/bench dirs under {JIRA}", file=sys.stderr)
        return 1
    rc = 0
    for bench_dir in bench_dirs:
        version = os.path.basename(os.path.dirname(bench_dir))
        out = os.path.join(os.path.dirname(bench_dir), "BENCH_RESULTS.md")
        rc = render_window(bench_dir, out, version) or rc
    return rc


if __name__ == "__main__":
    sys.exit(main())

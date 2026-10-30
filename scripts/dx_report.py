#!/usr/bin/env python3
"""dx_report.py — SPC view over posh/var/dx-events.jsonl (lane 13, gaps/66).

Prints per gate: n, pass rate, p50/p99 elapsed_ms (all rows; live vs backfilled split).
Exit 0 always; prints NO DATA loudly if the log is missing/empty.
"""
import json
import math
import os
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.path.join(ROOT, "posh", "var", "dx-events.jsonl")


def pctl(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * p / 100.0
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def main():
    as_json = "--json" in sys.argv[1:]

    if not os.path.exists(LOG):
        if as_json:
            print(json.dumps({"rows": [], "no_data": True}))
        else:
            print(f"NO DATA: {LOG} does not exist (no telemetry landed yet)")
        return 0
    rows = []
    with open(LOG) as fh:
        for i, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                print(f"WARN: skipping malformed JSONL row {i}", file=sys.stderr)
                continue
            rows.append(r)
    if not rows:
        if as_json:
            print(json.dumps({"rows": [], "no_data": True}))
        else:
            print(f"NO DATA: {LOG} is empty")
        return 0

    by_gate = defaultdict(list)
    for r in rows:
        by_gate[r.get("gate", "?")].append(r)

    if not as_json:
        print(f"DX telemetry report — {LOG} ({len(rows)} rows)")
        print()
        hdr = f"{'gate':<16} {'n':>5} {'pass%':>7} {'fail':>5} {'skip':>5} {'p50_ms':>8} {'p99_ms':>8} {'bf':>4}"
        print(hdr)
        print("-" * len(hdr))
    json_rows = []
    for gate in sorted(by_gate):
        rs = by_gate[gate]
        n = len(rs)
        npass = sum(1 for r in rs if r.get("outcome") == "pass")
        nfail = sum(1 for r in rs if r.get("outcome") == "fail")
        nskip = sum(1 for r in rs if r.get("outcome") == "skip")
        times = sorted(int(r["elapsed_ms"]) for r in rs if isinstance(r.get("elapsed_ms"), (int, float)))
        p50 = pctl(times, 50)
        p99 = pctl(times, 99)
        bf = sum(1 for r in rs if r.get("backfilled"))
        json_rows.append({
            "gate": gate,
            "n": n,
            "pass_pct": round(100.0 * npass / n, 2),
            "fail": nfail,
            "skip": nskip,
            "p50_ms": p50,
            "p99_ms": p99,
            "bf": bf,
        })
        if not as_json:
            print(f"{gate:<16} {n:>5} {100.0 * npass / n:>6.1f}% {nfail:>5} {nskip:>5} "
                  f"{p50 if p50 is not None else '-':>8} {p99 if p99 is not None else '-':>8} {bf:>4}")
    if as_json:
        print(json.dumps({"rows": json_rows, "no_data": False}))
    return 0


if __name__ == "__main__":
    sys.exit(main())

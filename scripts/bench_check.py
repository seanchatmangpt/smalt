#!/usr/bin/env python3
"""Smalt benchmark regression gate (stdlib-only).

Reads tmp/bench-receipt.json (schema smalt-bench/v1, produced by
scripts/bench.py) and asserts the PRD CTQ thresholds:

  doctor            <= 3s
  boot p95          <= 5s
  ARM PUT p95       <  50ms
  Cosmos p95        <  20ms
  AMQP first-frame  <  100ms

Exit 0 when every CTQ passes; exit 1 on any FAIL, missing/stale/invalid
receipt (failing CTQ table printed). --json emits a machine-readable
gate receipt on stdout. Refuses to run bench.py itself — run it manually
first (ports free per scripts/doctor.py).
"""
import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECEIPT_PATH = os.path.join(REPO, "tmp", "bench-receipt.json")
SCHEMA = "smalt-bench/v1"
DEFAULT_MAX_AGE_H = 24.0

CTQS = [
    # (receipt key, metric key, label, threshold, op)  op: "le" | "lt"
    ("doctor", "elapsed_s", "doctor runtime", 3.0, "le"),
    ("boot", "p95_s", "boot p95", 5.0, "le"),
    ("arm_put", "p95", "ARM PUT p95", 50.0, "lt"),
    ("cosmos_roundtrip", "p95", "Cosmos round-trip p95", 20.0, "lt"),
    ("amqp_first_frame", "p95", "AMQP first-frame p95", 100.0, "lt"),
]


def receipt_age_h(text):
    """Parse the receipt's %z-timestamp; return age in hours (inf on parse fail)."""
    m = re.search(r'"date"\s*:\s*"([^"]+)"', text)
    if not m:
        return float("inf")
    raw = m.group(1)
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.strptime(raw, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return (datetime.now(timezone.utc) - dt).total_seconds() / 3600.0
        except ValueError:
            continue
    return float("inf")


def main():
    ap = argparse.ArgumentParser(description="smalt bench regression gate")
    ap.add_argument("--json", action="store_true", help="emit machine receipt")
    ap.add_argument("--max-age-h", type=float, default=DEFAULT_MAX_AGE_H,
                    help=f"receipt max age in hours (default {DEFAULT_MAX_AGE_H})")
    ap.add_argument("--receipt", default=RECEIPT_PATH)
    args = ap.parse_args()

    rows = []  # (label, value, unit, op/target, verdict, detail)

    def add(label, value, unit, target, op, ok, detail=""):
        rows.append({
            "ctq": label, "value": value, "unit": unit,
            "target": target, "op": op, "verdict": "PASS" if ok else "FAIL",
            "detail": detail,
        })

    try:
        with open(args.receipt) as f:
            text = f.read()
        receipt = json.loads(text)
    except FileNotFoundError:
        add("receipt", None, "", "", "", False,
            f"missing: {args.receipt} (run scripts/bench.py first)")
        receipt = None
    except json.JSONDecodeError as e:
        add("receipt", None, "", "", "", False, f"invalid JSON: {e}")
        receipt = None

    if receipt is not None:
        if receipt.get("schema") != SCHEMA:
            add("receipt", receipt.get("schema"), "", SCHEMA, "eq", False,
                f"schema mismatch, expected {SCHEMA}")
        else:
            age = receipt_age_h(text)
            if age > args.max_age_h:
                add("receipt", round(age, 2), "h", args.max_age_h, "le", False,
                    "stale receipt — rerun scripts/bench.py")
            else:
                for key, mkey, label, target, op in CTQS:
                    sect = receipt.get(key)
                    if not isinstance(sect, dict) or mkey not in sect:
                        add(label, None, "", target, op, False,
                            f"missing {key}.{mkey} in receipt")
                        continue
                    val = sect[mkey]
                    ok = (val <= target) if op == "le" else (val < target)
                    add(label, val, sect.get("unit", "s" if key in ("doctor", "boot") else "ms"),
                        target, op, ok)

    failed = [r for r in rows if r["verdict"] != "PASS"]
    gate = {
        "schema": "smalt-bench-gate/v1",
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "receipt": os.path.relpath(args.receipt, REPO),
        "verdict": "PASS" if not failed else "FAIL",
        "failed": len(failed),
        "ctqs": rows,
    }

    if args.json:
        print(json.dumps(gate, indent=2))
    else:
        print("== Bench Gate ==")
        for r in rows:
            if r["value"] is None:
                print(f"  {r['ctq']:26s} -> {r['verdict']}  ({r['detail']})")
            else:
                cmp = "<=" if r["op"] == "le" else "< "
                print(f"  {r['ctq']:26s} {r['value']:>8} {r['unit']:2s} "
                      f"({cmp} {r['target']}) -> {r['verdict']}")
        print(f"\nGate: {gate['verdict']} ({len(rows) - len(failed)}/{len(rows)} CTQs pass)")
        for r in failed:
            if r["detail"]:
                print(f"  FAIL detail [{r['ctq']}]: {r['detail']}", file=sys.stderr)

    sys.exit(0 if not failed else 1)


if __name__ == "__main__":
    main()

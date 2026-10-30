#!/usr/bin/env python3
"""dod_check.py — DoD single-source reader (v26.10.30 POSH wave).

Parses dod.yaml (machine-readable Definition of Done) and RUNS each gate:
  - status: alive   → run the gate command, timeout-bounded, compare to
                      expected_exit; print PASS/FAIL.
  - status: planned → no gate; print SKIP loud with reason "planned".
  - gate empty      → SKIP loud with reason "no gate command registered".
  - gate exits 3    → SKIP loud with the gate's typed skip reason (substrate
                      down, pack not landed, ...); counts as SKIP, not FAIL.
Exit contract: 0 iff no FAIL among status:alive rows (SKIPs are loud but not
failures — a court that cannot run is skipped loudly, never a silent pass).
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MANIFEST = os.path.join(REPO, "dod.yaml")
TIMEOUT_DEFAULT = 600  # seconds per gate

GREEN, RED, YELLOW, DIM, NC = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def color(code, s):
    return f"{code}{s}{NC}" if sys.stdout.isatty() else s


def run_gate(req, timeout):
    """Returns (verdict, detail). verdict in PASS/FAIL/SKIP."""
    gate = (req.get("gate") or "").strip()
    if req.get("status") == "planned":
        return "SKIP", "planned (no gate registered — claim is not ALIVE)"
    if not gate:
        return "SKIP", "no gate command registered"
    try:
        proc = subprocess.run(
            gate, shell=True, cwd=REPO, capture_output=True, text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "FAIL", f"gate exceeded {timeout}s timeout"
    rc = proc.returncode
    exp = req.get("expected_exit", 0)
    tail = ""
    for src in (proc.stdout, proc.stderr):
        if src:
            tail = src.strip().splitlines()[-1][:160]
    if rc == exp:
        return "PASS", tail or f"exit {rc}"
    if rc == 3:
        return "SKIP", f"loud skip (exit 3): {tail}"
    return "FAIL", f"exit {rc} != expected {exp}: {tail}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--section", default=None, help="run only rows with this section value")
    ap.add_argument("--json-out", default=None, help="write machine-readable results JSON here")
    ap.add_argument("--timeout", type=int, default=TIMEOUT_DEFAULT)
    args = ap.parse_args()

    with open(args.manifest) as f:
        doc = yaml.safe_load(f)
    reqs = doc.get("requirements", [])
    if args.section:
        reqs = [r for r in reqs if r.get("section") == args.section]
    if not reqs:
        print(f"[DOD-FAIL] no requirements matched (section={args.section})", file=sys.stderr)
        return 2

    results = []
    for req in reqs:
        rid = req.get("id", "?")
        verdict, detail = run_gate(req, args.timeout)
        results.append({"id": rid, "section": req.get("section"), "status": req.get("status"),
                        "verdict": verdict, "detail": detail})
        c = {"PASS": GREEN, "FAIL": RED, "SKIP": YELLOW}[verdict]
        print(f"{color(c, verdict):5} {rid:28} {detail}")

    n_pass = sum(1 for r in results if r["verdict"] == "PASS")
    n_fail = sum(1 for r in results if r["verdict"] == "FAIL")
    n_skip = sum(1 for r in results if r["verdict"] == "SKIP")
    n_alive_fail = sum(1 for r in results if r["verdict"] == "FAIL" and r["status"] == "alive")

    print()
    print(f"[DOD] {n_pass} PASS / {n_fail} FAIL / {n_skip} SKIP "
          f"({len(results)} rows, section={args.section or 'all'})")
    if n_alive_fail:
        print(f"[DOD-FAIL] {n_alive_fail} alive-row FAIL(s) — honest baseline recorded")
        rc = 1
    else:
        print("[DOD] no FAIL among status:alive rows")
        rc = 0

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump({"at": datetime.now(timezone.utc).isoformat(),
                       "manifest": args.manifest, "section": args.section,
                       "results": results, "summary": {"pass": n_pass, "fail": n_fail,
                                                       "skip": n_skip, "exit": rc}}, f, indent=2)
        print(f"[DOD] results JSON -> {args.json_out}")
    return rc


if __name__ == "__main__":
    sys.exit(main())

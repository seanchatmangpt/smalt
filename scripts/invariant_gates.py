#!/usr/bin/env python3
"""invariant_gates.py — runner for the six fail-closed invariant gates.

The legacy runner (test/invariant_gates_test.py) was deleted with test/ in
the v26.10.19 clean-room reset (64f6099). This is the fresh successor: same
contract, no unittest — for each gate driver in gates/*_gate.py it runs the
gate for real (each self-boots a substrate on private ports via
gates/common.py), asserts exit 0, receipt PASS, and every negative fixture
detected. Fail-closed: 0 gates found -> exit 1.

Exit 0 all gates pass / 1 any gate fails (or no gates found / unreadable
receipt). Receipts: tmp/invariant-gates/<gate>-receipt.json (written fresh
by gates/common.py:run_gate).

Usage:
  python3 scripts/invariant_gates.py                  # all gates
  python3 scripts/invariant_gates.py --gate cosmos-etag-cas
  python3 scripts/invariant_gates.py --gate cosmos-etag-cas,blob-worm
"""
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATES_DIR = os.path.join(REPO, "gates")
RECEIPT_DIR = os.path.join(REPO, "tmp", "invariant-gates")

FILES = {
    "cosmos-etag-cas": "cosmos_etag_cas_gate.py",
    "blob-worm": "blob_worm_gate.py",
    "ledger-chain": "ledger_chain_gate.py",
    "queue-capacity": "queue_capacity_gate.py",
    "lock-clamp": "lock_clamp_gate.py",
    "appconfig-etag-cas": "appconfig_etag_cas_gate.py",
}


def main(argv):
    gates = dict(FILES)
    if "--gate" in argv[1:]:
        i = argv.index("--gate")
        sel = argv[i + 1]
        gates = {}
        for tok in sel.split(","):
            tok = tok.strip()
            if not tok:
                continue
            if tok not in FILES:
                print("[INVARIANT-GATES] [FAIL] unknown gate %r (have: %s)"
                      % (tok, ", ".join(sorted(FILES))))
                return 1
            gates[tok] = FILES[tok]
    if not gates:
        print("[INVARIANT-GATES] [FAIL] no gates configured — fail-closed")
        return 1
    missing = [f for f in FILES.values()
               if not os.path.isfile(os.path.join(GATES_DIR, f))]
    if missing:
        print("[INVARIANT-GATES] [FAIL] gate drivers missing from gates/: %s — fail-closed"
              % ", ".join(missing))
        return 1

    results = []
    failed = 0
    for name in sorted(gates):
        path = os.path.join(GATES_DIR, gates[name])
        print("\n=== [INVARIANT-GATE] %s ===" % name)
        try:
            r = subprocess.run([sys.executable, path], cwd=REPO, text=True,
                               stdout=sys.stdout, stderr=sys.stderr, timeout=900)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = 124
            print("[INVARIANT-GATES] [FAIL] %s timed out (900s)" % name)
        row = {"gate": name, "exit": rc}
        # Receipt contract: PASS verdict + every negative fixture detected.
        rpath = os.path.join(RECEIPT_DIR, "%s-receipt.json" % name)
        receipt = None
        if rc == 0:
            try:
                with open(rpath) as f:
                    receipt = json.load(f)
                if receipt.get("verdict") != "PASS":
                    print("[INVARIANT-GATES] [FAIL] %s receipt verdict=%s"
                          % (name, receipt.get("verdict")))
                    rc = 1
                elif not receipt.get("fixtures"):
                    print("[INVARIANT-GATES] [FAIL] %s declared no negative fixtures (vacuous)"
                          % name)
                    rc = 1
                elif not all(fx.get("detected") for fx in receipt["fixtures"]):
                    bad = [fx["fixture"] for fx in receipt["fixtures"] if not fx.get("detected")]
                    print("[INVARIANT-GATES] [FAIL] %s fixtures not detected: %s"
                          % (name, ", ".join(bad)))
                    rc = 1
            except (OSError, ValueError) as exc:
                print("[INVARIANT-GATES] [FAIL] %s receipt unreadable: %s" % (name, exc))
                rc = 1
        row["verdict"] = "PASS" if rc == 0 else "FAIL"
        results.append(row)
        if rc != 0:
            failed += 1
            print("[INVARIANT-GATES] [FAIL] %s (exit %s)" % (name, rc))

    print("\n================ INVARIANT-GATES VERDICT TABLE ================")
    for row in results:
        print("  %-20s %s" % (row["gate"], row["verdict"]))
    print("================================================================")
    if failed:
        print("[INVARIANT-GATES] FAIL: %d/%d gate(s) failed." % (failed, len(results)))
        return 1
    print("[INVARIANT-GATES] PASS: %d/%d gates (positive held + all negative fixtures refused)."
          % (len(results), len(results)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

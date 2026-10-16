#!/usr/bin/env python
"""Run the smalt-cli verification gates.

Usage::

    python run_gates.py [--gate N] [--ledger PATH]

Runs the gates in order (see GATES.md) and appends a per-gate receipt record
to the append-only audit ledger. Exit 0 iff no gate FAILs (SKIP is allowed
and reported loudly).
"""

from __future__ import annotations

import argparse
import sys
import time

from smalt_cli.gates import DEFAULT_LEDGER, run_all_gates


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Run smalt-cli verification gates.")
    ap.add_argument("--gate", type=int, choices=[1, 2, 3, 4],
                    help="run a single gate instead of all four")
    ap.add_argument("--ledger", default=DEFAULT_LEDGER,
                    help="audit manifest path (default: %(default)s)")
    args = ap.parse_args(argv)

    results = run_all_gates(ledger_path=args.ledger, only=args.gate)
    for res in results:
        print(res.to_json())
    failed = [r for r in results if r.status == "FAIL"]
    print(
        "gates: %d run, %d PASS, %d SKIP, %d FAIL"
        % (len(results),
           sum(1 for r in results if r.status == "PASS"),
           sum(1 for r in results if r.status == "SKIP"),
           len(failed)),
        file=sys.stderr,
    )
    # Note: run_all_gates already appended each gate receipt to the ledger;
    # the summary line above is printed after the last receipt lands.
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

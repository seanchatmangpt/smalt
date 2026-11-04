#!/usr/bin/env python3
"""Strict-bundle court wrapper, Module 27 (detailed design).

Thin wrapper over the registered derive court of record
(scripts/derive_keys.py: tolerance math re-derived from pinned constants
in BOTH regimes + DFMEA<->checklist linkage court). Real subprocess
execution; asserts exit 0 AND the pinned PASS-line count (loud-fail on
drift), runs the mutation court (corrupt one pinned checklist constant
-> script must exit nonzero), and carries the stale pre-adjudication
4.17 um sigma loud-fail over data/ (module 27 legitimately cites 4.17 um
as the HISTORICAL regime in prose/scripts, never in data/).

Usage: python3 court.py    (run from the module root)
"""
import glob
import hashlib
import os
import re
import subprocess
import sys

MODULE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = "scripts/derive_keys.py"
DATA_GLOB = "data/*.csv"
EXPECTED_CHECKS = 19          # measured PASS-line count (manifest row says
                              # "18 checks" -- see receipt, drift disclosed)
CHECK_PATTERN = re.compile(r"^PASS", re.M)
STALE_SIGMA = "4.17"          # loud-fail if the retired regime lands in data
MUTATE_FILE = "data/design-control-checklist.csv"
MUTATE_ROW = "DC-01"
MUTATE_FROM = ",CP-1\n"       # DC-01 plan_row; unique vs CP-10..CP-18 by \n
MUTATE_TO = ",CP-99\n"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run_script():
    return subprocess.run([sys.executable, SCRIPT], cwd=MODULE,
                          capture_output=True, text=True)


def main():
    os.chdir(MODULE)

    # -- 1. stale-sigma loud-fail ------------------------------------------
    for path in sorted(glob.glob(DATA_GLOB)):
        with open(path, encoding="utf-8", errors="replace") as f:
            if STALE_SIGMA in f.read():
                print(f"STALE-SIGMA FAIL: {path} carries the retired "
                      f"{STALE_SIGMA} um regime; adjudicated spine is 7.407 um"
                      )
                return 1

    # -- 2. real run --------------------------------------------------------
    r = run_script()
    if r.returncode != 0:
        print(f"COURT FAIL: {SCRIPT} exit {r.returncode}\n{r.stdout}\n{r.stderr}")
        return 1
    n_checks = len(CHECK_PATTERN.findall(r.stdout))
    if n_checks != EXPECTED_CHECKS:
        print(f"CHECK-COUNT DRIFT FAIL: {SCRIPT} emitted {n_checks} checks; "
              f"court pins {EXPECTED_CHECKS}")
        return 1
    print(f"bundle: {SCRIPT} exit 0, {n_checks}/{EXPECTED_CHECKS} checks green")

    # -- 3. mutation court: DC-01 plan_row CP-1 -> CP-99 --------------------
    before = sha256(MUTATE_FILE)
    with open(MUTATE_FILE, "rb") as f:
        before_bytes = f.read()
    with open(MUTATE_FILE, encoding="utf-8") as f:
        body = f.read()
    occurrences = body.count(MUTATE_FROM)
    if occurrences != 1:
        print(f"MUTATION SETUP FAIL: {MUTATE_ROW!r} terminator occurs "
              f"{occurrences}x in {MUTATE_FILE} (expected exactly 1)")
        return 1
    with open(MUTATE_FILE, "w", encoding="utf-8") as f:
        f.write(body.replace(MUTATE_FROM, MUTATE_TO, 1))
    try:
        m = run_script()
    finally:
        with open(MUTATE_FILE, "wb") as f:
            f.write(before_bytes)
    if sha256(MUTATE_FILE) != before:
        print("RESTORE FAIL: checklist not byte-identical after mutation court")
        return 1
    if m.returncode == 0:
        print(f"MUTATION VACUOUS: {MUTATE_ROW} plan_row CP-1->CP-99 did not "
              f"flip {SCRIPT} to nonzero")
        return 1
    print(f"mutation court: {MUTATE_ROW} plan_row CP-1->CP-99 flipped exit "
          f"{m.returncode} (nonzero, as required); restore byte-exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())

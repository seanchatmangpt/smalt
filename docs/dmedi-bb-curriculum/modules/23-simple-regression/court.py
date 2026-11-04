#!/usr/bin/env python3
"""Strict-bundle court wrapper, Module 23 (simple linear regression).

Thin wrapper over the registered derive court of record
(scripts/derive_keys.py: TSS witness, SST=SSR+SSE, sqrt(F)=|t|,
slope recovers 0.42). Real subprocess execution; asserts exit 0 and the
pinned check marker (manifest row states no numeric count; pinned to the
COURT PASS marker, loud-fail on drift), runs the mutation court (corrupt
one pinned data constant -> script must exit nonzero), and carries the
stale pre-adjudication 4.17 um sigma loud-fail over data/.

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
EXPECTED_CHECKS = 1           # pinned marker count: COURT PASS line
CHECK_PATTERN = re.compile(r"^COURT PASS", re.M)
STALE_SIGMA = "4.17"          # pre-adjudication regime; loud-fail if in data
MUTATE_FILE = "data/regression-simple.csv"
MUTATE_FIND = "11.44"         # run 1 bore_dev_um (unique)
MUTATE_REPL = "114.4"


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
                      f"{STALE_SIGMA} um regime; adjudicated spine is 7.407 um")
                return 1

    # -- 2. real run --------------------------------------------------------
    r = run_script()
    if r.returncode != 0:
        print(f"COURT FAIL: {SCRIPT} exit {r.returncode}\n{r.stdout}\n{r.stderr}")
        return 1
    n_checks = len(CHECK_PATTERN.findall(r.stdout))
    if n_checks != EXPECTED_CHECKS:
        print(f"CHECK-COUNT DRIFT FAIL: {SCRIPT} emitted {n_checks} markers; "
              f"court pins {EXPECTED_CHECKS}")
        return 1
    print(f"bundle: {SCRIPT} exit 0, COURT PASS marker green "
          f"({n_checks}/{EXPECTED_CHECKS})")

    # -- 3. mutation court ---------------------------------------------------
    before = sha256(MUTATE_FILE)
    with open(MUTATE_FILE, "rb") as f:
        body = f.read()
    occurrences = body.count(MUTATE_FIND.encode())
    if occurrences != 1:
        print(f"MUTATION SETUP FAIL: {MUTATE_FIND} occurs {occurrences}x "
              f"in {MUTATE_FILE} (expected exactly 1)")
        return 1
    with open(MUTATE_FILE, "wb") as f:
        f.write(body.replace(MUTATE_FIND.encode(), MUTATE_REPL.encode(), 1))
    try:
        m = run_script()
    finally:
        with open(MUTATE_FILE, "wb") as f:
            f.write(body)
    if sha256(MUTATE_FILE) != before:
        print("RESTORE FAIL: data file not byte-identical after mutation court")
        return 1
    if m.returncode == 0:
        print(f"MUTATION VACUOUS: corrupting {MUTATE_FIND} in {MUTATE_FILE} "
              f"did not flip {SCRIPT} to nonzero")
        return 1
    print(f"mutation court: {MUTATE_FIND} -> {MUTATE_REPL} flipped exit "
          f"{m.returncode} (nonzero, as required); restore byte-exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())

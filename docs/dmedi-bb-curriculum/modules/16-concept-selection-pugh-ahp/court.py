#!/usr/bin/env python3
"""Strict-bundle court wrapper, Module 16 (Pugh + AHP concept selection).

Thin wrapper over the registered derive court of record
(scripts/derive_selection.py, manifest row: exit 0 = 20/20 checks).
Real subprocess execution; asserts exit 0 AND the manifest-pinned check
count (loud-fail on drift), runs the mutation court (corrupt one pinned
data constant -> script must exit nonzero), and carries the stale
pre-adjudication 4.17 um sigma loud-fail over data/.

Usage: python3 court.py    (run from the module root)
"""
import glob
import hashlib
import os
import re
import subprocess
import sys

MODULE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = "scripts/derive_selection.py"
DATA_GLOB = "data/*.csv"
EXPECTED_CHECKS = 20          # manifest row: "exit 0 = 20/20 checks"
CHECK_PATTERN = re.compile(r"^\[PASS\]", re.M)
STALE_SIGMA = "4.17"          # pre-adjudication regime; loud-fail if in data
MUTATE_FILE = "data/concept_trials.csv"
MUTATE_FIND = "12.0121"       # A-citizen-regrind piece 1 bore_mm (unique)
MUTATE_REPL = "12.2012"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run_script():
    return subprocess.run([sys.executable, SCRIPT], cwd=MODULE,
                          capture_output=True, text=True)


def main():
    os.chdir(MODULE)

    # -- 1. stale-sigma loud-fail: data must not carry 4.17 um regime ------
    for path in sorted(glob.glob(DATA_GLOB)):
        with open(path, encoding="utf-8", errors="replace") as f:
            if STALE_SIGMA in f.read():
                print(f"STALE-SIGMA FAIL: {path} carries the retired "
                      f"{STALE_SIGMA} um regime; adjudicated spine is 7.407 um")
                return 1

    # -- 2. real run: exit 0 + pinned check count --------------------------
    r = run_script()
    if r.returncode != 0:
        print(f"COURT FAIL: {SCRIPT} exit {r.returncode}\n{r.stdout}\n{r.stderr}")
        return 1
    n_checks = len(CHECK_PATTERN.findall(r.stdout))
    if n_checks != EXPECTED_CHECKS:
        print(f"CHECK-COUNT DRIFT FAIL: {SCRIPT} emitted {n_checks} checks; "
              f"manifest pins {EXPECTED_CHECKS}")
        return 1
    print(f"bundle: {SCRIPT} exit 0, {n_checks}/{EXPECTED_CHECKS} checks green")

    # -- 3. mutation court: corrupt pinned constant -> nonzero -------------
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

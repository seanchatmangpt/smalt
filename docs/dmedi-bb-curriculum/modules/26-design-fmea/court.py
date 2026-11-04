#!/usr/bin/env python3
"""Strict-bundle court wrapper, Module 26 (DFMEA).

Thin wrapper over the registered derive court of record
(scripts/derive_keys.py: manifest row "exit 0 = 109 checks; re-derives
every RPN S x O x D, all 12 ranks, AP classes, S/O/D ranges,
no-post-worse-than-pre"). Real subprocess execution; asserts exit 0 AND
the manifest-pinned 109-check count (loud-fail on drift), runs the
mutation court (corrupt one pinned worksheet constant -> script must
exit nonzero), and carries the stale pre-adjudication 4.17 um sigma
loud-fail over data/.

Usage: python3 court.py    (run from the module root)
"""
import csv
import glob
import hashlib
import io
import os
import re
import subprocess
import sys

MODULE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = "scripts/derive_keys.py"
DATA_GLOB = "data/*.csv"
EXPECTED_CHECKS = 109         # manifest row: "exit 0 = 109 checks"
CHECK_PATTERN = re.compile(r"^PASS", re.M)
STALE_SIGMA = "4.17"          # pre-adjudication regime; loud-fail if in data
MUTATE_FILE = "data/dfmea-worksheet.csv"
MUTATE_MODE = "FM-01"
MUTATE_COLUMN = "severity"    # FM-01 S=10 -> RPN 360 pinned; 9 breaks it
MUTATE_FROM = "10"
MUTATE_TO = "9"


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
              f"manifest pins {EXPECTED_CHECKS}")
        return 1
    print(f"bundle: {SCRIPT} exit 0, {n_checks}/{EXPECTED_CHECKS} checks green")

    # -- 3. mutation court: FM-01 severity 10 -> 9 (RPN 360 -> 324) --------
    before = sha256(MUTATE_FILE)
    with open(MUTATE_FILE, "rb") as f:
        before_bytes = f.read()
    with open(MUTATE_FILE, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    hit = [rw for rw in rows if rw.get("mode_id") == MUTATE_MODE]
    if len(hit) != 1 or hit[0].get(MUTATE_COLUMN) != MUTATE_FROM:
        print(f"MUTATION SETUP FAIL: {MUTATE_MODE} / {MUTATE_COLUMN}="
              f"{MUTATE_FROM} not found uniquely in {MUTATE_FILE}")
        return 1
    hit[0][MUTATE_COLUMN] = MUTATE_TO
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=list(rows[0].keys()),
                            lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    with open(MUTATE_FILE, "w", encoding="utf-8", newline="") as f:
        f.write(buf.getvalue())
    try:
        m = run_script()
    finally:
        with open(MUTATE_FILE, "wb") as f:
            f.write(before_bytes)
    if sha256(MUTATE_FILE) != before:
        print("RESTORE FAIL: worksheet not byte-identical after mutation court")
        return 1
    if m.returncode == 0:
        print(f"MUTATION VACUOUS: {MUTATE_MODE} {MUTATE_COLUMN} "
              f"{MUTATE_FROM}->{MUTATE_TO} did not flip {SCRIPT} to nonzero")
        return 1
    print(f"mutation court: {MUTATE_MODE} {MUTATE_COLUMN} "
          f"{MUTATE_FROM}->{MUTATE_TO} flipped exit {m.returncode} "
          f"(nonzero, as required); restore byte-exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())

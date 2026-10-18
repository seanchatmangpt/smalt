#!/usr/bin/env python3
"""quiet_check — court precondition (v26.10.17, receipts/r240 lesson).

Fail-closed court precondition: refuses when the machine is not court-ready.
Checks (each can veto):
  1. No stray beam.smp processes holding court ports or running outside this
     checkout's own _build tree.
  2. Court ports (9443/8443/5672/5673/9444/9445) free.
  3. No concurrent mix test/court/substrate processes.
  4. Load average < ncpu * 1.0 (cold run-1 load faces fire above this).
Exit 0 quiet / 1 with a typed violation list.
"""

import os
import subprocess
import sys

COURT_PORTS = ["9443", "8443", "5672", "5673", "9444", "9445"]


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None


def main():
    violations = []

    beams = sh("ps -axo pid,command | grep '[b]eam.smp'")
    for line in (beams.stdout or "").splitlines():
        pid = line.strip().split(None, 1)
        if not pid:
            continue
        cwdp = sh("lsof -p %s 2>/dev/null | awk '$4==\"cwd\" {print $NF}'" % pid[0])
        cwd = (cwdp.stdout or "").strip() if cwdp else ""
        if cwd != os.getcwd():
            violations.append("stray beam pid %s cwd=%r (not this checkout)" % (pid[0], cwd))

    for port in COURT_PORTS:
        r = sh("lsof -iTCP:%s -sTCP:LISTEN" % port)
        if r and (r.stdout or "").strip():
            violations.append("court port %s occupied" % port)

    suites = sh("ps -axo command | grep -E '[m]ix (test|court)|[c]ourt_x2|[b]ench' | grep -v grep")
    if suites and (suites.stdout or "").strip():
        violations.append("concurrent suite/court processes: %s" % suites.stdout.strip()[:200])

    load1 = os.getloadavg()[0]
    ncpu = os.cpu_count() or 4
    if load1 > ncpu:
        violations.append(
            "load %.1f > %d cpus (cold run-1 load-face threshold)" % (load1, ncpu)
        )

    if violations:
        print("QUIET-CHECK REFUSE (typed violations):")
        for v in violations:
            print("  - " + v)
        return 1
    print("QUIET-CHECK: clear (beams ok, ports free, no concurrent suites, load %.1f < %d)" % (load1, ncpu))
    return 0


if __name__ == "__main__":
    sys.exit(main())

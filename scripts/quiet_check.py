#!/usr/bin/env python3
"""quiet_check — court precondition (v26.10.17, receipts/r240 lesson).

Fail-closed court precondition: refuses when the machine is not court-ready.
Checks (each can veto):
  1. No stray beam.smp processes holding court ports or running outside this
     checkout's own _build tree.
  2. Court ports (9443/8443/5672/5673/9444/9445) free.
  3. No concurrent mix test/court/substrate processes.
  4. Load gating: load1 > ncpu OR load5 > ncpu * 0.75 refuses.

Caveat: load gating guards machine-level load only. The r241 failure class
(async teardown race, fence-10 persistent flake) is NOT load-remediable;
quiet-check is not a proxy for court readiness on those faces.
Exit 0 quiet / 1 with a typed violation list.
"""

import json
import os
import socket
import subprocess
import sys
import time

COURT_PORTS = ["9443", "8443", "5672", "5673", "9444", "9445"]
ENV_GATE_JSONL = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "tmp", "env-gate.jsonl")
# machdep.xcpm.cpu_thermal_level: 0 = no throttling; >=1 = thermal pressure.
THERMAL_MAX = 0
# kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 3 critical.
MEM_PRESSURE_MAX = 2


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None


def _emit_env_rejected(load1, load5, thermal_level, mem_pressure, violations):
    """Append one ENV_REJECTED jsonl row on refusal (V2 audit)."""
    try:
        os.makedirs(os.path.dirname(ENV_GATE_JSONL), exist_ok=True)
        row = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "host": socket.gethostname(),
            "load1": round(load1, 2),
            "thermal_level": thermal_level,   # None = UNKNOWN-PROBE
            "mem_pressure": mem_pressure,     # None = UNKNOWN-PROBE
            "violations": violations,
        }
        with open(ENV_GATE_JSONL, "a") as f:
            f.write(json.dumps(row) + "\n")
    except OSError as e:
        print("quiet_check: failed to append %s: %s" % (ENV_GATE_JSONL, e),
              file=sys.stderr)


def main():
    violations = []

    beams = sh("ps -axo pid,command | grep '[b]eam.smp'")
    for line in (beams.stdout or "").splitlines():
        pid = line.strip().split(None, 1)
        if not pid:
            continue
        cwdp = sh("lsof -p %s 2>/dev/null | awk '$4==\"cwd\" {print $NF}'" % pid[0])
        cwd = (cwdp.stdout or "").strip() if cwdp else ""
        # Prefix match: a beam whose cwd is a subdir of this checkout (e.g.
        # deps/<pkg> after a dep compile) belongs to THIS checkout.
        if not (cwd == os.getcwd() or cwd.startswith(os.getcwd() + os.sep)):
            violations.append("stray beam pid %s cwd=%r (not this checkout)" % (pid[0], cwd))

    for port in COURT_PORTS:
        r = sh("lsof -iTCP:%s -sTCP:LISTEN" % port)
        if r and (r.stdout or "").strip():
            violations.append("court port %s occupied" % port)

    # Match only real suite processes (beam.smp running mix, or direct mix
    # invocations) — zsh -c harness wrappers carrying the words in their
    # command string self-matched and refused the gate spuriously
    # (witnessed: attempt-5 pre-check, 2026-10-18).
    # Exclude our own ancestry: the driver shell that invoked quiesce ->
    # quiet_check carries "court_x2.sh" in its command string and would
    # self-match (witnessed attempt-5 pre-check 2). Walk the parent chain.
    ancestry = set()
    pid = os.getpid()
    for _ in range(10):
        out = sh("ps -p %d -o ppid=" % pid)
        try:
            pid = int((out.stdout or "0").strip() or 0)
        except ValueError:
            break
        if pid <= 1:
            break
        ancestry.add(pid)
    suites = sh("ps -axo pid=,command | grep -E '[b]eam.smp.*mix (test|run)|^/opt/homebrew/bin/mix (test|court)|[c]ourt_x2.sh' | grep -v grep")
    if suites and suites.stdout:
        keep = []
        for line in suites.stdout.splitlines():
            try:
                if int(line.strip().split(None, 1)[0]) in ancestry:
                    continue
            except (ValueError, IndexError):
                pass
            keep.append(line)
        suites.stdout = "\n".join(keep)
    if suites and (suites.stdout or "").strip():
        violations.append("concurrent suite/court processes: %s" % suites.stdout.strip()[:200])

    load1, load5 = os.getloadavg()[:2]
    ncpu = os.cpu_count() or 4
    if load1 > ncpu or load5 > ncpu * 0.75:
        violations.append(
            "load %.1f/%.1f > threshold (%d cpus)" % (load1, load5, ncpu)
        )

    # Thermal + memory-pressure probes (V2 audit): load alone misses the
    # throttled/under-pressure machine. Absent key = typed UNKNOWN-PROBE
    # refusal (fail-closed), never a silent pass. No sudo-requiring probes.
    def sysctl_int(key):
        r = sh("sysctl -n %s" % key)
        out = (r.stdout or "").strip() if r else ""
        if r is None or r.returncode != 0 or not out:
            return None
        try:
            return int(out)
        except ValueError:
            return None

    thermal_level = sysctl_int("machdep.xcpm.cpu_thermal_level")
    mem_pressure = sysctl_int("kern.memorystatus_vm_pressure_level")
    if thermal_level is None:
        violations.append(
            "UNKNOWN-PROBE: machdep.xcpm.cpu_thermal_level unavailable "
            "(cannot verify thermal state; refusing, fail-closed)")
    elif thermal_level > THERMAL_MAX:
        violations.append(
            "thermal_level %d > %d (CPU thermal throttling active)"
            % (thermal_level, THERMAL_MAX))
    if mem_pressure is None:
        violations.append(
            "UNKNOWN-PROBE: kern.memorystatus_vm_pressure_level unavailable "
            "(cannot verify memory pressure; refusing, fail-closed)")
    elif mem_pressure > MEM_PRESSURE_MAX:
        violations.append(
            "mem_pressure_level %d > %d (system memory pressure)"
            % (mem_pressure, MEM_PRESSURE_MAX))

    if violations:
        _emit_env_rejected(load1, load5, thermal_level, mem_pressure, violations)
        print("QUIET-CHECK REFUSE (typed violations):")
        for v in violations:
            print("  - " + v)
        return 1
    print("QUIET-CHECK: clear (beams ok, ports free, no concurrent suites, load %.1f/%.1f < %d)" % (load1, load5, ncpu))
    return 0


if __name__ == "__main__":
    sys.exit(main())

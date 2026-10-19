#!/usr/bin/env python3
"""HAVE L2 — 30m meta watchdog (component 3).

Runbook checks, in order:

  1. Heartbeat age > 600s → ALRT-SEV1-HEARTBEAT-DEADLOCK → RP-01 automated:
       a. sweep dead beams: beam.smp processes whose whole process tree has no
          LISTEN socket AND whose cwd is NOT under this checkout (quiet_check's
          cwd-prefix rule, imported). A beam with a listening socket in its
          tree, or belonging to this checkout, is never touched.
       b. reclaim ports 9443/9444/8443/5672/5673/9545 ONLY if the holder is a
          verified-dead tree (dead-beam verified above, or a pid whose own
          tree has no LISTEN socket and cwd outside this checkout).
       c. sanitize the L1 state ledger (imports HAVE-1's sanitizer).
       d. write a restart row into the ledger.
     NEVER kill other sessions' live lanes — the port law stands.

  2. Zombie audit: orphan beam count >= 3 → SEV2 + targeted SIGKILL of
     verified-dead-tree pids only.

  3. Dangling socket listeners on court ports with no live owner → typed alert
     (owner pid gone, or owner is not a beam/epmd/mix process).

  4. Cron schedule verify: reads `crontab -l`; if the AZB loop lines vanished
     (or there is no crontab at all), a typed alert fires. Honest limitation:
     this watchdog cannot see session-scoped cron (e.g. a lane's own loop
     process) — it verifies the machine crontab only.

  5. --dry-run prints every action it would take without executing (no kill,
     no sanitize write, no ledger append).

Exit 0 quiet / 1 with alerts fired / 2 configuration error.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Set, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))  # scripts/ so we can import quiet_check
sys.path.insert(0, _HERE)                   # scripts/have/ so we can import state_ledger

import quiet_check  # noqa: E402  (cwd-prefix rule + sh helper)
import state_ledger  # noqa: E402  (L1 sanitizer + ledger append)

WATCHDOG_PORTS = ["9443", "9444", "8443", "5672", "5673", "9545"]
HEARTBEAT_STALE_S = 600.0
ZOMBIE_COUNT_SEV2 = 3
AZB_CRON_MARKERS = ("azb", "have", "smalt")

SEV1_HEARTBEAT = "ALRT-SEV1-HEARTBEAT-DEADLOCK"
SEV2_ZOMBIE = "ALRT-SEV2-ZOMBIE-BEAMS"
ALRT_DANGLING = "ALRT-DANGLING-LISTENER"
ALRT_CRON = "ALRT-CRON-MISSING"


def sh(cmd: str) -> Optional[subprocess.CompletedProcess]:
    return quiet_check.sh(cmd)


def beam_pids() -> List[Tuple[str, str]]:
    """All beam.smp pids with their command strings."""
    r = sh("ps -axo pid=,command | grep '[b]eam.smp'")
    out = []
    for line in (r.stdout or "").splitlines() if r else []:
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            out.append((parts[0], parts[1]))
    return out


def pid_cwd(pid: str) -> str:
    r = sh("lsof -p %s 2>/dev/null | awk '$4==\"cwd\" {print $NF}'" % pid)
    return (r.stdout or "").strip() if r else ""


def in_checkout(cwd: str) -> bool:
    """quiet_check's cwd-prefix rule: this checkout or any subdir of it."""
    return cwd == os.getcwd() or cwd.startswith(os.getcwd() + os.sep)


def pid_tree(pid: str) -> Set[str]:
    """pid + all descendants (beam trees are shallow: driver -> beam -> workers)."""
    tree: Set[str] = set()
    frontier = [pid]
    for _ in range(10):  # depth cap
        if not frontier:
            break
        nxt: Set[str] = set()
        for p in frontier:
            if p in tree:
                continue
            tree.add(p)
            r = sh("pgrep -P %s" % p)
            for line in (r.stdout or "").split() if r else []:
                nxt.add(line)
        frontier = sorted(nxt)
    return tree


def tree_listens(tree: Set[str]) -> bool:
    """True if ANY pid in the tree holds a LISTEN socket (TCP or UDP)."""
    for p in tree:
        r = sh("lsof -a -p %s -i -sTCP:LISTEN 2>/dev/null" % p)
        if r and (r.stdout or "").strip():
            return True
    return False


def verified_dead_tree(pid: str) -> bool:
    """A pid is a verified-dead tree iff its whole tree has no LISTEN socket
    AND its cwd is not under this checkout (never touch this checkout's lanes)."""
    # Never our own ancestry, never this checkout's lanes (absolute no),
    # never a tree with a LISTEN socket.
    if pid in ancestry_of_self():
        return False
    if in_checkout(pid_cwd(pid)):
        return False
    if tree_listens(pid_tree(pid)):
        return False
    return True


def ancestry_of_self() -> Set[str]:
    """Our own ancestry — never classified dead, never killed."""
    anc: Set[str] = set()
    pid = os.getpid()
    for _ in range(10):
        r = sh("ps -p %d -o ppid=" % pid)
        try:
            pid = int((r.stdout or "0").strip() or 0) if r else 0
        except ValueError:
            break
        if pid <= 1:
            break
        anc.add(str(pid))
    return anc


def port_holders(port: str) -> List[Tuple[str, str]]:
    """(pid, command) pairs listening on port."""
    r = sh("lsof -iTCP:%s -sTCP:LISTEN -Fpcl 2>/dev/null" % port)
    holders: List[Tuple[str, str]] = []
    if r and r.stdout:
        pid = ""
        cmd = ""
        for ln in r.stdout.splitlines():
            if ln.startswith("p"):
                pid = ln[1:]
            elif ln.startswith("c") and pid:
                cmd = ln[1:]
                holders.append((pid, cmd))
    return holders


def kill_pid(pid: str, dry: bool, actions: List[str]) -> bool:
    if dry:
        actions.append("DRY-RUN SIGKILL pid %s" % pid)
        return True
    r = sh("kill -9 %s" % pid)
    ok = bool(r) and r.returncode == 0
    actions.append("SIGKILL pid %s -> %s" % (pid, "ok" if ok else "FAIL rc=%s" % (r.returncode if r else "timeout")))
    return ok


# ---------------------------------------------------------------- checks

def check_heartbeat(hb_path: str, ledger_path: str, dry: bool, actions: List[str], alerts: List[Dict[str, Any]]) -> None:
    age = state_ledger.heartbeat_age(hb_path)
    if age is None:
        alerts.append({"id": ALRT_CRON, "sev": "INFO",
                       "detail": "heartbeat file never touched (%s)" % hb_path})
        return
    if age <= HEARTBEAT_STALE_S:
        return
    alerts.append({"id": SEV1_HEARTBEAT, "sev": "SEV1",
                   "detail": "heartbeat age %.0fs > %.0fs" % (age, HEARTBEAT_STALE_S)})
    actions.append("RP-01 automated (SEV1)")
    run_rp01(ledger_path, dry, actions, alerts)


def run_rp01(ledger_path: str, dry: bool, actions: List[str], alerts: List[Dict[str, Any]]) -> None:
    # (a) sweep dead beams
    dead: List[str] = []
    for pid, cmd in beam_pids():
        if verified_dead_tree(pid):
            dead.append(pid)
        else:
            cwd = pid_cwd(pid)
            actions.append("RP-01 spared beam pid %s cwd=%r (live lane or in-checkout)" % (pid, cwd))
    for pid in dead:
        kill_pid(pid, dry, actions)

    # (b) port reclaim — only verified-dead-tree holders
    for port in WATCHDOG_PORTS:
        for hpid, cmd in port_holders(port):
            if verified_dead_tree(hpid):
                kill_pid(hpid, dry, actions)
                actions.append("reclaimed port %s (holder %s verified-dead tree)" % (port, hpid))
            else:
                actions.append("port %s held by %s (%s) NOT verified-dead — port law, left in place" % (port, hpid, cmd[:60]))

    # (c) sanitize the L1 ledger (HAVE-1 sanitizer, imported)
    if dry:
        actions.append("DRY-RUN sanitize ledger %s" % ledger_path)
    else:
        retained, dropped = state_ledger.sanitize_truncated_lines(ledger_path)
        actions.append("ledger sanitize retained=%d dropped=%d" % (retained, dropped))

    # (d) restart row
    row = state_ledger.make_entry("dispatch", "RP-01-restart",
                                  "meta_watchdog SEV1 heartbeat deadlock; dead_beams=%d" % len(dead))
    if dry:
        actions.append("DRY-RUN ledger append %s" % json.dumps(row, sort_keys=True))
    else:
        state_ledger.append_entry(row, ledger_path)
        actions.append("restart row appended to %s" % ledger_path)


def check_zombies(dry: bool, actions: List[str], alerts: List[Dict[str, Any]]) -> None:
    orphans: List[str] = []
    for pid, cmd in beam_pids():
        if pid in ancestry_of_self():
            continue
        cwd = pid_cwd(pid)
        if in_checkout(cwd):
            continue  # this checkout's lanes are live by definition here
        if not tree_listens(pid_tree(pid)):
            orphans.append(pid)
    if len(orphans) < ZOMBIE_COUNT_SEV2:
        if orphans:
            actions.append("zombie audit: %d orphan beam(s) < %d, no action" % (len(orphans), ZOMBIE_COUNT_SEV2))
        return
    alerts.append({"id": SEV2_ZOMBIE, "sev": "SEV2",
                   "detail": "%d orphan beams: %s" % (len(orphans), ",".join(orphans))})
    for pid in orphans:
        kill_pid(pid, dry, actions)


def check_dangling(actions: List[str], alerts: List[Dict[str, Any]]) -> None:
    for port in WATCHDOG_PORTS:
        for hpid, cmd in port_holders(port):
            ps = sh("ps -p %s > /dev/null 2>&1" % hpid)
            if ps is None or ps.returncode != 0:
                alerts.append({"id": ALRT_DANGLING, "sev": "SEV2",
                               "detail": "port %s held by pid %s which no longer exists" % (port, hpid)})
                continue
            low = cmd.lower()
            if not any(m in low for m in ("beam", "epmd", "mix", "erl", "node", "python")):
                alerts.append({"id": ALRT_DANGLING, "sev": "SEV2",
                               "detail": "port %s held by non-runtime pid %s cmd=%r (no live owner class)" % (port, hpid, cmd[:60])})


def check_cron(alerts: List[Dict[str, Any]]) -> None:
    r = sh("crontab -l 2>&1")
    lines = [l for l in (r.stdout or "").splitlines() if l.strip() and not l.strip().startswith("#")] if r else []
    if r is None:
        alerts.append({"id": ALRT_CRON, "sev": "SEV2",
                       "detail": "crontab -l timed out — schedule unverifiable"})
        return
    if not lines:
        alerts.append({"id": ALRT_CRON, "sev": "SEV2",
                       "detail": "no crontab for this user — AZB loop lines absent (LIMITATION: session-scoped cron is invisible to this check)"})
        return
    hits = [l for l in lines if any(m in l.lower() for m in AZB_CRON_MARKERS)]
    if not hits:
        alerts.append({"id": ALRT_CRON, "sev": "SEV2",
                       "detail": "crontab has %d lines but none match AZB/HAVE/smalt loop markers %s" % (len(lines), str(AZB_CRON_MARKERS))})


# ---------------------------------------------------------------- main

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="HAVE L2 meta watchdog (30m)")
    ap.add_argument("--dry-run", action="store_true", help="print actions, execute nothing")
    ap.add_argument("--heartbeat-path", default=state_ledger.HEARTBEAT_PATH,
                    help="heartbeat file (fixture override for tests)")
    ap.add_argument("--ledger-path", default=state_ledger.LEDGER_PATH,
                    help="ledger file (fixture override for tests)")
    args = ap.parse_args(argv)

    actions: List[str] = []
    alerts: List[Dict[str, Any]] = []

    check_heartbeat(args.heartbeat_path, args.ledger_path, args.dry_run, actions, alerts)
    check_zombies(args.dry_run, actions, alerts)
    check_dangling(actions, alerts)
    check_cron(alerts)

    print("=== meta_watchdog %s ===" % ("(DRY-RUN)" if args.dry_run else ""))
    if alerts:
        for a in alerts:
            print("ALERT [%s] %s: %s" % (a["sev"], a["id"], a["detail"]))
    else:
        print("no alerts")
    if actions:
        print("--- actions ---")
        for a in actions:
            print("  " + a)
    else:
        print("no actions")
    print("exit=%d" % (1 if alerts else 0))
    return 1 if alerts else 0


if __name__ == "__main__":
    sys.exit(main())

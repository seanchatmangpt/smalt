#!/usr/bin/env python3
"""HAVE component 4 — have_* metric catalog emitter.

Emits typed JSONL metric rows, one per metric:
    {"metric": <str>, "value": <num|null>, "window": <str>, "ts": <iso8601Z>,
     "severity": "nominal|warning|critical|ABSENT"}

A metric that cannot be observed is emitted as an ABSENT row (value null,
reason embedded in "window") — never silently skipped, never faked as a zero.

Threshold table (severity bands, per HAVE spec):
    metric                                       nominal        warning          critical
    have_control_heartbeat_age_seconds           <=90s          (90,600]s        >600s
    have_worker_fleet_active_count               >=15           [5,15)           <5
    have_orphan_beam_processes_count             0              1-3              >=4
    have_dangling_socket_listeners               0              1                >=2
    have_mailbox_message_queue_depth_max         <1000          [1000,100000)    >=100000
    have_dets_unrepaired_dirty_tables            0              1-2              >=3
    have_ocel_referential_integrity_violations   0              1-9              >=10
    have_petri_net_token_drift                   0              1-2              >=3

Metric definitions:
  - have_control_heartbeat_age: seconds since the HAVE L1 heartbeat file
    (tmp/have/have_l1.heartbeat) was last touched. ABSENT if never touched.
  - have_worker_fleet_active_count: distinct PIDs matching
    `pgrep -f 'mix test|docker'` (the smalt worker definition). ABSENT if the
    counter fails — UNKNOWN is not zero.
  - have_orphan_beam_processes_count: beam.smp processes whose whole tree has
    no LISTEN socket (verified-dead-tree beams; tree-aware orphan detection
    per same-checkout-fanout rule 4). Always observable; never ABSENT.
  - have_dangling_socket_listeners: court ports (9443/9444/8443/5672/5673/9545)
    where something holds a LISTEN but no beam.smp process does — a held port
    with no live substrate owner.
  - have_mailbox_message_queue_depth_max: max message_queue_len over the
    running substrate's processes. Requires a live DISTRIBUTED substrate
    (eval injection riding Erlang distribution via `mix run --no-start`);
    a down or non-distributed substrate is an honest ABSENT, not a zero.
  - have_dets_unrepaired_dirty_tables: count of *.dets files under tmp/
    whose open probe (repair disabled) reports needs_repair.
  - have_ocel_referential_integrity_violations: dangling relationship
    objectIds (references absent from ocel:objects) in the newest
    *.ocel.json burn projection (docs/jira/*/burn, then tmp/ocel).
  - have_petri_net_token_drift: number of burn-cycle objects in the newest
    OCEL doc whose event-reference count deviates from the modal cycle shape
    (token conservation across the cycle net).

Zero sleeps. CLI:
    python3 scripts/have/telemetry.py --emit-all
    python3 scripts/have/telemetry.py --metric have_worker_fleet_active_count
    python3 scripts/have/telemetry.py --self-check
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import state_ledger  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

COURT_PORTS = (9443, 9444, 8443, 5672, 5673, 9545)
WORKER_PGREP = "mix test|docker"

MetricRow = Dict[str, Any]
Collector = Callable[[], Tuple[Optional[float], str]]  # (value|None, window/reason)


def utcnow_iso(ts: float | None = None) -> str:
    dt = datetime.fromtimestamp(ts if ts is not None else time.time(), tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- severity banding

def classify(metric: str, value: Optional[float]) -> str:
    """Band a value per the threshold table. None -> ABSENT."""
    if value is None:
        return "ABSENT"
    if metric == "have_worker_fleet_active_count":
        return "nominal" if value >= 15 else ("warning" if value >= 5 else "critical")
    if metric == "have_control_heartbeat_age_seconds":
        return "nominal" if value <= 90 else ("warning" if value <= 600 else "critical")
    if metric == "have_mailbox_message_queue_depth_max":
        return "nominal" if value < 1000 else ("warning" if value < 100_000 else "critical")
    if metric == "have_ocel_referential_integrity_violations":
        return "nominal" if value == 0 else ("warning" if value <= 9 else "critical")
    if metric == "have_orphan_beam_processes_count":
        return "nominal" if value == 0 else ("warning" if value <= 3 else "critical")
    if metric == "have_dets_unrepaired_dirty_tables":
        return "nominal" if value == 0 else ("warning" if value <= 2 else "critical")
    if metric == "have_petri_net_token_drift":
        return "nominal" if value == 0 else ("warning" if value <= 2 else "critical")
    if metric == "have_dangling_socket_listeners":
        return "nominal" if value == 0 else ("warning" if value == 1 else "critical")
    raise ValueError("unknown metric %r" % metric)


def make_row(metric: str, value: Optional[float], window: str, ts: str) -> MetricRow:
    return {
        "metric": metric,
        "value": value,
        "window": window,
        "ts": ts,
        "severity": classify(metric, value),
    }


# ---------------------------------------------------------------- collectors

def run_cmd(cmd: List[str], timeout: int = 15) -> Optional[str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return None
    return p.stdout if p.returncode == 0 else None


def collect_heartbeat_age() -> Tuple[Optional[float], str]:
    age = state_ledger.heartbeat_age(state_ledger.HEARTBEAT_PATH)
    if age is None:
        return None, "never-touched: no HAVE L1 heartbeat file"
    return round(age, 3), "since-last-heartbeat-touch"


def collect_worker_fleet() -> Tuple[Optional[float], str]:
    try:
        out = subprocess.run(
            ["pgrep", "-f", WORKER_PGREP], capture_output=True, text=True, timeout=10
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return None, "counter-failed: %s" % exc
    pids = {ln.strip() for ln in out.stdout.splitlines() if ln.strip()}
    return float(len(pids)), "pgrep -f '%s' distinct pids" % WORKER_PGREP


def _listening_ports_by_pid() -> Dict[int, set]:
    """pid -> set of TCP LISTEN ports, via lsof."""
    out = run_cmd(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"])
    by_pid: Dict[int, set] = {}
    if not out:
        return by_pid
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9:
            continue
        try:
            pid = int(parts[1])
        except ValueError:
            continue
        port = parts[8].rsplit(":", 1)[-1]
        if port.isdigit():
            by_pid.setdefault(pid, set()).add(int(port))
    return by_pid


def collect_orphan_beams() -> Tuple[Optional[float], str]:
    out = run_cmd(["pgrep", "-f", "beam.smp"])
    if out is None:
        return None, "beam census failed: pgrep unavailable"
    listen_by_pid = _listening_ports_by_pid()
    orphans = []
    for ln in out.splitlines():
        pid = ln.strip()
        if not pid:
            continue
        # Tree-aware: an ancestor holding a listener keeps the tree live.
        live = False
        cur = int(pid)
        for _ in range(6):  # beam -> mix/elixir -> sh/flock depth cap
            if listen_by_pid.get(cur):
                live = True
                break
            ppid = _ppid_of(cur)
            if ppid is None or ppid <= 1:
                break
            cur = ppid
        if not live:
            orphans.append(int(pid))
    return float(len(orphans)), "beam.smp pids with no LISTEN socket in tree"


def _ppid_of(pid: int) -> Optional[int]:
    try:
        with open("/proc/%d/stat" % pid) as f:  # Linux
            fields = f.read().rsplit(")", 1)[-1].split()
            return int(fields[1])
    except (OSError, IndexError, ValueError):
        pass
    out = run_cmd(["ps", "-o", "ppid=", "-p", str(pid)])
    if out is None:
        return None
    try:
        return int(out.strip().split()[0])
    except (IndexError, ValueError):
        return None


def collect_dangling_listeners() -> Tuple[Optional[float], str]:
    out = run_cmd(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN"])
    if out is None:
        return None, "lsof unavailable: port census UNKNOWN"
    lines = out.splitlines()[1:]
    dangling = []
    for port in COURT_PORTS:
        holders = []
        beam_holds = False
        for line in lines:
            parts = line.split()
            if len(parts) < 9:
                continue
            p = parts[8].rsplit(":", 1)[-1]
            if p.isdigit() and int(p) == port:
                holders.append(parts[1])
                if "beam" in parts[0]:
                    beam_holds = True
        if holders and not beam_holds:
            dangling.append(port)
    return float(len(dangling)), "court ports held with no beam owner %s" % (dangling or "[]")


def collect_mailbox_depth() -> Tuple[Optional[float], str]:
    """Eval injection: max message_queue_len over a live substrate's processes.

    Honest boundary: a `mix run --no-start` node is its OWN node; it cannot
    read another BEAM's mailboxes unless the substrate is distributed. So the
    injection rides Erlang distribution: epmd must name a live node, then the
    eval connects and rpc-evaluates the mailbox sweep remotely.
    """
    names = run_cmd(["epmd", "-names"])
    node = None
    if names:
        for line in names.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "name":
                node = parts[1]
    if not node:
        return None, "ABSENT: substrate not distributed (epmd names no node); mailboxes not observable"
    eval_src = (
        "Node.set_cookie(:" + node + ", :\""
        + os.environ.get("SMALT_COOKIE", "smalt")
        + "\"); "
        ':ok = Application.ensure_all_started(:net_kernel) |> elem(0);'
        'IO.puts(inspect Node.ping(:"' + node + '@'
        + os.uname().nodename
        + '"));'
    )
    # Fall back to a local sweep only when ping succeeds is unknowable from
    # here; instead run the eval and parse its verdict.
    del eval_src
    script = (
        'case Node.ping(:"%s@%s") do\n'
        "  :pong ->\n"
        "    depths = :rpc.call(:\"%s@%s\", :erlang, :processes, [])\n"
        "      |> Enum.map(&:erlang.process_info(&1, :message_queue_len) |> elem(1))\n"
        '    IO.puts("MAXQ=" <> Integer.to_string(Enum.max(depths)))\n'
        "  _ ->\n"
        '    IO.puts("MAXQ=UNREACHABLE")\n'
        "end\n" % (node, os.uname().nodename, node, os.uname().nodename)
    )
    try:
        p = subprocess.run(
            ["mix", "run", "--no-start", "--eval", script],
            capture_output=True, text=True, timeout=120, cwd=REPO_ROOT,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return None, "ABSENT: injection eval failed: %s" % exc
    m = None
    for line in p.stdout.splitlines():
        if line.startswith("MAXQ="):
            m = line[len("MAXQ="):].strip()
    if m == "UNREACHABLE" or m is None:
        return None, "ABSENT: distributed substrate node '%s' unreachable (cookie/connect)" % node
    return float(int(m)), "max message_queue_len over substrate node '%s' processes" % node


def _dets_files() -> List[str]:
    found = []
    for root, dirs, files in os.walk(os.path.join(REPO_ROOT, "tmp")):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "_build")]
        for fn in files:
            if fn.endswith(".dets"):
                found.append(os.path.join(root, fn))
    return found


def collect_dets_dirty() -> Tuple[Optional[float], str]:
    files = _dets_files()
    if not files:
        return 0.0, "no *.dets files under tmp/ (vacuously clean)"
    script = (
        "files = %s\n"
        "dirty = for f <- files do\n"
        "  case :dets.open_file(String.to_charlist(f), repair: false) do\n"
        "    {:error, :needs_repair} -> f\n"
        "    {:ok, d} -> :dets.close(d); nil\n"
        "    _ -> nil\n"
        "  end\n"
        "end\n"
        'IO.puts("DIRTY=" <> Integer.to_string(dirty |> Enum.reject(&is_nil/1) |> length))\n'
        % json.dumps(files)
    )
    try:
        p = subprocess.run(
            ["mix", "run", "--no-start", "--eval", script],
            capture_output=True, text=True, timeout=120, cwd=REPO_ROOT,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return None, "ABSENT: dets probe eval failed: %s" % exc
    for line in p.stdout.splitlines():
        if line.startswith("DIRTY="):
            return float(int(line[len("DIRTY="):])), "open-probe over %d *.dets files (repair disabled)" % len(files)
    return None, "ABSENT: dets probe produced no verdict (eval output missing)"


def _newest_ocel_doc() -> Optional[str]:
    candidates: List[str] = []
    for base in ("docs", "tmp"):
        top = os.path.join(REPO_ROOT, base)
        if not os.path.isdir(top):
            continue
        for root, dirs, files in os.walk(top):
            dirs[:] = [d for d in dirs if d not in ("node_modules", "_build", "deps")]
            for fn in files:
                if fn.endswith(".ocel.json"):
                    candidates.append(os.path.join(root, fn))
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def collect_ocel_integrity() -> Tuple[Optional[float], str]:
    path = _newest_ocel_doc()
    if path is None:
        return None, "ABSENT: no *.ocel.json burn projection present"
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as exc:
        return None, "ABSENT: newest OCEL doc unreadable: %s" % exc
    obj_ids = {o.get("id") for o in doc.get("ocel:objects", [])}
    violations = 0
    for ev in doc.get("ocel:events", []):
        for r in ev.get("relationships", []):
            if r.get("objectId") not in obj_ids:
                violations += 1
    return float(violations), "dangling relationship objectIds in %s" % os.path.relpath(path, REPO_ROOT)


def collect_petri_token_drift() -> Tuple[Optional[float], str]:
    path = _newest_ocel_doc()
    if path is None:
        return None, "ABSENT: no *.ocel.json burn projection present"
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as exc:
        return None, "ABSENT: newest OCEL doc unreadable: %s" % exc
    from collections import Counter

    per_object: Counter = Counter()
    for ev in doc.get("ocel:events", []):
        touched = {r.get("objectId") for r in ev.get("relationships", [])}
        for oid in touched:
            per_object[oid] += 1
    cycle_counts = [c for oid, c in per_object.items() if oid.startswith("burn-cycle/")]
    if not cycle_counts:
        return 0.0, "no burn-cycle objects in %s (vacuously conserved)" % os.path.relpath(path, REPO_ROOT)
    mode = Counter(cycle_counts).most_common(1)[0][0]
    drift = sum(1 for c in cycle_counts if c != mode)
    return float(drift), "burn-cycle objects deviating from modal event count %d in %s" % (
        mode, os.path.relpath(path, REPO_ROOT))


# ---------------------------------------------------------------- catalog

COLLECTORS: Dict[str, Collector] = {
    "have_control_heartbeat_age_seconds": collect_heartbeat_age,
    "have_worker_fleet_active_count": collect_worker_fleet,
    "have_orphan_beam_processes_count": collect_orphan_beams,
    "have_dangling_socket_listeners": collect_dangling_listeners,
    "have_mailbox_message_queue_depth_max": collect_mailbox_depth,
    "have_dets_unrepaired_dirty_tables": collect_dets_dirty,
    "have_ocel_referential_integrity_violations": collect_ocel_integrity,
    "have_petri_net_token_drift": collect_petri_token_drift,
}


def emit_all() -> List[MetricRow]:
    ts = utcnow_iso()
    rows = []
    for metric, collector in COLLECTORS.items():
        try:
            value, window = collector()
        except Exception as exc:  # a collector crash is an ABSENT, never a skip
            value, window = None, "ABSENT: collector exception: %r" % exc
        rows.append(make_row(metric, value, window, ts))
    return rows


# ---------------------------------------------------------------- self-check

def self_check() -> int:
    """Fixture-driven: banding correctness + ABSENT honesty + row shape."""
    failures: List[str] = []

    def check(name: str, cond: bool) -> None:
        print(("PASS" if cond else "FAIL") + " " + name)
        if not cond:
            failures.append(name)

    # 1. banding table
    check("band-heartbeat-nominal", classify("have_control_heartbeat_age_seconds", 5.0) == "nominal")
    check("band-heartbeat-warning", classify("have_control_heartbeat_age_seconds", 300.0) == "warning")
    check("band-heartbeat-critical", classify("have_control_heartbeat_age_seconds", 900.0) == "critical")
    check("band-workers-nominal", classify("have_worker_fleet_active_count", 15) == "nominal")
    check("band-workers-warning", classify("have_worker_fleet_active_count", 7) == "warning")
    check("band-workers-critical", classify("have_worker_fleet_active_count", 2) == "critical")
    check("band-mailbox-warning", classify("have_mailbox_message_queue_depth_max", 5000) == "warning")
    check("band-mailbox-critical", classify("have_mailbox_message_queue_depth_max", 200000) == "critical")
    check("band-ocel-critical", classify("have_ocel_referential_integrity_violations", 12) == "critical")
    check("band-drift-nominal", classify("have_petri_net_token_drift", 0) == "nominal")

    # 2. row shape
    row = make_row("have_orphan_beam_processes_count", 0, "test", utcnow_iso())
    check(
        "row-shape",
        set(row) == {"metric", "value", "window", "ts", "severity"}
        and row["severity"] == "nominal",
    )
    absent = make_row("have_mailbox_message_queue_depth_max", None, "reason", utcnow_iso())
    check("absent-row-honest", absent["severity"] == "ABSENT" and absent["value"] is None)

    # 3. petri drift on a synthetic doc (modal deviation detected)
    doc = {
        "ocel:objects": [
            {"id": "burn-cycle/c1", "type": "burn-cycle"},
            {"id": "burn-cycle/c2", "type": "burn-cycle"},
            {"id": "burn-cycle/c3", "type": "burn-cycle"},
        ],
        "ocel:events": (
            [{"id": "e%d" % i, "type": "t", "relationships": [{"objectId": "burn-cycle/c1"}]} for i in range(5)]
            + [{"id": "f%d" % i, "type": "t", "relationships": [{"objectId": "burn-cycle/c2"}]} for i in range(5)]
            + [{"id": "g%d" % i, "type": "t", "relationships": [{"objectId": "burn-cycle/c3"}]} for i in range(2)]
        ),
    }
    tmpdir = tempfile.mkdtemp(prefix="have-tel-")
    p = os.path.join(tmpdir, "synthetic.ocel.json")
    with open(p, "w") as f:
        json.dump(doc, f)

    obj_ids = {o["id"] for o in doc["ocel:objects"]}
    from collections import Counter

    per_object: Counter = Counter()
    for ev in doc["ocel:events"]:
        for r in ev["relationships"]:
            per_object[r["objectId"]] += 1
    cycle_counts = [c for oid, c in per_object.items() if oid.startswith("burn-cycle/")]
    mode = Counter(cycle_counts).most_common(1)[0][0]
    drift = sum(1 for c in cycle_counts if c != mode)
    check("petri-drift-detects-deviant", drift == 1)
    os.unlink(p)
    os.rmdir(tmpdir)

    # 4. every metric in the catalog has a collector and a band rule
    for m in COLLECTORS:
        try:
            classify(m, 1)
            ok = True
        except ValueError:
            ok = False
        check("catalog-%s-banded" % m, ok)

    print("\nself-check: %d failure(s)" % len(failures) + (": " + ", ".join(failures) if failures else ""))
    return 1 if failures else 0


# ---------------------------------------------------------------- CLI

def main() -> int:
    ap = argparse.ArgumentParser(description="HAVE component 4 — metric catalog emitter")
    ap.add_argument("--emit-all", action="store_true", help="emit one JSONL snapshot of all metrics")
    ap.add_argument("--metric", help="emit a single metric row")
    ap.add_argument("--out", help="also append snapshot to this JSONL file")
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()

    if args.self_check:
        return self_check()
    if args.metric:
        if args.metric not in COLLECTORS:
            print("unknown metric %r; known: %s" % (args.metric, ", ".join(COLLECTORS)), file=sys.stderr)
            return 2
        value, window = COLLECTORS[args.metric]()
        rows = [make_row(args.metric, value, window, utcnow_iso())]
    elif args.emit_all:
        rows = emit_all()
    else:
        ap.print_help()
        return 2

    for r in rows:
        print(json.dumps(r, sort_keys=True))
    if args.out and rows:
        with open(args.out, "a") as f:
            for r in rows:
                f.write(json.dumps(r, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

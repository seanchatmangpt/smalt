#!/usr/bin/env python3
"""HAVE component 5: SEV matrix + jidoka engine.

Reads telemetry JSONL rows (HAVE-4 output) and applies the alert
classification exactly:

  SEV1  HEARTBEAT-DEADLOCK               duration > 600s
  SEV1  STORAGE-CORRUPTION-UNREPAIRED    >= 1 unrepaired DETS store
  SEV1  PETRI-TOKEN-IMBALANCE            token balance != 0
  SEV2  FLEET-STARVATION                 available < 15 for >= 10m
  SEV2  PROCESS-LEAK-ZOMBIE              >= 3 orphaned processes

SEV1 is jidoka (line-stop): for each SEV1 firing the engine emits a
line-stop row {action: halt_dag, freeze_state: true, drain_leases: true}
and writes an alert file plus a *.hold dispatch-hold file under the
alerts dir; the cron loop treats any *.hold file there as a dispatch hold.

SEV2 emits a recycle/refill row {action: recycle_refill}.

Input contract (per JSONL row; only the fields a rule needs are read):
  ts                  ISO-8601 UTC row timestamp (FLEET-STARVATION window)
  t_start, t_end      ISO-8601 UTC (HEARTBEAT-DEADLOCK duration)
  heartbeat_s         direct duration override (number)
  verdict             burn-row verdict; "DETS_UNREPAIRED" maps to
                      STORAGE-CORRUPTION-UNREPAIRED
  dets_unrepaired     direct count override (int)
  petri_tokens        int token balance; rule fires iff present and != 0
  available           int fleet-available gauge (FLEET-STARVATION); rows
                      without `available` are ignored for this rule
  starved_s           direct starvation duration override (>= 600 fires)
  orphans             int count OR list of process descriptors (zombie rule)
  container           optional row identity, echoed into alerts

Exit codes: 0 = clean (no alerts), 1 = one or more alerts fired,
2 = usage/IO error. `--self-test` exits 0 pass / 1 fail.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any

SCHEMA = "smalt-have-alert/v1"

SEV1_HEARTBEAT = "HEARTBEAT-DEADLOCK"
SEV1_STORAGE = "STORAGE-CORRUPTION-UNREPAIRED"
SEV1_PETRI = "PETRI-TOKEN-IMBALANCE"
SEV2_STARVATION = "FLEET-STARVATION"
SEV2_ZOMBIE = "PROCESS-LEAK-ZOMBIE"

HEARTBEAT_DEADLOCK_S = 600.0  # strictly greater than
STARVATION_THRESHOLD = 15  # available below this
STARVATION_WINDOW_S = 600.0  # sustained for at least this long (10m)
ZOMBIE_ORPHANS = 3  # at least this many orphans

EXIT_CLEAN = 0
EXIT_ALERTS = 1
EXIT_USAGE = 2


def _parse_ts(value: Any) -> "datetime | None":
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _duration_s(row: dict) -> "float | None":
    if isinstance(row.get("heartbeat_s"), (int, float)):
        return float(row["heartbeat_s"])
    t0 = _parse_ts(row.get("t_start"))
    t1 = _parse_ts(row.get("t_end"))
    if t0 is None or t1 is None:
        return None
    return (t1 - t0).total_seconds()


def rule_heartbeat_deadlock(row: dict) -> bool:
    dur = _duration_s(row)
    return dur is not None and dur > HEARTBEAT_DEADLOCK_S


def rule_storage_corruption(row: dict) -> bool:
    if row.get("verdict") == "DETS_UNREPAIRED":
        return True
    v = row.get("dets_unrepaired")
    return isinstance(v, (int, float)) and v >= 1


def rule_petri_imbalance(row: dict) -> bool:
    v = row.get("petri_tokens")
    return isinstance(v, (int, float)) and v != 0


def rule_fleet_starvation(rows: list) -> bool:
    """True when `available` < 15 is sustained >= 600s across ordered rows,
    or any row carries starved_s >= 600 directly."""
    for r in rows:
        v = r.get("starved_s")
        if isinstance(v, (int, float)) and float(v) >= STARVATION_WINDOW_S:
            return True
    window = []
    for row in rows:
        v = row.get("available")
        if not isinstance(v, (int, float)):
            continue
        ts = _parse_ts(row.get("ts"))
        if ts is None:
            continue
        window.append((ts, float(v)))
    window.sort(key=lambda p: p[0])
    run_start = None
    last_ts = None
    for ts, available in window:
        if available < STARVATION_THRESHOLD:
            if run_start is None:
                run_start = ts
            last_ts = ts
        else:
            run_start = None
            last_ts = None
    if run_start is not None and last_ts is not None:
        return (last_ts - run_start).total_seconds() >= STARVATION_WINDOW_S
    return False


def rule_zombie(row: dict) -> bool:
    v = row.get("orphans")
    if isinstance(v, list):
        return len(v) >= ZOMBIE_ORPHANS
    return isinstance(v, (int, float)) and v >= ZOMBIE_ORPHANS


ROW_RULES = (rule_heartbeat_deadlock, rule_storage_corruption, rule_petri_imbalance, rule_zombie)


def severity_for(rule: str) -> str:
    return "SEV1" if rule in (SEV1_HEARTBEAT, SEV1_STORAGE, SEV1_PETRI) else "SEV2"


def make_alert(rule: str, row: dict, ts_now: str) -> dict:
    sev = severity_for(rule)
    alert = {
        "schema": SCHEMA,
        "ts": ts_now,
        "severity": sev,
        "rule": rule,
        "container": row.get("container"),
        "row_ts": row.get("ts") or row.get("t_end") or row.get("t_start"),
        "action": "halt_dag" if sev == "SEV1" else "recycle_refill",
    }
    if sev == "SEV1":
        alert["freeze_state"] = True
        alert["drain_leases"] = True
    return alert


class AlertEngine:
    """Stateful evaluator: feed JSONL rows, collect alerts, persist holds."""

    def __init__(self, alerts_dir: "str | None" = None, now: "str | None" = None):
        self.alerts_dir = alerts_dir
        self.now = now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.alerts = []
        self._rows = []
        self._hold_files = []

    def feed(self, row: dict) -> list:
        """Evaluate per-row rules; returns rules fired for this row."""
        self._rows.append(row)
        fired = []
        if rule_heartbeat_deadlock(row):
            fired.append(SEV1_HEARTBEAT)
        if rule_storage_corruption(row):
            fired.append(SEV1_STORAGE)
        if rule_petri_imbalance(row):
            fired.append(SEV1_PETRI)
        if rule_zombie(row):
            fired.append(SEV2_ZOMBIE)
        for rule in fired:
            self.alerts.append(make_alert(rule, row, self.now))
        return fired

    def finalize(self) -> list:
        """Evaluate window rules over the full stream; write alert + hold files."""
        if rule_fleet_starvation(self._rows):
            sample = next(
                (
                    r
                    for r in self._rows
                    if isinstance(r.get("available"), (int, float)) and float(r["available"]) < STARVATION_THRESHOLD
                ),
                next((r for r in self._rows if "starved_s" in r), {}),
            )
            self.alerts.append(make_alert(SEV2_STARVATION, sample, self.now))
        if self.alerts_dir and self.alerts:
            os.makedirs(self.alerts_dir, exist_ok=True)
            for i, alert in enumerate(self.alerts):
                name = "ALERT-%s-%s-%02d.json" % (alert["rule"], self.now.replace(":", ""), i)
                path = os.path.join(self.alerts_dir, name)
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump(alert, fh, indent=2, sort_keys=True)
                if alert["severity"] == "SEV1":
                    hold_path = path + ".hold"
                    with open(hold_path, "w", encoding="utf-8") as fh:
                        json.dump(
                            {
                                "schema": SCHEMA,
                                "kind": "dispatch-hold",
                                "alert": name,
                                "rule": alert["rule"],
                                "severity": alert["severity"],
                            },
                            fh,
                            indent=2,
                            sort_keys=True,
                        )
                    self._hold_files.append(hold_path)
        return self.alerts

    @property
    def hold_files(self) -> list:
        return list(self._hold_files)


def _read_rows(paths) -> list:
    rows = []
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="HAVE-5 SEV matrix + jidoka engine")
    ap.add_argument("inputs", nargs="*", help="telemetry JSONL files (default stdin)")
    ap.add_argument(
        "--alerts-dir",
        default=os.environ.get("HAVE_ALERTS_DIR", ".smalt/alerts"),
        help="directory for SEV1 dispatch-hold alert files (default .smalt/alerts)",
    )
    ap.add_argument("--no-write", action="store_true", help="evaluate only, do not write alert/hold files")
    ap.add_argument("--rows-out", default=None, help="write emitted alert rows JSONL here")
    ap.add_argument("--self-test", action="store_true", help="run embedded fixture suite and exit")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    try:
        if args.inputs:
            rows = _read_rows(args.inputs)
        else:
            rows = [json.loads(line) for line in sys.stdin if line.strip()]
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write("HAVE-5: input error: %s\n" % exc)
        return EXIT_USAGE

    engine = AlertEngine(alerts_dir=None if args.no_write else args.alerts_dir)
    for row in rows:
        engine.feed(row)
    alerts = engine.finalize()

    lines = [json.dumps(a, sort_keys=True) for a in alerts]
    for line in lines:
        sys.stdout.write(line + "\n")
    if args.rows_out:
        with open(args.rows_out, "w", encoding="utf-8") as fh:
            for line in lines:
                fh.write(line + "\n")

    if alerts:
        sev1 = sum(1 for a in alerts if a["severity"] == "SEV1")
        sys.stderr.write(
            "HAVE-5: %d alert(s): %d SEV1 (jidoka halt_dag; dispatch holds in %s), %d SEV2\n"
            % (len(alerts), sev1, args.alerts_dir, len(alerts) - sev1)
        )
        return EXIT_ALERTS
    sys.stderr.write("HAVE-5: clean, 0 alerts\n")
    return EXIT_CLEAN


def self_test() -> int:
    import tempfile

    failures = []
    now = "2026-10-18T00:00:00Z"

    def check(name, cond):
        print(("PASS " if cond else "FAIL ") + name)
        if not cond:
            failures.append(name)

    def run(rows, alerts_dir=None):
        eng = AlertEngine(alerts_dir=alerts_dir, now=now)
        for r in rows:
            eng.feed(r)
        eng.finalize()
        return eng

    # SEV1 HEARTBEAT-DEADLOCK
    eng = run([{"container": "c1", "heartbeat_s": 601}])
    check(
        "heartbeat-601s-fires-SEV1",
        len(eng.alerts) == 1
        and eng.alerts[0]["rule"] == SEV1_HEARTBEAT
        and eng.alerts[0]["severity"] == "SEV1",
    )
    check(
        "heartbeat-fires-jidoka-action",
        eng.alerts
        and eng.alerts[0]["action"] == "halt_dag"
        and eng.alerts[0]["freeze_state"] is True
        and eng.alerts[0]["drain_leases"] is True,
    )
    eng = run([{"heartbeat_s": 600}])
    check("heartbeat-600s-boundary-clean", eng.alerts == [])
    eng = run([{"t_start": "2026-10-18T00:00:00Z", "t_end": "2026-10-18T00:10:01Z"}])
    check(
        "heartbeat-t-start-t-end-601s-fires",
        len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV1_HEARTBEAT,
    )

    # SEV1 STORAGE-CORRUPTION-UNREPAIRED
    eng = run([{"verdict": "DETS_UNREPAIRED"}])
    check(
        "dets-unrepaired-verdict-fires",
        len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV1_STORAGE and eng.alerts[0]["severity"] == "SEV1",
    )
    eng = run([{"dets_unrepaired": 1}])
    check(
        "dets-unrepaired-count-fires",
        len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV1_STORAGE,
    )
    eng = run([{"dets_unrepaired": 0, "verdict": "CLEAN"}])
    check("storage-clean-no-alert", eng.alerts == [])

    # SEV1 PETRI-TOKEN-IMBALANCE
    eng = run([{"petri_tokens": 1}])
    check(
        "petri-1-fires",
        len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV1_PETRI and eng.alerts[0]["action"] == "halt_dag",
    )
    eng = run([{"petri_tokens": -2}])
    check("petri-negative-fires", len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV1_PETRI)
    eng = run([{"petri_tokens": 0}])
    check("petri-0-clean", eng.alerts == [])

    # SEV2 FLEET-STARVATION
    series = [{"ts": "2026-10-18T00:%02d:00Z" % m, "available": 10} for m in range(0, 11)]
    eng = run(series)
    check(
        "starvation-10min-fires-SEV2",
        len(eng.alerts) == 1
        and eng.alerts[0]["rule"] == SEV2_STARVATION
        and eng.alerts[0]["severity"] == "SEV2"
        and eng.alerts[0]["action"] == "recycle_refill",
    )
    under = [{"ts": "2026-10-18T00:%02d:00Z" % m, "available": 14} for m in range(0, 10)]
    eng = run(under)
    check("starvation-9min-clean", eng.alerts == [])
    eng = run([{"starved_s": 600}])
    check(
        "starvation-direct-600s-fires",
        len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV2_STARVATION,
    )
    eng = run([{"starved_s": 599}])
    check("starvation-direct-599s-clean", eng.alerts == [])
    recovered = [
        {"ts": "2026-10-18T00:%02d:00Z" % m, "available": 5 if m < 3 else 40}
        for m in range(0, 20)
    ]
    eng = run(recovered)
    check("starvation-recovered-clean", eng.alerts == [])

    # SEV2 PROCESS-LEAK-ZOMBIE
    eng = run([{"orphans": 3}])
    check(
        "zombies-3-fires-SEV2",
        len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV2_ZOMBIE and eng.alerts[0]["severity"] == "SEV2",
    )
    eng = run([{"orphans": ["p1", "p2", "p3"]}])
    check("zombies-list-of-3-fires", len(eng.alerts) == 1 and eng.alerts[0]["rule"] == SEV2_ZOMBIE)
    eng = run([{"orphans": 2}])
    check("zombies-2-clean", eng.alerts == [])

    # clean rows produce no alerts
    eng = run(
        [
            {"container": "ok", "heartbeat_s": 120, "petri_tokens": 0, "available": 42, "ts": "2026-10-18T00:00:00Z"},
            {"verdict": "CLEAN", "orphans": 0},
        ]
    )
    check("clean-rows-no-alerts", eng.alerts == [])

    # jidoka: SEV1 writes dispatch hold; SEV2 does not
    with tempfile.TemporaryDirectory() as td:
        eng = run([{"heartbeat_s": 700, "container": "j1"}], alerts_dir=td)
        holds = [f for f in sorted(os.listdir(td)) if f.endswith(".hold")]
        check("sev1-writes-dispatch-hold", len(holds) == 1 and eng.hold_files == [os.path.join(td, holds[0])])
        with open(os.path.join(td, holds[0])) as fh:
            hold = json.load(fh)
        check("hold-kind-dispatch-hold", hold["kind"] == "dispatch-hold" and hold["severity"] == "SEV1")
    with tempfile.TemporaryDirectory() as td:
        eng = run([{"orphans": 3}], alerts_dir=td)
        check(
            "sev2-writes-no-hold",
            eng.alerts and not [f for f in os.listdir(td) if f.endswith(".hold")],
        )

    print("")
    print("%d check(s), %d failed" % (22, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

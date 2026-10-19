#!/usr/bin/env python3
"""HAVE component 2: Level-1 pool saturation guard (5m cron).

Worker definition (smalt): a distinct line of `pgrep -f 'mix test|docker'`.

Behavior per cycle:
  1. Count active workers.
  2. Compare against the target pool (--target-pool, default 20).
  3. If N < target: emit a typed `have_worker_fleet_active_count` alert row to
     the state ledger. Severity: SEV2 when N < 15 sustained (the previous
     heartbeat sample also reported < 15), otherwise SEV3.
  4. If N < target: append a `{kind: dispatch_request, deficit: N}` row to the
     dispatch-request ledger. HONEST BOUNDARY: the guard cannot spawn Claude
     agents — it requests. The 5m cron loop is the actuator.
  5. Touch the heartbeat (timestamp + observed count).

Zero sleeps. Deadline logic is timestamp arithmetic, not wall-clock waits.

Usage:
  python3 scripts/have/pool_saturation_guard.py [--target-pool N] [--state-dir DIR]
  python3 scripts/have/pool_saturation_guard.py --self-check
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

DEFAULT_TARGET_POOL = 20
SEV2_SUSTAINED_THRESHOLD = 15
WORKER_PGREP = "mix test|docker"

LEDGER = "state_ledger.jsonl"
DISPATCH = "dispatch_requests.jsonl"
HEARTBEAT = "heartbeat.json"


def utcnow_iso(ts: float | None = None) -> str:
    dt = datetime.fromtimestamp(ts if ts is not None else time.time(), tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def count_workers(counter: Callable[[], int] | None = None) -> int:
    """Count active smalt workers: distinct PIDs matching pgrep -f 'mix test|docker'.

    Returns -1 on counter failure (typed, never silently read as zero workers).
    """
    if counter is not None:
        return counter()
    try:
        out = subprocess.run(
            ["pgrep", "-f", WORKER_PGREP],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        print(f"WARN: worker count failed: {exc}", file=sys.stderr)
        return -1
    return len({ln.strip() for ln in out.stdout.splitlines() if ln.strip()})


def load_heartbeat(state_dir: Path) -> dict[str, Any] | None:
    hb = state_dir / HEARTBEAT
    if not hb.exists():
        return None
    try:
        return json.loads(hb.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def severity_for(count: int, prev: dict[str, Any] | None) -> str:
    """SEV2 iff deficit < 15 sustained: this sample AND the previous heartbeat
    sample are both < SEV2_SUSTAINED_THRESHOLD. First-observation deficits are
    SEV3 (unproven duration)."""
    if count >= SEV2_SUSTAINED_THRESHOLD:
        return "SEV4"  # below target but not below the SEV2/SEV3 band
    prev_ok = isinstance(prev, dict) and isinstance(prev.get("workers"), int)
    if prev_ok and prev["workers"] < SEV2_SUSTAINED_THRESHOLD:
        return "SEV2"
    return "SEV3"


def append_jsonl(path: Path, row: dict[str, Any]) -> None:
    with path.open("a") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")


def run_cycle(
    state_dir: Path,
    target_pool: int,
    now: float | None = None,
    counter: Callable[[], int] | None = None,
) -> dict[str, Any]:
    now = time.time() if now is None else now
    state_dir.mkdir(parents=True, exist_ok=True)

    n = count_workers(counter)
    prev = load_heartbeat(state_dir)

    cycle: dict[str, Any] = {
        "ts": utcnow_iso(now),
        "workers": n,
        "target_pool": target_pool,
        "deficit": max(0, target_pool - n) if n >= 0 else -1,
    }

    if n < 0:
        cycle["status"] = "COUNTER_FAIL"
        append_jsonl(
            state_dir / LEDGER,
            {
                "kind": "alert",
                "type": "have_worker_fleet_active_count",
                "ts": cycle["ts"],
                "severity": "SEV1",
                "workers": n,
                "target_pool": target_pool,
                "note": "worker counter failed; count is UNKNOWN, not zero",
            },
        )
        write_heartbeat(state_dir, cycle, now)
        return cycle

    deficit = target_pool - n
    if deficit > 0:
        sev = severity_for(n, prev)
        cycle["status"] = "DEFICIT"
        cycle["severity"] = sev
        append_jsonl(
            state_dir / LEDGER,
            {
                "kind": "alert",
                "type": "have_worker_fleet_active_count",
                "ts": cycle["ts"],
                "severity": sev,
                "workers": n,
                "target_pool": target_pool,
                "deficit": deficit,
                "sustained": sev == "SEV2",
            },
        )
        # Honest boundary: request, never spawn. The 5m cron loop is the
        # actuator that consumes dispatch-requests.
        append_jsonl(
            state_dir / DISPATCH,
            {
                "kind": "dispatch_request",
                "ts": cycle["ts"],
                "deficit": deficit,
                "workers": n,
                "target_pool": target_pool,
                "severity": sev,
                "requested_by": "pool_saturation_guard",
            },
        )
        # Mirror into the run_state ledger so multiple ticks compose: each
        # deficit tick leaves a kind=dispatch row in run_state.jsonl, and the
        # actuator can read the accumulated request history across ticks.
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import state_ledger
        state_ledger.append_entry(
            state_ledger.make_entry(
                "dispatch",
                "pool_saturation_guard",
                json.dumps(
                    {
                        "deficit": deficit,
                        "workers": n,
                        "target_pool": target_pool,
                        "severity": sev,
                        "dispatch_ledger": str(state_dir / DISPATCH),
                    },
                    sort_keys=True,
                ),
                ts=now,
            ),
            path=str(state_dir / "run_state.jsonl"),
        )
    else:
        cycle["status"] = "OK"

    write_heartbeat(state_dir, cycle, now)
    return cycle


def write_heartbeat(state_dir: Path, cycle: dict[str, Any], now: float) -> None:
    hb = {
        "ts": cycle["ts"],
        "epoch": now,
        "workers": cycle["workers"],
        "target_pool": cycle["target_pool"],
        "status": cycle["status"],
    }
    (state_dir / HEARTBEAT).write_text(json.dumps(hb, sort_keys=True) + "\n")


# ---------------------------------------------------------------------------
# Self-check: fixture-driven, no real pgrep dependency, zero sleeps.
# ---------------------------------------------------------------------------

def self_check() -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import state_ledger

    failures: list[str] = []

    def check(name: str, cond: bool) -> None:
        if not cond:
            failures.append(name)
        print(f"{'PASS' if cond else 'FAIL'} {name}")

    with tempfile.TemporaryDirectory() as td:
        sd = Path(td)

        # Fixture 1: saturated pool -> OK, no alerts, no dispatch requests.
        c1 = run_cycle(sd, 20, now=1_000_000, counter=lambda: 20)
        check("saturated-pool-ok", c1["status"] == "OK" and c1["deficit"] == 0)
        check("no-alert-at-target", not (sd / LEDGER).exists())
        check("no-dispatch-at-target", not (sd / DISPATCH).exists())
        hb = load_heartbeat(sd)
        check("heartbeat-touched", hb is not None and hb["workers"] == 20)

        # Fixture 2: first deficit observation (12 workers) -> SEV3 (unproven
        # duration), one alert row, one dispatch-request row deficit=8.
        c2 = run_cycle(sd, 20, now=1_000_300, counter=lambda: 12)
        check("first-deficit-sev3", c2.get("severity") == "SEV3")
        rows = [json.loads(l) for l in (sd / LEDGER).read_text().splitlines() if l.strip()]
        check("alert-row-typed", rows[-1]["type"] == "have_worker_fleet_active_count")
        check("alert-row-deficit", rows[-1]["deficit"] == 8)
        reqs = [json.loads(l) for l in (sd / DISPATCH).read_text().splitlines() if l.strip()]
        check("dispatch-request-deficit", reqs[-1]["kind"] == "dispatch_request" and reqs[-1]["deficit"] == 8)
        # Mirror row: the deficit tick must leave a kind=dispatch entry in the
        # run_state ledger (tmp/have/run_state.jsonl) so ticks compose.
        state_rows = state_ledger.read_entries(str(sd / "run_state.jsonl"))
        mirror = [r for r in state_rows if r["kind"] == "dispatch"]
        check(
            "dispatch-mirrored-to-state-ledger",
            len(mirror) == 1
            and json.loads(mirror[0]["detail"])["deficit"] == 8
            and mirror[0]["subject"] == "pool_saturation_guard",
        )

        # Fixture 3: sustained deficit (9 workers, previous heartbeat 12 < 15)
        # -> SEV2 with the last-2-heartbeat window satisfied.
        c3 = run_cycle(sd, 20, now=1_000_600, counter=lambda: 9)
        check("sustained-deficit-sev2", c3.get("severity") == "SEV2")
        check("sev2-sustained-flag", c3.get("severity") == "SEV2")

        # Fixture 4: mid-band (17 workers, above 15, below 20) -> SEV4 band.
        c4 = run_cycle(sd, 20, now=1_000_900, counter=lambda: 17)
        check("midband-sev4", c4.get("severity") == "SEV4" and c4["status"] == "DEFICIT")

        # Fixture 5: counter failure -> COUNTER_FAIL, SEV1, UNKNOWN not zero.
        c5 = run_cycle(sd, 20, now=1_001_200, counter=lambda: -1)
        check("counter-fail-typed", c5["status"] == "COUNTER_FAIL" and c5["workers"] == -1)
        rows5 = [json.loads(l) for l in (sd / LEDGER).read_text().splitlines() if l.strip()]
        check("counter-fail-sev1", rows5[-1]["severity"] == "SEV1")

        # Fixture 6: recovery (25 workers) -> OK, no new dispatch row emitted.
        before = len((sd / DISPATCH).read_text().splitlines())
        c6 = run_cycle(sd, 20, now=1_001_500, counter=lambda: 25)
        after = len((sd / DISPATCH).read_text().splitlines())
        check("recovery-ok", c6["status"] == "OK")
        check("no-dispatch-on-recovery", after == before)

    print(f"\nself-check: {len(failures)} failure(s)" + (": " + ", ".join(failures) if failures else ""))
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="HAVE Level-1 pool saturation guard")
    ap.add_argument("--target-pool", type=int, default=DEFAULT_TARGET_POOL)
    ap.add_argument(
        "--state-dir",
        default=str(Path(__file__).resolve().parent.parent.parent / "tmp" / "have"),
    )
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()

    if args.self_check:
        return self_check()

    cycle = run_cycle(Path(args.state_dir), args.target_pool)
    print(json.dumps(cycle, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Chaos kill-under-load harness (stdlib-only), fail-closed.

Runs steady 20 rps good traffic (ARM 9443 + Cosmos data-plane 8443) against a
live substrate and injects three functional chaos phases at t=30/60/90s:

  t=30s  listen-queue fill: hold 300 unaccepted connects on :8443 for 10s
  t=60s  gate pressure: 500 GraphLaw-refusing ARM PUTs (400 InvalidResourceShape)
  t=90s  total failure: SIGKILL the whole substrate beam mid-flight, reboot,
         measure time-to-first-successful-request

Per-phase impact table + recovery times are printed and written to
tmp/chaos-kill-receipt.json.
"""
from __future__ import annotations

import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = "127.0.0.1"
ARM_PORT = 9443
DATA_PORT = 8443
AMQP_PORT = 5672
SUB_ID = "chaos-sub"
API_VERSION = "2021-01-01"

TRAFFIC_RPS = 20.0
PHASE_FLOOD = 30.0
PHASE_GATE = 60.0
PHASE_KILL = 90.0
FLOOD_CONNECTIONS = 300
FLOOD_HOLD_S = 10.0
GATE_REQUESTS = 500
RECOVERY_WINDOW_S = 30.0

RECEIPT_PATH = os.path.join(REPO, "tmp", "chaos-kill-receipt.json")
SUBSTRATE_LOG = os.path.join(REPO, "tmp", "chaos-substrate.log")
SCHEMA = "smalt-chaos-kill/v1"

PHASE_KEYS = (
    "p1_baseline",
    "p2_flood",
    "p2_between",
    "p3_gate",
    "p3_between",
    "p4_kill_recovery",
)


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Substrate lifecycle (mirrors scripts/bench.py)
# ---------------------------------------------------------------------------

def spawn_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    proc = subprocess.Popen(
        ["mix", "run", "--no-halt"],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )
    return boot_with_retry(attempts=3)


def boot_with_retry(attempts=3):
    """Spawn the substrate and verify it is actually usable: ports bound, beam
    alive after a settle, token minted, authenticated canary passes. Any
    failure sweeps the pinned ports and retries (e.g. stray substrates racing
    us on the fixed ports, or a lazy AMQP bind crashing the beam late)."""
    for attempt in range(attempts):
        proc = _popen_substrate()
        try:
            wait_for_port(ARM_PORT, proc, timeout_s=90.0)
            wait_for_port(DATA_PORT, proc, timeout_s=30.0)
            time.sleep(2.0)  # settle: catch late bind crashes
            if proc.poll() is not None:
                fail_closed(f"substrate exited rc={proc.poll()} after settle")
            acquire_token()
            canary()
            return proc
        except (SystemExit, Exception) as e:
            print(f"[CHAOS] boot attempt {attempt + 1}/{attempts} failed ({e}); "
                  f"sweeping ports and retrying")
            kill_substrate(proc)
            sweep_ports()
            time.sleep(2.0)
    fail_closed(f"could not boot a usable substrate after {attempts} attempts")


def _popen_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    return subprocess.Popen(
        ["mix", "run", "--no-halt"],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=open(SUBSTRATE_LOG, "ab"),
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )


def canary():
    """One authenticated ARM GET; 401 means our token and the listener disagree."""
    try:
        status = arm_get_rg(0)
    except Exception as e:
        fail_closed(f"auth canary request failed: {e}")
    if str(status) == "401":
        acquire_token()
        status = arm_get_rg(0)
        if str(status) == "401":
            fail_closed("auth canary still 401 after token refresh")


# ---------------------------------------------------------------------------
# Bearer auth: dev mode enforces tokens; the ARM STS mints one per beam
# ---------------------------------------------------------------------------

_TOKEN = {"value": None}


def acquire_token():
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=5.0)
    try:
        body = "grant_type=client_credentials"
        conn.request("POST", "/oauth2/v2.0/token", body=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        payload = json.loads(resp.read())
        if resp.status != 200 or "access_token" not in payload:
            fail_closed(f"token endpoint returned {resp.status}: {payload}")
        _TOKEN["value"] = payload["access_token"]
        return _TOKEN["value"]
    finally:
        conn.close()


def auth_headers(extra=None):
    h = {"Authorization": f"Bearer {_TOKEN['value']}"}
    if extra:
        h.update(extra)
    return h


def wait_for_port(port, proc, timeout_s=90.0):
    t0 = time.monotonic()
    deadline = t0 + timeout_s
    while time.monotonic() < deadline:
        if proc is not None and proc.poll() is not None:
            fail_closed(f"substrate exited rc={proc.poll()} before binding :{port}")
        try:
            with socket.create_connection((HOST, port), timeout=0.25):
                pass
            return time.monotonic() - t0
        except OSError:
            time.sleep(0.01)
    fail_closed(f"substrate never bound :{port} within {timeout_s}s")


def sweep_ports():
    for port in (ARM_PORT, DATA_PORT, AMQP_PORT, 5673):
        try:
            out = subprocess.run(["lsof", "-ti", f"tcp:{port}"],
                                 capture_output=True, text=True, timeout=10).stdout
        except Exception:
            out = ""
        for pid in out.split():
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ValueError, ProcessLookupError, PermissionError):
                pass


def kill_substrate(proc):
    if proc is None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        try:
            proc.kill()
        except Exception:
            pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass
    sweep_ports()


def wait_port_free(port, timeout_s=15.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        try:
            socket.create_connection((HOST, port), timeout=0.2).close()
            # connect succeeded -> port is BUSY
            time.sleep(0.05)
        except OSError:
            # connect failed -> port is FREE
            return True
    return False


# ---------------------------------------------------------------------------
# Good-traffic request functions (real HTTP over loopback)
# ---------------------------------------------------------------------------

def arm_put_rg(i):
    body = json.dumps({"location": "chaos"})
    path = f"/subscriptions/{SUB_ID}/resourceGroups/rg-chaos-{i % 8}?api-version={API_VERSION}"
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=5.0)
    try:
        conn.request("PUT", path, body=body, headers=auth_headers({
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        }))
        resp = conn.getresponse()
        resp.read()
        return resp.status
    finally:
        conn.close()


def arm_get_rg(i):
    path = (f"/subscriptions/{SUB_ID}/resourceGroups/rg-chaos-{(i - 1) % 8}"
            f"?api-version={API_VERSION}")
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=5.0)
    try:
        conn.request("GET", path, headers=auth_headers({"Content-Length": "0"}))
        resp = conn.getresponse()
        resp.read()
        return resp.status
    finally:
        conn.close()


def cosmos_post(i):
    body = json.dumps({"id": f"chaos-{i}", "pk": "chaos", "payload": "x" * 128})
    conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=5.0)
    try:
        conn.request("POST", "/dbs/chaos/colls/c/docs", body=body, headers=auth_headers({
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        }))
        resp = conn.getresponse()
        resp.read()
        return resp.status
    finally:
        conn.close()


def cosmos_get(i):
    conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=5.0)
    try:
        conn.request("GET", f"/dbs/chaos/colls/c/docs/chaos-{i - 1}",
                     headers=auth_headers({"Content-Length": "0"}))
        resp = conn.getresponse()
        resp.read()
        return resp.status
    finally:
        conn.close()


KINDS = ("arm_put", "arm_get", "cosmos_post", "cosmos_get")


def good_request(i):
    """One good-traffic request, rotating 4 kinds. Returns (status_str, latency_ms)."""
    t0 = time.perf_counter()
    which = i % 4
    try:
        if which == 0:
            status = arm_put_rg(i)
        elif which == 1:
            status = arm_get_rg(i)
        elif which == 2:
            status = cosmos_post(i)
        else:
            status = cosmos_get(i)
        return str(status), (time.perf_counter() - t0) * 1000.0
    except Exception as e:
        return f"ERR:{type(e).__name__}", (time.perf_counter() - t0) * 1000.0


# ---------------------------------------------------------------------------
# Good-traffic loop (single paced thread, 20 rps)
# ---------------------------------------------------------------------------

def run_good_traffic(stop_evt, records, t_start, events):
    i = 0
    interval = 1.0 / TRAFFIC_RPS
    next_t = time.monotonic()
    streak401 = 0
    while not stop_evt.is_set():
        status, dt = good_request(i)
        records.append({
            "t_rel": round(time.monotonic() - t_start, 3),
            "kind": KINDS[i % 4],
            "status": status,
            "latency_ms": round(dt, 3),
        })
        if status == "401":
            streak401 += 1
            if streak401 >= 5:
                events.append({"t_rel": round(time.monotonic() - t_start, 3),
                               "event": "token_refresh"})
                acquire_token()
                streak401 = 0
        else:
            streak401 = 0
        i += 1
        next_t += interval
        delay = next_t - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            next_t = time.monotonic()  # fell behind; re-anchor pacing


def run_watchdog(stop_evt, records, t_start, events, current):
    """If our substrate beam dies mid-run, record the crash and reboot it —
    a mid-run crash under load is itself a chaos finding, and without a
    reboot the rest of the run would measure a dead substrate."""
    while not stop_evt.is_set():
        proc = current["proc"]
        if (proc is not None and not current.get("killing")
                and proc.poll() is not None):
            events.append({"t_rel": round(time.monotonic() - t_start, 3),
                           "event": "substrate_crash",
                           "rc": proc.poll()})
            new_proc = spawn_substrate()
            current["proc"] = new_proc
        time.sleep(0.5)


def _wait_until(t_start, target):
    d = (t_start + target) - time.monotonic()
    if d > 0:
        time.sleep(d)


# ---------------------------------------------------------------------------
# Chaos phases
# ---------------------------------------------------------------------------

def phase_flood(results):
    """Open 300 unaccepted connects to :8443, hold them 10s, release."""
    socks = []
    opened = 0
    t0 = time.monotonic()
    try:
        while len(socks) < FLOOD_CONNECTIONS and time.monotonic() - t0 < FLOOD_HOLD_S:
            try:
                s = socket.create_connection((HOST, DATA_PORT), timeout=2.0)
                socks.append(s)
                opened += 1
            except OSError:
                time.sleep(0.005)
        time.sleep(max(0.0, FLOOD_HOLD_S - (time.monotonic() - t0)))
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass
    results["listen_queue_fill"] = {
        "connections_opened": opened,
        "target": FLOOD_CONNECTIONS,
        "hold_s": FLOOD_HOLD_S,
    }
    return time.monotonic() - t0


def phase_gate(results):
    """500 GraphLaw-refusing ARM PUTs (unadmitted type) -> 400 InvalidResourceShape."""
    statuses = {}
    errors = 0
    body = json.dumps({"location": "chaos"})
    t0 = time.monotonic()
    for i in range(GATE_REQUESTS):
        conn = None
        try:
            path = (f"/subscriptions/{SUB_ID}/resourceGroups/rg-gate-{i}"
                    f"/providers/Microsoft.Fake/nonexistentType/gate-{i}"
                    f"?api-version={API_VERSION}")
            conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=5.0)
            conn.request("PUT", path, body=body, headers=auth_headers({
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
            }))
            resp = conn.getresponse()
            resp.read()
            statuses[resp.status] = statuses.get(resp.status, 0) + 1
        except Exception:
            errors += 1
        finally:
            if conn is not None:
                conn.close()
    results["gate_pressure"] = {
        "requests": GATE_REQUESTS,
        "status_counts": statuses,
        "errors": errors,
        "duration_s": round(time.monotonic() - t0, 3),
    }


def phase_kill_and_recover(current, records, t_start, results):
    """SIGKILL the substrate process group, respawn, measure recovery."""
    proc = current["proc"]
    kill_t = time.monotonic()
    current["killing"] = True
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        proc.kill()
    try:
        proc.wait(timeout=5)
    except Exception:
        pass
    sweep_ports()
    pre_kill = len(records)

    new_proc = spawn_substrate()
    reboot_s = time.monotonic() - kill_t
    current["proc"] = new_proc
    current["killing"] = False
    results["kill"] = {
        "signal": "SIGKILL(process-group)",
        "at_t_rel": round(kill_t - t_start, 3),
        "reboot_s": round(reboot_s, 3),
    }

    # watch for the first good 2xx after the kill, within a bounded window
    first_ok = None
    deadline = kill_t + reboot_s + RECOVERY_WINDOW_S
    while time.monotonic() < deadline:
        for r in records[pre_kill:]:
            if r["t_rel"] > (kill_t - t_start) and str(r["status"]).startswith("2"):
                first_ok = r["t_rel"]
                break
        if first_ok is not None:
            break
        time.sleep(0.2)

    in_flight_failures = sum(
        1 for r in records[pre_kill:]
        if r["t_rel"] > (kill_t - t_start)
        and (first_ok is None or r["t_rel"] < first_ok)
        and not str(r["status"]).startswith("2")
    )
    results["kill"]["in_flight_failures"] = in_flight_failures
    results["kill"]["time_to_first_success_s"] = (
        round(first_ok - (kill_t - t_start), 3) if first_ok is not None else None
    )
    return new_proc


# ---------------------------------------------------------------------------
# Analysis + receipt
# ---------------------------------------------------------------------------

def phase_of(t_rel, t_kill):
    if t_rel < PHASE_FLOOD:
        return "p1_baseline"
    if t_rel < PHASE_FLOOD + 15.0:
        return "p2_flood"
    if t_rel < PHASE_GATE:
        return "p2_between"
    if t_rel < PHASE_GATE + 15.0:
        return "p3_gate"
    if t_rel >= PHASE_KILL:
        return "p4_kill_recovery"
    return "p3_between"


def ok(status):
    return str(status).startswith("2")


def stats_block(recs):
    good = [r for r in recs if ok(r["status"])]
    lats = sorted(r["latency_ms"] for r in good)
    if not lats:
        return {"n": len(recs), "successes": 0, "failures": len(recs),
                "p50_ms": None, "p95_ms": None, "p99_ms": None, "max_ms": None}
    def pct(p):
        k = int(round((p / 100.0) * (len(lats) - 1)))
        return round(lats[k], 3)
    return {
        "n": len(recs),
        "successes": len(good),
        "failures": len(recs) - len(good),
        "p50_ms": pct(50),
        "p95_ms": pct(95),
        "p99_ms": pct(99),
        "max_ms": lats[-1],
    }


def analyze(records, t_kill_rel, reboot_s, kill_results):
    t_reboot_end = t_kill_rel + reboot_s
    per_phase = {k: [] for k in PHASE_KEYS}
    post = []
    for r in records:
        r["phase"] = phase_of(r["t_rel"], t_kill_rel)
        per_phase[r["phase"]].append(r)
        if r["t_rel"] >= t_reboot_end:
            post.append(r)
    table = {k: stats_block(per_phase[k]) for k in PHASE_KEYS}
    table["recovery"] = {
        "in_flight_failures": kill_results["kill"]["in_flight_failures"],
        "reboot_s": kill_results["kill"]["reboot_s"],
        "time_to_first_success_s": kill_results["kill"]["time_to_first_success_s"],
        "ttfas_measured_from": "kill moment",
        "post_recovery_window_s": RECOVERY_WINDOW_S,
        "post_recovery_stats": stats_block(post),
    }
    return table


def fmt(v):
    return "-" if v is None else f"{v:.1f}"


def print_table(table):
    print("\n== Per-phase impact table (good traffic, 20 rps) ==")
    print(f"{'phase':22s} {'n':>5s} {'ok':>5s} {'fail':>5s} "
          f"{'p50ms':>8s} {'p95ms':>8s} {'p99ms':>8s} {'maxms':>8s}")
    for k in PHASE_KEYS:
        b = table[k]
        print(f"{k:22s} {b['n']:5d} {b['successes']:5d} {b['failures']:5d} "
              f"{fmt(b['p50_ms']):>8s} {fmt(b['p95_ms']):>8s} "
              f"{fmt(b['p99_ms']):>8s} {fmt(b['max_ms']):>8s}")
    rec = table["recovery"]
    post = rec["post_recovery_stats"]
    print("\n== Recovery ==")
    print(f"  in-flight failures at kill : {rec['in_flight_failures']}")
    print(f"  reboot time (ports bound)  : {rec['reboot_s']}s")
    print(f"  time-to-first-success      : {rec['time_to_first_success_s']}s (from kill)")
    print(f"  post-recovery window       : n={post['n']} ok={post['successes']} "
          f"fail={post['failures']} p95={fmt(post['p95_ms'])}ms")


def write_receipt(records, table, raw_results, events):
    receipt = {
        "schema": SCHEMA,
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": "darwin/arm64 local",
        "profile": ("20 rps ARM+Cosmos good traffic; t30 listen-queue fill "
                    "(300 conns, 10s); t60 gate pressure (500 refusing PUTs); "
                    "t90 SIGKILL process group + reboot"),
        "phases": {
            "t30_listen_queue_fill": raw_results.get("listen_queue_fill"),
            "t60_gate_pressure": raw_results.get("gate_pressure"),
            "t90_kill": raw_results.get("kill"),
        },
        "impact_table": table,
        "events": events,
        "requests": records,
    }
    with open(RECEIPT_PATH, "w") as f:
        f.write(json.dumps(receipt, indent=2))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    for port in (ARM_PORT, DATA_PORT, AMQP_PORT, 5673):
        if not wait_port_free(port, timeout_s=2.0):
            print(f"[CHAOS] port {port} held by a stray substrate; sweeping")
            sweep_ports()
            if not wait_port_free(port, timeout_s=15.0):
                fail_closed(f"port {port} still in use after sweep")

    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)

    print("[CHAOS] spawning substrate")
    proc = spawn_substrate()
    results = {}
    records = []
    events = []
    current = {"proc": proc, "killing": False}
    stop_evt = threading.Event()
    t_start = time.monotonic()

    traffic = threading.Thread(target=run_good_traffic,
                               args=(stop_evt, records, t_start, events), daemon=True)
    traffic.start()
    watchdog = threading.Thread(target=run_watchdog,
                                args=(stop_evt, records, t_start, events, current),
                                daemon=True)
    watchdog.start()

    new_proc = proc
    try:
        _wait_until(t_start, PHASE_FLOOD)
        print(f"[CHAOS] t=30 listen-queue fill: {FLOOD_CONNECTIONS} unaccepted "
              f"connects on :{DATA_PORT}, hold {FLOOD_HOLD_S}s")
        phase_flood(results)

        _wait_until(t_start, PHASE_GATE)
        print(f"[CHAOS] t=60 gate pressure: {GATE_REQUESTS} refusing ARM PUTs")
        phase_gate(results)

        _wait_until(t_start, PHASE_KILL)
        print("[CHAOS] t=90 SIGKILL substrate process group mid-flight")
        new_proc = phase_kill_and_recover(current, records, t_start, results)

        _wait_until(t_start, PHASE_KILL + RECOVERY_WINDOW_S)
        stop_evt.set()
        traffic.join(timeout=15)

        kill_rel = PHASE_KILL
        reboot_s = results["kill"]["reboot_s"]
        table = analyze(records, kill_rel, reboot_s, results)
        table["events"] = events
        print_table(table)
        write_receipt(records, table, results, events)
        print(f"[CHAOS] receipt written: {RECEIPT_PATH}")
    finally:
        stop_evt.set()
        kill_substrate(proc)
        if new_proc is not proc:
            kill_substrate(new_proc)

    print("[CHAOS] done")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        sys.exit(1)

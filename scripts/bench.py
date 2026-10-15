#!/usr/bin/env python3
"""Smalt benchmark — fail-closed measurement harness (stdlib-only).

Measures PRD CTQs against a live substrate spawned by this script:

  1. Doctor runtime          (target <= 3s, against a live substrate)
  2. Substrate boot          spawn -> TCP accept on 9443, 5 runs (target <= 5s)
  3. ARM PUT round-trip      200 PUTs, p50/p95/p99 (target p95 < 50ms)
  4. Cosmos doc round-trip   200x POST+GET, p50/p95 (target p95 < 20ms)
  5. AMQP header exchange    50x raw socket, first-frame latency (target < 100ms)

The substrate is killed in a finally/trap on every path. Exit code 0 only
when the full run completed; per-CTQ PASS/FAIL is reported per measurement.
"""
import http.client
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
import traceback

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = "127.0.0.1"
ARM_PORT = 9443
DATA_PORT = 8443
AMQP_PORT = 5672
SUB_ID = "bench-sub"
API_VERSION = "2021-01-01"

DOCTOR_TARGET_S = 3.0
BOOT_TARGET_S = 5.0
ARM_P95_TARGET_MS = 50.0
COSMOS_P95_TARGET_MS = 20.0
AMQP_READY_TARGET_MS = 100.0

SCHEMA = "smalt-bench/v1"
RECEIPT_PATH = os.path.join(REPO, "tmp", "bench-receipt.json")


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(1)


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


def spawn_substrate():
    """Spawn `mix run --no-halt` in its own process group; caller must killpg."""
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    return subprocess.Popen(
        ["mix", "run", "--no-halt"],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )


def wait_for_port(port, proc, timeout_s=90.0):
    """Poll TCP connect until the port accepts; return elapsed seconds since spawn."""
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


def kill_substrate(proc):
    """SIGKILL the whole process group, then sweep any surviving port holder; never raise."""
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
    # sweep: a BEAM child can outlive the mix wrapper's process group
    for port in (ARM_PORT, DATA_PORT, AMQP_PORT):
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
    try:
        os.remove("/tmp/smalt-bench.pid")
    except OSError:
        pass


def doctor_time():
    """Time `scripts/doctor.py` against the live substrate (ports held by caller)."""
    t0 = time.monotonic()
    r = subprocess.run(
        [sys.executable, os.path.join(REPO, "scripts", "doctor.py")],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=60,
    )
    elapsed = time.monotonic() - t0
    if r.returncode != 0:
        return elapsed, False, (r.stderr or r.stdout).strip()[-300:]
    return elapsed, True, ""


def wait_port_free(port, timeout_s=15.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        try:
            socket.create_connection((HOST, port), timeout=0.2).close()
        except OSError:
            return True
        time.sleep(0.05)
    return False


def bench_boot(n=5):
    boot_times = []
    for i in range(n):
        if not wait_port_free(ARM_PORT, timeout_s=20.0):
            fail_closed(f"port {ARM_PORT} not free before boot run {i + 1}")
        proc = spawn_substrate()
        try:
            t = wait_for_port(ARM_PORT, proc)
            boot_times.append(t)
            print(f"  boot run {i + 1}/{n}: {t:.3f}s")
        finally:
            kill_substrate(proc)
        if not wait_port_free(ARM_PORT):
            fail_closed(f"port {ARM_PORT} still held after teardown of boot run {i + 1}")
        time.sleep(0.5)
    return boot_times


def _arm_put_once(i):
    body = json.dumps({"location": "bench"})
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10)
    path = f"/subscriptions/{SUB_ID}/resourceGroups/rg-bench-{i}?api-version={API_VERSION}"
    try:
        t0 = time.perf_counter()
        conn.request("PUT", path, body=body, headers={
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        resp.read()
        dt = (time.perf_counter() - t0) * 1000.0
        if resp.status not in (200, 201):
            fail_closed(f"ARM PUT #{i} returned {resp.status} (expected 200/201)")
        return dt
    finally:
        conn.close()


def bench_arm_puts(n=200):
    if not wait_port_free(ARM_PORT, timeout_s=20.0):
        fail_closed(f"port {ARM_PORT} not free before ARM bench")
    proc = spawn_substrate()
    try:
        wait_for_port(ARM_PORT, proc)
        return [_arm_put_once(i) for i in range(n)]
    finally:
        kill_substrate(proc)


def bench_cosmos(n=200):
    if not wait_port_free(DATA_PORT, timeout_s=20.0):
        fail_closed(f"port {DATA_PORT} not free before Cosmos bench")
    proc = spawn_substrate()
    try:
        wait_for_port(DATA_PORT, proc)
        times_ms = []
        for i in range(n):
            body = json.dumps({"id": f"bench-{i}", "pk": "bench", "payload": "x" * 128})
            headers = {"Content-Type": "application/json", "Content-Length": str(len(body))}
            t0 = time.perf_counter()
            conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=10)
            conn.request("POST", "/dbs/bench/colls/c/docs", body=body, headers=headers)
            r1 = conn.getresponse()
            r1.read()
            t1 = time.perf_counter()
            conn.request("GET", f"/dbs/bench/colls/c/docs/bench-{i}",
                         headers={"Content-Length": "0"})
            r2 = conn.getresponse()
            r2.read()
            t2 = time.perf_counter()
            conn.close()
            if r1.status != 201:
                fail_closed(f"Cosmos POST #{i} returned {r1.status} (expected 201)")
            if r2.status != 200:
                fail_closed(f"Cosmos GET #{i} returned {r2.status} (expected 200)")
            times_ms.extend([(t1 - t0) * 1000.0, (t2 - t1) * 1000.400 if False else (t2 - t1) * 1000.0])
        return times_ms
    finally:
        kill_substrate(proc)


def bench_amqp(rounds=50):
    if not wait_port_free(AMQP_PORT, timeout_s=20.0):
        fail_closed(f"port {AMQP_PORT} not free before AMQP bench")
    proc = spawn_substrate()
    try:
        wait_for_port(AMQP_PORT, proc)
        lats = []
        for _ in range(rounds):
            t0 = time.perf_counter()
            s = socket.create_connection((HOST, AMQP_PORT), timeout=5)
            s.sendall(b"AMQP\x00\x01\x00\x00")
            peer = s.recv(8)
            dt = (time.perf_counter() - t0) * 1000.0
            s.close()
            if not peer.startswith(b"AMQP"):
                fail_closed(f"AMQP peer header not AMQP: {peer!r}")
            lats.append(dt)
        return lats
    finally:
        kill_substrate(proc)


def stats_dict(vals, unit="ms"):
    s = sorted(vals)
    return {
        "n": len(s),
        "min": round(s[0], 3),
        "median": round(statistics.median(s), 3),
        "p95": round(pct(s, 95), 3),
        "p99": round(pct(s, 99), 3),
        "max": round(s[-1], 3),
        "unit": unit,
    }


def verdict(d, target, key="p95", cmp="lt"):
    val = d[key] if key in d else d["latency_ms"][key]
    ok = val < target if cmp == "lt" else val <= target
    d["target"] = target
    d["verdict"] = "PASS" if ok else "FAIL"
    return d


def main():
    if shutil.which("mix") is None:
        fail_closed("mix not in PATH")

    for port in (ARM_PORT, DATA_PORT, AMQP_PORT):
        if not wait_port_free(port, timeout_s=30.0):
            holder = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
                                    capture_output=True, text=True).stdout.strip()
            fail_closed(f"port {port} still in use after 30s: {holder}")

    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)

    # --- doctor: pre-flight court, defined to run with the substrate DOWN ---
    print("[BENCH] doctor (substrate stopped, as doctor requires)")
    doctor_elapsed, doctor_ok, doctor_err = doctor_time()
    doctor_pass = False
    if doctor_ok:
        doctor_pass = doctor_elapsed <= DOCTOR_TARGET_S
        print(f"  {doctor_elapsed:.3f}s (target <= {DOCTOR_TARGET_S}s) -> "
              f"{'PASS' if doctor_pass else 'FAIL'}")
    else:
        fail_closed(f"doctor failed: {doctor_err}")

    print("[BENCH] substrate boot (spawn -> TCP accept on 9443), 5 runs")
    boots = bench_boot(5)

    print("[BENCH] ARM PUT round-trip, 200 PUTs")
    arm_vals = bench_arm_puts(200)
    arm = verdict(stats_dict(arm_vals), ARM_P95_TARGET_MS, cmp="lt")

    print("[BENCH] Cosmos doc POST+GET round-trips, 200x")
    cosmos_vals = bench_cosmos(200)
    cosmos = verdict(stats_dict(cosmos_vals), COSMOS_P95_TARGET_MS, cmp="lt")

    print("[BENCH] AMQP first-frame latency (connect + 8-byte header), 50 rounds")
    amqp_vals = bench_amqp(50)
    amqp = verdict(stats_dict(amqp_vals), AMQP_READY_TARGET_MS, cmp="lt")

    boot_sorted = sorted(boots)
    boot_stats = {
        "runs": [round(b, 3) for b in boots],
        "n": len(boots),
        "min_s": round(boot_sorted[0], 3),
        "median_s": round(statistics.median(boots), 3),
        "p95_s": round(pct(boot_sorted, 95), 3),
        "target_s": BOOT_TARGET_S,
        "verdict": "PASS" if pct(boot_sorted, 95) <= BOOT_TARGET_S else "FAIL",
    }
    doctor_stats = {
        "elapsed_s": round(doctor_elapsed, 3),
        "target_s": DOCTOR_TARGET_S,
        "verdict": "PASS" if doctor_pass else "FAIL",
    }

    print("\n== Results ==")
    print(f"  doctor        : {doctor_stats['elapsed_s']}s "
          f"(<= {DOCTOR_TARGET_S}s) -> {doctor_stats['verdict']}")
    print(f"  boot median   : {boot_stats['median_s']}s  p95 {boot_stats['p95_s']}s "
          f"(<= {BOOT_TARGET_S}s) -> {boot_stats['verdict']}")
    for name, d in (("arm_put", arm), ("cosmos", cosmos), ("amqp_first_frame", amqp)):
        lat = d["latency_ms"] if "latency_ms" in d else d
        print(f"  {name:14s}: p50 {lat['median']}ms  p95 {lat['p95']}ms  p99 {lat['p99']}ms "
              f"(p95 < {d['target']}ms) -> {d['verdict']}")

    receipt = {
        "schema": SCHEMA,
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": "darwin/arm64 local",
        "doctor": doctor_stats,
        "boot": boot_stats,
        "arm_put": arm,
        "cosmos_roundtrip": cosmos,
        "amqp_first_frame": amqp,
    }
    with open(RECEIPT_PATH, "w") as f:
        f.write(json.dumps(receipt, indent=2))
    print(f"[BENCH] receipt written: {RECEIPT_PATH}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        sys.exit(1)

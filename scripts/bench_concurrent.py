#!/usr/bin/env python3
"""Smalt concurrent-behavior benchmark (stdlib-only).

Boots the substrate once (pid + process-group trap, same pattern as
scripts/bench.py), then measures under real concurrency:

  1. ARM PUT  : 32 threads x 25 unique resource groups (800 requests)
  2. Cosmos   : 16 concurrent doc-creation workers (20 docs each, 400 POSTs)
  3. CAS probe: 2 workers racing PUT on the SAME resource-group id 250x
                each (500 requests); 200-on-update path doubles as the
                Store compare-and-write serialization witness
  4. Asserts  : zero non-2xx (any 5xx = FAIL exit 1), zero transport errors;
                 workers authenticate via the ARM STS client-credentials flow

Per-request latencies come from worker-local timers (time.perf_counter);
wall time is measured per phase. Receipt: tmp/bench-concurrent-receipt.json
(schema smalt-bench-concurrent/v1).
"""
import http.client
import json
import os
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
import traceback

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = "127.0.0.1"
# Ports are overridable via env so the bench can run against its own
# substrate on private high ports when the canonical 9443/8443 are held
# by another lane (the substrate reads :smalt, :arm_port/:data_plane_port).
ARM_PORT = int(os.environ.get("SMALT_BENCH_ARM_PORT", "9443"))
DATA_PORT = int(os.environ.get("SMALT_BENCH_DATA_PORT", "8443"))
AMQP_PORT = 5672
SUB_ID = "bench-sub"
API_VERSION = "2021-01-01"

ARM_WORKERS = 32
ARM_PER_WORKER = 25
COSMOS_WORKERS = 16
COSMOS_PER_WORKER = 20
CAS_WORKERS = 2
CAS_PER_WORKER = 250

SCHEMA = "smalt-bench-concurrent/v1"
RECEIPT_PATH = os.path.join(REPO, "tmp", "bench-concurrent-receipt.json")


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(code)


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


def spawn_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    if ARM_PORT != 9443 or DATA_PORT != 8443:
        # --no-start so the env is set before the app boots its listeners
        cmd = ["mix", "run", "--no-start", "--no-halt", "-e",
               f"Application.put_env(:smalt, :arm_port, {ARM_PORT}); "
               f"Application.put_env(:smalt, :egress_port, {DATA_PORT}); "
               "{{:ok, _}} = Application.ensure_all_started(:smalt)"]
    else:
        cmd = ["mix", "run", "--no-halt"]
    return subprocess.Popen(
        cmd,
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )


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


def wait_port_free(port, timeout_s=30.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        try:
            socket.create_connection((HOST, port), timeout=0.2).close()
        except OSError:
            return True
        time.sleep(0.05)
    return False


def stats_dict(vals):
    s = sorted(vals)
    return {
        "n": len(s),
        "min_ms": round(s[0], 3),
        "p50_ms": round(statistics.median(s), 3),
        "p95_ms": round(pct(s, 95), 3),
        "p99_ms": round(pct(s, 99), 3),
        "max_ms": round(s[-1], 3),
    }


class Result:
    def __init__(self):
        self.lock = threading.Lock()
        self.latencies = []
        self.status_counts = {}
        self.errors = []

    def add(self, dt_ms, status, err=None):
        with self.lock:
            if err is None:
                self.latencies.append(dt_ms)
                self.status_counts[status] = self.status_counts.get(status, 0) + 1
            else:
                self.errors.append(err)


def fetch_bearer_token(port, timeout_s=10):
    """Client-credentials flow against the ARM STS (exempt path, no token
    needed to reach it). Returns the access_token string."""
    body = ("grant_type=client_credentials&client_id=bench-client"
            "&client_secret=bench-secret"
            "&scope=https%3A%2F%2Fmanagement.azure.com%2F.default")
    conn = http.client.HTTPConnection(HOST, port, timeout=timeout_s)
    try:
        conn.request("POST", "/oauth2/v2.0/token", body=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        payload = json.loads(resp.read())
        if resp.status != 200 or "access_token" not in payload:
            fail_closed(f"STS token fetch returned {resp.status}: {payload}")
        return payload["access_token"]
    finally:
        conn.close()


def arm_put_worker(wid, result, barrier, token):
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=15)
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
    }
    try:
        barrier.wait()
        for i in range(ARM_PER_WORKER):
            n = wid * ARM_PER_WORKER + i
            body = json.dumps({"location": "bench-concurrent"})
            path = (f"/subscriptions/{SUB_ID}/resourceGroups/rg-bconc-{n}"
                    f"?api-version={API_VERSION}")
            try:
                t0 = time.perf_counter()
                conn.request("PUT", path, body=body, headers={
                    **headers, "Content-Length": str(len(body)),
                })
                resp = conn.getresponse()
                resp.read()
                dt = (time.perf_counter() - t0) * 1000.0
                result.add(dt, resp.status)
            except Exception as exc:
                result.add(None, None, err=f"arm w{wid} #{i}: {exc!r}")
    finally:
        conn.close()


def cosmos_worker(wid, result, barrier, token):
    barrier.wait()
    for i in range(COSMOS_PER_WORKER):
        n = wid * COSMOS_PER_WORKER + i
        doc_id = f"bcosmos-{wid}-{i}"
        body = json.dumps({"id": doc_id, "pk": "bench", "payload": "x" * 128})
        headers = {"Content-Type": "application/json",
                   "Authorization": f"Bearer {token}",
                   "Content-Length": str(len(body))}
        try:
            t0 = time.perf_counter()
            conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=15)
            conn.request("POST", "/dbs/bench/colls/c/docs", body=body,
                         headers=headers)
            r1 = conn.getresponse()
            r1.read()
            dt = (time.perf_counter() - t0) * 1000.0
            conn.close()
            result.add(dt, r1.status)
        except Exception as exc:
            result.add(None, None, err=f"cosmos w{wid} #{i}: {exc!r}")


def cas_worker(wid, result, barrier, rg_name, token):
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=15)
    body = json.dumps({"location": "bench-cas"})
    path = (f"/subscriptions/{SUB_ID}/resourceGroups/{rg_name}"
            f"?api-version={API_VERSION}")
    try:
        barrier.wait()
        for i in range(CAS_PER_WORKER):
            try:
                t0 = time.perf_counter()
                conn.request("PUT", path, body=body, headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {token}",
                    "Content-Length": str(len(body)),
                })
                resp = conn.getresponse()
                resp.read()
                dt = (time.perf_counter() - t0) * 1000.0
                result.add(dt, resp.status)
            except Exception as exc:
                result.add(None, None, err=f"cas w{wid} #{i}: {exc!r}")
    finally:
        conn.close()


def run_phase(name, target_fn, workers, token):
    barrier = threading.Barrier(workers + 1)
    result = Result()
    threads = [threading.Thread(target=target_fn,
                                args=(w, result, barrier, token), daemon=True)
               for w in range(workers)]
    for t in threads:
        t.start()
    barrier.wait()
    t0 = time.monotonic()
    for t in threads:
        t.join()
    wall = time.monotonic() - t0
    print(f"[BENCH] {name}: wall {wall:.3f}s statuses={dict(sorted(result.status_counts.items()))} "
          f"errors={len(result.errors)}")
    return wall, result


def start_watchdog(timeout_s=600.0):
    """Force-exit if a phase hangs (e.g. substrate killed mid-request by an
    external port sweep leaves a worker thread stuck past socket timeouts)."""
    def _dog():
        time.sleep(timeout_s)
        print("[FAULT] watchdog: benchmark did not finish within "
              f"{timeout_s:.0f}s", file=sys.stderr)
        os._exit(1)
    t = threading.Thread(target=_dog, daemon=True)
    t.start()


def main():
    if subprocess.run(["which", "mix"], capture_output=True).returncode != 0:
        fail_closed("mix not in PATH")

    ports_needed = ([ARM_PORT, DATA_PORT, AMQP_PORT] if ARM_PORT == 9443
                    else [ARM_PORT, DATA_PORT])
    for port in ports_needed:
        if not wait_port_free(port, timeout_s=30.0):
            holder = subprocess.run(
                ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
                capture_output=True, text=True).stdout.strip()
            fail_closed(f"port {port} still in use after 30s: {holder}")

    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)
    start_watchdog()
    proc = spawn_substrate()
    try:
        wait_for_port(ARM_PORT, proc)
        wait_for_port(DATA_PORT, proc)
        print("[BENCH] substrate up (9443 + 8443)")
        token = fetch_bearer_token(ARM_PORT)
        print("[BENCH] STS bearer token acquired")

        print(f"[BENCH] phase 1: ARM PUT, {ARM_WORKERS} workers x "
              f"{ARM_PER_WORKER} unique RGs")
        arm_wall, arm = run_phase("arm_concurrent", arm_put_worker, ARM_WORKERS,
                                  token)

        print(f"[BENCH] phase 2: Cosmos doc create, {COSMOS_WORKERS} workers x "
              f"{COSMOS_PER_WORKER} docs")
        cos_wall, cos = run_phase("cosmos_concurrent", cosmos_worker,
                                  COSMOS_WORKERS, token)

        print(f"[BENCH] phase 3: CAS race, {CAS_WORKERS} workers x "
              f"{CAS_PER_WORKER} PUTs on the same RG id")
        barrier = threading.Barrier(CAS_WORKERS + 1)
        cas = Result()
        rg_name = "rg-cas-race"
        threads = [threading.Thread(target=cas_worker,
                                    args=(w, cas, barrier, rg_name, token),
                                    daemon=True)
                   for w in range(CAS_WORKERS)]
        for t in threads:
            t.start()
        barrier.wait()
        t0 = time.monotonic()
        for t in threads:
            t.join()
        cas_wall = time.monotonic() - t0
        print(f"[BENCH] cas race: wall {cas_wall:.3f}s "
              f"statuses={dict(sorted(cas.status_counts.items()))} "
              f"errors={len(cas.errors)}")

        # --- verdicts: any 5xx (or transport error) anywhere = FAIL ---
        def any_5xx(res):
            return any(500 <= int(s) < 600 for s in res.status_counts)

        failures = []
        for name, res in (("arm_concurrent", arm), ("cosmos_concurrent", cos),
                          ("cas_race", cas)):
            if any_5xx(res):
                failures.append(f"{name}: 5xx statuses "
                                f"{dict(sorted(res.status_counts.items()))}")
            non_2xx = {s: c for s, c in res.status_counts.items()
                       if not (200 <= int(s) < 300)}
            if non_2xx:
                failures.append(f"{name}: non-2xx statuses {non_2xx}")
            if res.errors:
                failures.append(f"{name}: {len(res.errors)} transport errors, "
                                f"first={res.errors[0]}")

        ok = not failures
        for f in failures:
            print(f"[FAIL] {f}", file=sys.stderr)

        arm_stats = stats_dict(arm.latencies)
        cos_stats = stats_dict(cos.latencies)
        cas_stats = stats_dict(cas.latencies)

        print("\n== Concurrent results ==")
        print(f"  arm_concurrent     : n={arm_stats['n']} wall {arm_wall:.3f}s "
              f"p50 {arm_stats['p50_ms']}ms p95 {arm_stats['p95_ms']}ms "
              f"p99 {arm_stats['p99_ms']}ms max {arm_stats['max_ms']}ms "
              f"errors={len(arm.errors)}")
        print(f"  cosmos_concurrent  : n={cos_stats['n']} wall {cos_wall:.3f}s "
              f"p50 {cos_stats['p50_ms']}ms p95 {cos_stats['p95_ms']}ms "
              f"p99 {cos_stats['p99_ms']}ms max {cos_stats['max_ms']}ms "
              f"errors={len(cos.errors)}")
        print(f"  cas_race (2x{CAS_PER_WORKER} same RG): n={cas_stats['n']} "
              f"wall {cas_wall:.3f}s p50 {cas_stats['p50_ms']}ms "
              f"p95 {cas_stats['p95_ms']}ms statuses="
              f"{dict(sorted(cas.status_counts.items()))} "
              f"errors={len(cas.errors)}")
        print(f"  verdict            : {'PASS' if ok else 'FAIL'}")

        receipt = {
            "schema": SCHEMA,
            "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "host": "darwin/arm64 local",
            "arm_concurrent": {
                "workers": ARM_WORKERS, "per_worker": ARM_PER_WORKER,
                "wall_s": round(arm_wall, 3), "latency": arm_stats,
                "status_counts": {str(k): v for k, v in arm.status_counts.items()},
                "errors": len(arm.errors),
            },
            "cosmos_concurrent": {
                "workers": COSMOS_WORKERS, "per_worker": COSMOS_PER_WORKER,
                "wall_s": round(cos_wall, 3), "latency": cos_stats,
                "status_counts": {str(k): v for k, v in cos.status_counts.items()},
                "errors": len(cos.errors),
            },
            "cas_race": {
                "workers": CAS_WORKERS, "per_worker": CAS_PER_WORKER,
                "resource_id": f"/subscriptions/{SUB_ID}/resourceGroups/{rg_name}",
                "wall_s": round(cas_wall, 3), "latency": cas_stats,
                "status_counts": {str(k): v for k, v in cas.status_counts.items()},
                "errors": len(cas.errors),
            },
            "verdict": "PASS" if ok else "FAIL",
            "failures": failures,
        }
        with open(RECEIPT_PATH, "w") as f:
            f.write(json.dumps(receipt, indent=2))
        print(f"[BENCH] receipt written: {RECEIPT_PATH}")
        if not ok:
            sys.exit(1)
    finally:
        kill_substrate(proc)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        sys.exit(1)

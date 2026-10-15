#!/usr/bin/env python3
"""Smalt spike-stress harness (stdlib-only, fail-closed).

Boots the substrate once, then:

  1. Spike probe   : instant 500 concurrent client threads, each doing 5 ARM
                     PUTs (token pre-minted once, up front). Measures accept
                     latency (barrier release -> first response byte of the
                     client's first request), per-request first-byte latency
                     p50/p95/p99, queue-drop / connection-refused count, and
                     error classes.
  2. Recovery      : 10 spike cycles back-to-back with 5s idle between them;
                     after each cycle a single post-spike ARM request must
                     complete in < 100ms (recovery assertion).
  3. TLS herd      : 100 parallel TLS handshakes against the ARM TLS twin on
                     9444 (dev cert auto-minted by Smalt.TLS.ensure_dev_cert/0).

Budgets: spike p95 < 2s under spike; zero 5xx anywhere; post-spike single
request < 100ms after every cycle. Receipt:
tmp/spike-receipt.json (schema smalt-spike/v1). Exit 0 only if all budgets hold.
"""
import http.client
import json
import os
import signal
import socket
import ssl
import statistics
import subprocess
import sys
import threading
import time

import _substrate

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = "127.0.0.1"
# Own private block (DEV_LOOP table) — the old defaults were the front door
# and reused SMALT_BENCH_* env names, so a spike run contended `just bench`.
ARM_PORT = int(os.environ.get("SMALT_SPIKE_ARM_PORT", "39510"))
DATA_PORT = int(os.environ.get("SMALT_SPIKE_EGRESS_PORT", "39511"))
TLS_PORT = int(os.environ.get("SMALT_SPIKE_TLS_PORT", "39512"))
AMQP_PORT = int(os.environ.get("SMALT_SPIKE_AMQP_PORT", "39513"))
EVENT_HUBS_PORT = AMQP_PORT + 1
MCP_PORT = int(os.environ.get("SMALT_SPIKE_MCP_PORT", "39515"))
SUB_ID = "spike-sub"
API_VERSION = "2021-01-01"

SPIKE_CLIENTS = 500
REQS_PER_CLIENT = 5
SPIKE_CYCLES = 10
IDLE_S = 5.0
TLS_CLIENTS = 100

P95_TARGET_MS = 2000.0      # p95 < 2s under spike
RECOVERY_TARGET_MS = 100.0  # post-spike single request < 100ms

SCHEMA = "smalt-spike/v1"
RECEIPT_PATH = os.path.join(REPO, "tmp", "spike-receipt.json")


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(code)


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


def stats_dict(vals):
    n = len(vals)
    if n == 0:
        return {"n": 0}
    s = sorted(vals)
    return {
        "n": n,
        "min_ms": round(s[0], 3),
        "p50_ms": round(statistics.median(s), 3),
        "p95_ms": round(pct(s, 95), 3),
        "p99_ms": round(pct(s, 99), 3),
        "max_ms": round(s[-1], 3),
    }


def classify_error(exc):
    text = repr(exc)
    lowered = text.lower()
    if "connectionrefused" in lowered or "refused" in lowered:
        return "connection-refused"
    if "connectionreset" in lowered or "reset" in lowered or "remoteparty" in lowered:
        return "connection-reset"
    if "timed out" in lowered or "timeout" in lowered:
        return "timeout"
    if "certificate" in lowered or "ssl" in lowered:
        return "tls"
    if "brokenpipe" in lowered:
        return "broken-pipe"
    return "other"


def spawn_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    # Ports are overridable via env so the spike can run against its own
    # substrate on private high ports when another lane holds 9443/8443/9444.
    eval_code = (
        'Application.put_env(:smalt, :arm_port, '
        f'{ARM_PORT}); '
        'Application.put_env(:smalt, :egress_port, '
        f'{DATA_PORT}); '
        'Application.put_env(:smalt, :arm_tls_port, '
        f'{TLS_PORT}); '
        f'Application.put_env(:smalt, :amqp_port, {AMQP_PORT}); '
        f'Application.put_env(:smalt, :event_hubs_port, {EVENT_HUBS_PORT}); '
        f'Application.put_env(:smalt, :mcp_port, {MCP_PORT}); '
        'Application.ensure_all_started(:smalt)'
    )
    return subprocess.Popen(
        ["mix", "run", "--no-start", "--no-halt", "--eval", eval_code],
        cwd=REPO,
        env=env,
        stdout=open(os.path.join(REPO, "tmp", "spike-substrate.log"), "wb"),
        stderr=subprocess.STDOUT,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )


def port_open(port, timeout=0.25):
    return _substrate.port_open(port, timeout=timeout)


def wait_for_port(port, proc, timeout_s=120.0):
    return _substrate.wait_for_port(port, proc=proc, timeout_s=timeout_s,
                                    fail=fail_closed, poll=0.05)


def kill_substrate(proc):
    if proc is None:
        return
    _substrate.kill_substrate(proc, ports=(ARM_PORT, DATA_PORT, AMQP_PORT, TLS_PORT, EVENT_HUBS_PORT, MCP_PORT))


def fetch_bearer_token(port, timeout_s=10):
    body = ("grant_type=client_credentials&client_id=spike-client"
            "&client_secret=spike-secret"
            "&scope=https%3A%2F%2Fmanagement.azure.com%2F.default")
    conn = http.client.HTTPConnection(HOST, port, timeout=timeout_s)
    try:
        conn.request("POST", "/oauth2/v2.0/token", body=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        payload = resp.read()
        if resp.status != 200 or b"access_token" not in payload:
            fail_closed(f"STS token fetch returned {resp.status}: {payload[:200]}")
        return json.loads(payload)["access_token"]
    finally:
        conn.close()


def single_arm_request(token, path, body):
    """One fresh-connection ARM PUT; returns (status, elapsed_ms) or raises."""
    t0 = time.perf_counter()
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10.0)
    try:
        conn.request("PUT", path, body=body, headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        resp.read()
        return resp.status, (time.perf_counter() - t0) * 1000.0
    finally:
        conn.close()


class SpikeResult:
    """Thread-safe collector for one spike cycle."""

    def __init__(self):
        self.lock = threading.Lock()
        self.accept_latencies = []   # barrier release -> first byte (ms), per client
        self.first_byte = []         # per-request first-byte latency (ms)
        self.status_counts = {}
        self.error_classes = {}

    def record_accept(self, ms):
        with self.lock:
            self.accept_latencies.append(ms)

    def record_request(self, fb_ms, status):
        with self.lock:
            self.first_byte.append(fb_ms)
            self.status_counts[status] = self.status_counts.get(status, 0) + 1

    def record_error(self, class_):
        with self.lock:
            self.error_classes[class_] = self.error_classes.get(class_, 0) + 1


def spike_worker(wid, res, barrier, token):
    body = json.dumps({"location": "spike"})
    base = f"/subscriptions/{SUB_ID}/resourceGroups/rg-spike-{wid}"
    conn = None
    try:
        barrier.wait()
        t0 = time.perf_counter()
        conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=20.0)
        conn.connect()
        for i in range(REQS_PER_CLIENT):
            path = f"{base}-{i}?api-version={API_VERSION}"
            t_req = time.perf_counter()
            conn.request("PUT", path, body=body, headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {token}",
                "Content-Length": str(len(body)),
            })
            resp = conn.getresponse()
            resp.read()
            fb = (time.perf_counter() - t_req) * 1000.0
            res.record_request(fb, resp.status)
        res.record_accept((time.perf_counter() - t0) * 1000.0)
    except Exception as exc:
        res.record_error(classify_error(exc))
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def run_spike_cycle(token):
    """One spike cycle: barrier-synchronized 500 clients x 5 requests."""
    res = SpikeResult()
    barrier = threading.Barrier(SPIKE_CLIENTS + 1)
    threads = [threading.Thread(target=spike_worker,
                                args=(w, res, barrier, token), daemon=True)
               for w in range(SPIKE_CLIENTS)]
    for t in threads:
        t.start()
    barrier.wait()
    wall_start = time.monotonic()
    for t in threads:
        t.join()
    wall_s = time.monotonic() - wall_start
    return res, wall_s


def run_tls_herd(token_unused=None):
    """100 parallel TLS handshakes + one https request each on 9444."""
    ctx = ssl._create_unverified_context()
    res = SpikeResult()
    barrier = threading.Barrier(TLS_CLIENTS + 1)
    threads = []
    for w in range(TLS_CLIENTS):
        def one(w=w, res=res, barrier=barrier, ctx=ctx):
            conn = None
            try:
                barrier.wait()
                t0 = time.perf_counter()
                conn = http.client.HTTPSConnection(HOST, TLS_PORT, timeout=20.0,
                                                   context=ctx)
                conn.request("GET", "/subscriptions?api-version=2021-01-01",
                             headers={"Authorization": "Bearer spike-tls-probe"})
                resp = conn.getresponse()
                resp.read()
                res.record_request((time.perf_counter() - t0) * 1000.0, resp.status)
            except Exception as exc:
                res.record_error(classify_error(exc))
            finally:
                if conn is not None:
                    try:
                        conn.close()
                    except Exception:
                        pass
        t = threading.Thread(target=one, daemon=True)
        threads.append(t)
    for t in threads:
        t.start()
    barrier.wait()
    for t in threads:
        t.join()
    return res


def print_receipt_table(receipt):
    cfg = receipt["config"]
    print("\n================ SPIKE RECEIPT ================")
    print(f"clients/cycle : {cfg['spike_clients']} x "
          f"{cfg['reqs_per_client']} reqs, {cfg['cycles']} cycles, "
          f"idle {cfg['idle_s']}s")
    print(f"{'cycle':>5} {'wall_s':>8} {'p50_ms':>9} {'p95_ms':>9} {'p99_ms':>9} "
          f"{'max_ms':>9} {'5xx':>4} {'errors':>7} {'recov_ms':>9} {'ok':>4}")
    for cyc in receipt["spike_cycles"]:
        st = cyc["first_byte"]
        print(f"{cyc['cycle']:>5} {cyc['wall_s']:>8.3f} "
              f"{st.get('p50_ms', float('nan')):>9.1f} "
              f"{st.get('p95_ms', float('nan')):>9.1f} "
              f"{st.get('p99_ms', float('nan')):>9.1f} "
              f"{st.get('max_ms', float('nan')):>9.1f} "
              f"{cyc['five_xx']:>4} {cyc['error_total']:>7} "
              f"{cyc['recovery_ms'] if cyc['recovery_ms'] is not None else float('nan'):>9.1f} "
              f"{'PASS' if cyc['recovery_ok'] else 'FAIL':>4}")
    tls = receipt["tls_herd"]
    print(f"TLS herd (9444): n={tls['first_byte'].get('n', 0)} "
          f"p50={tls['first_byte'].get('p50_ms', float('nan')):.1f}ms "
          f"p99={tls['first_byte'].get('p99_ms', float('nan')):.1f}ms "
          f"5xx={tls['five_xx']} errors={tls['error_total']}")
    print(f"totals        : requests={receipt['totals']['requests']} "
          f"5xx={receipt['totals']['five_xx']} "
          f"transport_errors={receipt['totals']['transport_errors']}")
    print(f"verdict       : {receipt['verdict']}")
    print("================================================")


def main():
    if subprocess.run(["which", "mix"], capture_output=True).returncode != 0:
        fail_closed("mix not in PATH")
    for port in (ARM_PORT, DATA_PORT, TLS_PORT, AMQP_PORT, EVENT_HUBS_PORT, MCP_PORT):
        if port_open(port):
            holder = subprocess.run(
                ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
                capture_output=True, text=True).stdout.strip()
            fail_closed(f"port {port} already in use: {holder}")

    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)
    watchdog = threading.Timer(1200.0,
                               lambda: (print("[FAULT] watchdog: 20min budget "
                                              "exceeded", file=sys.stderr),
                                        os._exit(1)))
    watchdog.daemon = True
    watchdog.start()

    proc = spawn_substrate()
    try:
        wait_for_port(ARM_PORT, proc)
        wait_for_port(DATA_PORT, proc)
        print(f"[SPIKE] substrate up (arm :{ARM_PORT} data :{DATA_PORT})")
        token = fetch_bearer_token(ARM_PORT)
        print("[SPIKE] STS bearer token pre-minted")

        cycles = []
        totals_req = 0
        totals_5xx = 0
        totals_err = 0
        total_start = time.monotonic()
        for c in range(1, SPIKE_CYCLES + 1):
            res, wall_s = run_spike_cycle(token)
            fb = stats_dict(res.first_byte)
            five_xx = sum(v for k, v in res.status_counts.items() if 500 <= k < 600)
            err_total = sum(res.error_classes.values())
            # recovery probe: single fresh-connection request, budget < 100ms
            rec_path = f"/subscriptions/{SUB_ID}/resourceGroups/rg-recov-{c}?api-version={API_VERSION}"
            try:
                _, rec_ms = single_arm_request(token, rec_path,
                                               json.dumps({"location": "spike-recovery"}))
                rec_ok = rec_ms < RECOVERY_TARGET_MS
                rec_err = None
            except Exception as exc:
                rec_ms = float("nan")
                rec_ok = False
                rec_err = classify_error(exc)
            cycles.append({
                "cycle": c,
                "wall_s": round(wall_s, 3),
                "first_byte": fb,
                "accept": stats_dict(res.accept_latencies),
                "status_counts": {str(k): v for k, v in sorted(res.status_counts.items())},
                "five_xx": five_xx,
                "error_classes": res.error_classes,
                "error_total": err_total,
                "recovery_ms": round(rec_ms, 3) if rec_err is None else None,
                "recovery_ok": rec_ok,
            })
            totals_req += len(res.first_byte)
            totals_5xx += five_xx
            totals_err += err_total
            print(f"[SPIKE] cycle {c:>2}/{SPIKE_CYCLES}: wall {wall_s:.2f}s "
                  f"p95 {fb.get('p95_ms', float('nan')):.0f}ms "
                  f"p99 {fb.get('p99_ms', float('nan')):.0f}ms "
                  f"5xx {five_xx} errors {err_total} "
                  f"classes {res.error_classes} recovery {rec_ms:.0f}ms "
                  f"{'OK' if rec_ok else 'FAIL'}")
            if c < SPIKE_CYCLES:
                time.sleep(IDLE_S)

        print("[SPIKE] TLS herd: 100 parallel handshakes on 9444")
        tls_res = run_tls_herd()
        tls_fb = stats_dict(tls_res.first_byte)
        tls_5xx = sum(v for k, v in tls_res.status_counts.items() if 500 <= k < 600)
        tls = {
            "clients": TLS_CLIENTS,
            "first_byte": tls_fb,
            "status_counts": {str(k): v for k, v in sorted(tls_res.status_counts.items())},
            "five_xx": tls_5xx,
            "error_classes": tls_res.error_classes,
            "error_total": sum(tls_res.error_classes.values()),
        }
        totals_req += tls_fb.get("n", 0)
        totals_5xx += tls_5xx
        totals_err += tls["error_total"]

        cycle_p95s = [cyc["first_byte"].get("p95_ms", float("inf"))
                      for cyc in cycles]
        p95_overall = max(cycle_p95s) if cycle_p95s else float("nan")
        all_recov_ok = all(cyc["recovery_ok"] for cyc in cycles)
        verdict_pass = (totals_5xx == 0
                        and all_recov_ok
                        and p95_overall < P95_TARGET_MS
                        and totals_err == 0)
        receipt = {
            "schema": SCHEMA,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "host": HOST,
            "config": {
                "arm_port": ARM_PORT, "data_port": DATA_PORT, "tls_port": TLS_PORT,
                "spike_clients": SPIKE_CLIENTS,
                "reqs_per_client": REQS_PER_CLIENT,
                "cycles": SPIKE_CYCLES, "idle_s": IDLE_S,
                "tls_clients": TLS_CLIENTS,
                "budgets": {"spike_p95_ms": P95_TARGET_MS,
                            "post_spike_ms": RECOVERY_TARGET_MS,
                            "five_xx": 0},
            },
            "spike_cycles": cycles,
            "tls_herd": tls,
            "totals": {"requests": totals_req, "five_xx": totals_5xx,
                       "transport_errors": totals_err,
                       "wall_s": round(time.monotonic() - total_start, 3)},
            "verdict": ("PASS" if verdict_pass
                        else f"FAIL (max cycle p95={p95_overall:.1f}ms, "
                             f"5xx={totals_5xx}, errors={totals_err}, "
                             f"recovery_all_ok={all_recov_ok})"),
        }
        with open(RECEIPT_PATH, "w") as f:
            json.dump(receipt, f, indent=2)
        print_receipt_table(receipt)
        sys.exit(0 if verdict_pass else 1)
    finally:
        kill_substrate(proc)
        watchdog.cancel()


if __name__ == "__main__":
    main()

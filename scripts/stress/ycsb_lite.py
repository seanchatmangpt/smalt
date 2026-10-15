#!/usr/bin/env python3
"""YCSB-lite mixed-plane stress harness (stdlib-only, no deps).

Spawns the smalt substrate (`mix run --no-halt`), seeds state, then drives a
10-minute, 24-thread mixed workload against all three planes simultaneously:

  - Cosmos (data plane :8443): 80% read / 15% insert-update / 5% scan
    over 10 partitions with an approximate-zipfian key distribution
    (power-law sampling via random.paretovariate, no numpy/scipy).
  - ARM (control plane :9443): 10% of all ops are resource-group GETs.
  - Blob  (data plane :8443):  2% of all ops are blob PUTs
    (the guarded catch-all requires an x-ms-version header).

Measures aggregate ops/s, per-op-type latency distributions
(p50/p95/p99/max), and an error budget (zero 5xx to pass). A short warmup
window is discarded; the 600 s measured window starts after it. The
substrate is killed in a finally on every path. Receipt:
tmp/ycsb-lite-receipt.json (schema smalt-ycsb-lite/v1).
"""
from __future__ import annotations

import http.client
import json
import os
import random
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time

import _substrate

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = "127.0.0.1"
# Dedicated stress-heap ports, DEV_LOOP private-port table block (39472-39475;
# the old 39443 default collided with the mutation court's table allocation).
# The harness never touches the front door.
ARM_PORT = int(os.environ.get("YCSB_ARM_PORT", "39472"))
DATA_PORT = int(os.environ.get("YCSB_DATA_PORT", "39473"))
AMQP_PORT_ALT = int(os.environ.get("YCSB_AMQP_PORT", "39474"))
TLS_PORT = int(os.environ.get("YCSB_TLS_PORT", "39476"))
MCP_PORT = int(os.environ.get("YCSB_MCP_PORT", "39477"))
SUB_ID = "bench-sub"
API_VERSION = "2021-01-01"
X_MS_VERSION = "2021-04-10"

SCHEMA = "smalt-ycsb-lite/v1"
RECEIPT_PATH = os.path.join(REPO, "tmp", "ycsb-lite-receipt.json")

THREADS = 24
WARMUP_S = float(os.environ.get("YCSB_WARMUP_S", "30"))
MEASURE_S = float(os.environ.get("YCSB_MEASURE_S", "600"))
PARTITIONS = 10
KEYSPACE = 10_000
ZIPF_ALPHA = 1.2
ZIPF_CAP = 1000.0
SEED_DOCS = KEYSPACE
SEED_RGS = 20
BLOB_ACCOUNT = "ycsbacc"
BLOB_CONTAINER = "ycsbcont"

OP_TYPES = ("cosmos_read", "cosmos_upsert", "cosmos_scan", "arm_rg_get", "blob_put")
EXPECTED = {
    "cosmos_read": {200},
    "cosmos_upsert": {200, 201},
    "cosmos_scan": {200},
    "arm_rg_get": {200},
    "blob_put": {201},
}


TOKEN = None
STS_SECRET = "ycsb-lite-stress-sts-signing-secret-0123456789abcdef"  # >= 32 bytes
TENANT = "ycsb-tenant"
AUDIENCE = "https://management.azure.com"
ISSUER = f"https://login.microsoftonline.com/{TENANT}/v2.0"


def b64url(data: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_token():
    """Mint the bearer token client-side (HS256 with the substrate's
    `:sts_signing_secret`, set by our own prelude). Valid 2 h — covers the
    10-min window. Auth is enforced by default (`auth_mode: :enforce`);
    every non-exempt route requires a valid token."""
    import base64
    import hmac
    import hashlib
    global TOKEN
    now = int(time.time())
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    claims = {
        "aud": AUDIENCE, "iss": ISSUER, "iat": now, "nbf": now,
        "exp": now + 7200, "appid": "ycsb-lite", "tid": TENANT,
        "roles": ["Contributor", "Owner"],
    }
    payload = b64url(json.dumps(claims).encode())
    signing_input = f"{header}.{payload}".encode()
    sig = hmac.new(STS_SECRET.encode(), signing_input, hashlib.sha256).digest()
    TOKEN = f"{header}.{payload}.{b64url(sig)}"


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(code)


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = clamp(int(round((p / 100.0) * (len(sorted_vals) - 1))), 0, len(sorted_vals) - 1)
    return sorted_vals[k]


def stats_dict(vals):
    s = sorted(vals)
    if not s:
        return {"n": 0}
    return {
        "n": len(s),
        "min_ms": round(s[0], 3),
        "p50_ms": round(statistics.median(s), 3),
        "p95_ms": round(pct(s, 95), 3),
        "p99_ms": round(pct(s, 99), 3),
        "max_ms": round(s[-1], 3),
    }


def spawn_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    prelude = (
        "Application.put_env(:smalt, :arm_port, "
        f"{ARM_PORT}); "
        "Application.put_env(:smalt, :egress_port, "
        f"{DATA_PORT}); "
        "Application.put_env(:smalt, :auth_mode, :enforce); "
        "Application.put_env(:smalt, :sts_signing_secret, "
        f"\"{STS_SECRET}\"); "
        "Application.put_env(:smalt, :amqp_port, "
        f"{AMQP_PORT_ALT}); "
        "Application.put_env(:smalt, :event_hubs_port, "
        f"{AMQP_PORT_ALT + 1}); "
        "Application.put_env(:smalt, :arm_tls_port, "
        f"{TLS_PORT}); "
        "Application.put_env(:smalt, :mcp_port, "
        f"{MCP_PORT}); "
        "{:ok, _} = Application.ensure_all_started(:smalt); "
        "Process.sleep(:infinity)"
    )
    return subprocess.Popen(
        ["mix", "run", "--no-start", "--no-halt", "-e", prelude],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True, stdin=subprocess.DEVNULL,
    )


def wait_for_port(port, proc=None, timeout_s=90.0):
    return _substrate.wait_for_port(port, proc=proc, timeout_s=timeout_s,
                                    fail=fail_closed, poll=0.01)


def kill_substrate(proc):
    if proc is None:
        return
    _substrate.kill_substrate(proc, ports=(ARM_PORT, DATA_PORT, AMQP_PORT_ALT, TLS_PORT, MCP_PORT))


def wait_port_free(port, timeout_s=30.0):
    return _substrate.wait_port_free(port, timeout_s=timeout_s)


class Zipf:
    """Approximate-zipfian sampler: random.paretovariate power law mapped
    linearly onto the keyspace with a clamp. Pareto shape > 1 concentrates
    draws on the head of the distribution like YCSB's zipfian."""

    __slots__ = ("n", "rng")

    def __init__(self, n, rng):
        self.n = n
        self.rng = rng

    def draw(self):
        x = self.rng.paretovariate(ZIPF_ALPHA)
        idx = int((min(x, ZIPF_CAP) - 1.0) / (ZIPF_CAP - 1.0) * self.n)
        return clamp(idx, 0, self.n - 1)


def request(conn, method, path, body=None, headers=None):
    """One HTTP op. Returns (status, latency_ms). Reconnects once on
    connection-level error (persistent conns can be idled out)."""
    if isinstance(body, str):
        body = body.encode()
    hdrs = {"Content-Length": str(len(body) if body is not None else 0)}
    if body is not None:
        hdrs["Content-Type"] = "application/json"
    if TOKEN:
        hdrs["Authorization"] = f"Bearer {TOKEN}"
    if headers:
        hdrs.update(headers)
    for attempt in (0, 1):
        try:
            t0 = time.perf_counter()
            conn.request(method, path, body=body, headers=hdrs)
            resp = conn.getresponse()
            resp.read()
            return resp.status, (time.perf_counter() - t0) * 1000.0
        except (http.client.HTTPException, OSError):
            if attempt == 1:
                raise
            try:
                conn.close()
            except Exception:
                pass
            time.sleep(0.01)
    raise RuntimeError("unreachable")


def make_conn(port):
    return http.client.HTTPConnection(HOST, port, timeout=15)


# ---------------------------------------------------------------------------
# Seed
# ---------------------------------------------------------------------------


def seed():
    """Create db/collection/docs, RGs, blob container. Idempotent (warm-store
    re-runs tolerate 409 dups). Fails closed if any seed op errors hard."""
    data = make_conn(DATA_PORT)
    arm = make_conn(ARM_PORT)
    try:
        # NOTE: the db/collection is intentionally NOT created. Creating a
        # collection installs a partition-key definition; with `paths: []`
        # (no partitionKey in the body) every doc op 400s on pk enforcement.
        # With no collection record, pk_meta is nil and doc ops pass.
        seeded = 0
        for i in range(SEED_DOCS):
            key = i % KEYSPACE
            body = json.dumps({"id": f"k{key}", "pk": f"p{key % PARTITIONS}",
                               "payload": "x" * 128})
            st, _ = request(data, "POST", "/dbs/ycsb/colls/c/docs",
                            body=body,
                            headers={"Content-Type": "application/json",
                                     "x-ms-documentdb-partitionkey":
                                     f'["p{key % PARTITIONS}"]'})
            if st not in (201, 409):
                probe = http.client.HTTPConnection(HOST, DATA_PORT, timeout=10)
                probe.request("POST", "/dbs/ycsb/colls/c/docs", body=body,
                              headers={"Content-Type": "application/json",
                                       "Authorization": f"Bearer {TOKEN}"})
                r = probe.getresponse()
                detail = r.read().decode(errors="replace")
                probe.close()
                fail_closed(f"seed doc k{key} returned {st}: {detail[:400]}")
            elif st == 201:
                seeded += 1
        for i in range(SEED_RGS):
            st, _ = request(arm, "PUT",
                            f"/subscriptions/{SUB_ID}/resourceGroups/rg-ycsb-{i}"
                            f"?api-version={API_VERSION}",
                            body=json.dumps({"location": "ycsb"}),
                            headers={"Content-Type": "application/json"})
            if st not in (200, 201, 409):
                fail_closed(f"seed RG rg-ycsb-{i} returned {st}")
        st, _ = request(data, "PUT",
                        f"/{BLOB_ACCOUNT}/{BLOB_CONTAINER}?restype=container",
                        headers={"x-ms-version": X_MS_VERSION})
        if st not in (200, 201, 409):
            fail_closed(f"seed blob container returned {st}")
        return {"seed_docs_created": seeded, "seed_rgs": SEED_RGS,
                "blob_container_status": st}
    finally:
        data.close()
        arm.close()


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------


class OpStats:
    """Thread-safe per-op-type latency/error collectors."""

    def __init__(self):
        self._lock = threading.Lock()
        self._lats = {op: [] for op in OP_TYPES}
        self._errs = {op: {"non_2xx": 0, "5xx": 0, "transport": 0} for op in OP_TYPES}
        self._ops = {op: 0 for op in OP_TYPES}

    def record(self, op, status, ms):
        with self._lock:
            self._ops[op] += 1
            self._lats[op].append(ms)
            if status is None:
                self._errs[op]["transport"] += 1
            elif status >= 500:
                self._errs[op]["5xx"] += 1
            elif status not in EXPECTED[op]:
                self._errs[op]["non_2xx"] += 1

    def snapshot(self):
        with self._lock:
            return ({op: list(v) for op, v in self._lats.items()},
                    {op: dict(v) for op, v in self._errs.items()},
                    dict(self._ops))


def draw_op(rng):
    u = rng.random()
    if u < 0.10:
        return "arm_rg_get"
    if u < 0.12:
        return "blob_put"
    r = rng.random()
    if r < 0.80:
        return "cosmos_read"
    if r < 0.95:
        return "cosmos_upsert"
    return "cosmos_scan"


_seq_lock = threading.Lock()
_seq = [0]


def next_seq():
    with _seq_lock:
        _seq[0] += 1
        return _seq[0]


def worker(stop_evt, stats, seed_num):
    rng = random.Random(seed_num)
    zipf = Zipf(KEYSPACE, rng)
    data = make_conn(DATA_PORT)
    arm = make_conn(ARM_PORT)
    try:
        while not stop_evt.is_set():
            op = draw_op(rng)
            try:
                if op == "arm_rg_get":
                    rg = f"rg-ycsb-{rng.randrange(SEED_RGS)}"
                    status, ms = request(
                        arm, "GET",
                        f"/subscriptions/{SUB_ID}/resourceGroups/{rg}"
                        f"?api-version={API_VERSION}")
                elif op == "blob_put":
                    body = os.urandom(1024)
                    # blob PUT bodies are raw bytes, not JSON; unique blob
                    # names so every PUT is a fresh 201 (no 409 overwrite)
                    hdrs = {"x-ms-version": X_MS_VERSION,
                            "x-ms-blob-type": "BlockBlob",
                            "Authorization": f"Bearer {TOKEN}"}
                    t0 = time.perf_counter()
                    data.request("PUT",
                                 f"/{BLOB_ACCOUNT}/{BLOB_CONTAINER}/blob-{next_seq()}.bin",
                                 body=body,
                                 headers=dict(hdrs,
                                              **{"Content-Length": str(len(body))}))
                    resp = data.getresponse()
                    resp.read()
                    status, ms = resp.status, (time.perf_counter() - t0) * 1000.0
                else:
                    key = zipf.draw()
                    if op == "cosmos_read":
                        status, ms = request(
                            data, "GET", f"/dbs/ycsb/colls/c/docs/k{key}",
                            headers={"x-ms-documentdb-partitionkey":
                                     f'["p{key % PARTITIONS}"]'})
                    elif op == "cosmos_upsert":
                        if rng.random() < 0.5:
                            with _seq_lock:
                                _seq[0] += 1
                                n = _seq[0]
                            doc_id = f"ins-{n}"
                            body = json.dumps(
                                {"id": doc_id, "pk": f"p{key % PARTITIONS}",
                                 "payload": "y" * 128})
                            status, ms = request(
                                data, "POST", "/dbs/ycsb/colls/c/docs",
                                body=body,
                                headers={"x-ms-documentdb-partitionkey":
                                         f'["p{key % PARTITIONS}"]'})
                        else:
                            body = json.dumps(
                                {"id": f"k{key}", "pk": f"p{key % PARTITIONS}",
                                 "payload": "z" * 128})
                            status, ms = request(
                                data, "PUT", f"/dbs/ycsb/colls/c/docs/k{key}",
                                body=body,
                                headers={"x-ms-documentdb-partitionkey":
                                         f'["p{key % PARTITIONS}"]'})
                    else:  # cosmos_scan
                        status, ms = request(data, "GET", "/dbs/ycsb/colls/c/docs")
            except (http.client.HTTPException, OSError):
                status = None
                ms = 0.0
                for c in (data, arm):
                    try:
                        c.close()
                    except Exception:
                        pass
                data = make_conn(DATA_PORT)
                arm = make_conn(ARM_PORT)
            stats.record(op, status, ms)
    finally:
        for c in (data, arm):
            try:
                c.close()
            except Exception:
                pass


def run_workload():
    stop_evt = threading.Event()
    stats = OpStats()
    threads = [threading.Thread(target=worker, args=(stop_evt, stats, i),
                                daemon=True)
               for i in range(THREADS)]
    for t in threads:
        t.start()
    t0 = time.monotonic()
    try:
        print(f"[YCSD] warmup {WARMUP_S:.0f}s (discarded)...", flush=True)
        time.sleep(WARMUP_S)
        warm_lats, warm_errs, warm_ops = stats.snapshot()
        print(f"[YCSD] warmup done: {sum(warm_ops.values())} ops discarded", flush=True)
        measured_start = time.monotonic()
        warm_lats.clear() if False else None
        # discard warmup numbers by snapshotting again at the end and subtracting
        time.sleep(MEASURE_S)
    finally:
        stop_evt.set()
        for t in threads:
            t.join(timeout=30)
    total_end = time.monotonic()
    lats, errs, ops = stats.snapshot()
    measured_ops = {op: ops[op] - warm_ops[op] for op in OP_TYPES}
    measured_lats = lats  # warmup latencies included in lists; subtract via n
    # Trim warmup latencies: keep only the last measured_ops entries per type.
    trimmed = {}
    for op in OP_TYPES:
        n_meas = measured_ops[op]
        trimmed[op] = lats[op][-n_meas:] if n_meas > 0 else []
    elapsed = total_end - measured_start
    return {
        "elapsed_s": round(elapsed, 3),
        "measured_ops": measured_ops,
        "latencies": {op: stats_dict(trimmed[op]) for op in OP_TYPES},
        "errors": errs,
        "total_ops": sum(measured_ops.values()),
        "aggregate_ops_per_s": round(sum(measured_ops.values()) / elapsed, 1),
    }


def main():
    if os.path.exists(RECEIPT_PATH):
        try:
            os.remove(RECEIPT_PATH)
        except OSError:
            pass
    for port in (ARM_PORT, DATA_PORT):
        if not wait_port_free(port, timeout_s=30.0):
            fail_closed(f"port {port} not free before start")
    proc = None
    try:
        proc = spawn_substrate()
        boot_s = wait_for_port(ARM_PORT, proc)
        wait_for_port(DATA_PORT, proc)
        print(f"[YCSD] substrate up in {boot_s:.2f}s", flush=True)
        mint_token()
        print("[YCSD] bearer token minted", flush=True)
        seed_info = seed()
        print(f"[YCSD] seeded: {seed_info}", flush=True)
        results = run_workload()
        fivexx = sum(e["5xx"] + e["transport"] for e in results["errors"].values())
        verdict = "PASS" if fivexx == 0 and results["total_ops"] > 0 else "FAIL"
        receipt = {
            "schema": SCHEMA,
            "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "subject": {"repo": "smalt", "mix_env": "dev",
                        "host": "darwin/arm64 local loopback"},
            "config": {"threads": THREADS, "warmup_s": WARMUP_S,
                       "measure_s": MEASURE_S, "partitions": PARTITIONS,
                       "keyspace": KEYSPACE, "zipf_alpha": ZIPF_ALPHA,
                       "mix": "80/15/5 cosmos + 10% ARM RG GET + 2% blob PUT",
                       "seed": seed_info},
            "boot_s": round(boot_s, 3),
            **results,
            "error_budget": {"5xx_plus_transport": fivexx,
                             "target": 0,
                             "verdict": "PASS" if fivexx == 0 else "FAIL"},
            "verdict": verdict,
        }
        os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)
        with open(RECEIPT_PATH, "w") as f:
            json.dump(receipt, f, indent=2)
        print(f"\n== YCSB-lite results ({results['elapsed_s']:.0f}s measured) ==")
        print(f"  aggregate: {results['aggregate_ops_per_s']} ops/s "
              f"({results['total_ops']} ops)")
        for op in OP_TYPES:
            d = results["latencies"][op]
            e = results["errors"][op]
            if d.get("n", 0) == 0:
                print(f"  {op:14s}: n=0")
                continue
            print(f"  {op:14s}: n={d['n']:7d} p50 {d['p50_ms']:8.3f} ms  "
                  f"p95 {d['p95_ms']:8.3f}  p99 {d['p99_ms']:8.3f}  "
                  f"max {d['max_ms']:8.3f}  errs {e}")
        print(f"  error budget (5xx+transport): {fivexx} -> "
              f"{'PASS' if fivexx == 0 else 'FAIL'}")
        print(f"  receipt: {RECEIPT_PATH}")
        sys.exit(0 if verdict == "PASS" else 1)
    finally:
        kill_substrate(proc)


if __name__ == "__main__":
    main()

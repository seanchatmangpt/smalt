#!/usr/bin/env python3
"""Smalt ARM-scale stress harness (stdlib-only, fail-closed, Chicago-style:
every measurement is against a real live substrate over real HTTP).

Phases (all against a single spawned substrate):

  1. Create 20,000 resources across 200 resource groups (32 threads)
     -> throughput (rps), PUT p50/p95/p99
  2. LIST latency vs child count: RG collection LIST (200 RGs), and per-RG
     provider-type LIST on RGs holding 10 / 100 / 1000 children
  3. ResourceGraph (POST /providers/Microsoft.ResourceGraph/resources on 8443):
     unfiltered `$top 100` page and subscription-filtered query latency
  4. GET random single resource: 500 samples, p50/p95/p99
     (Store.get on :smalt_resources, a 20k-key :ordered_set)
  5. api-version validation overhead: GET missing vs GET valid vs PUT
     wrong-version rejection latency

BEAM RSS is sampled before/after the load phase. A JSON receipt is written to
tmp/arm-scale-receipt.json; the script exits 0 only when every phase completed
with the expected status codes.
"""
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
import traceback
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = "127.0.0.1"
ARM_PORT = 19443
DATA_PORT = 18443
ARM_TLS_PORT = 19444
SUB_ID = "00000000-0000-0000-0000-000000000000"
RG_API_VERSION = "2021-04-01"          # Microsoft.Resources/resourceGroups latest
RES_TYPE = "Microsoft.EventGrid/topics"  # DefaultShape (needs only `location`), non-LRO
RES_API_VERSION = "2021-04-01"
GRAPH_API_VERSION = "2022-10-01"

N_RGS = 200
N_RESOURCES = 20_000
PUT_THREADS = 32
# per-RG child-count buckets for the LIST-vs-child-count curve.
# 90 RGs @ 10 + 101 RGs @ 100 + 9 RGs @ 1000 = 900 + 10,100 + 9,000 = 20,000
# resources across exactly 200 RGs (10a+100b+1000c=20000, a+b+c=200, c=9).
BUCKETS = {10: 90, 100: 101, 1000: 9}

LIST_REPS = 20
GET_SAMPLES = 500
API_VERSION_REPS = 200

RECEIPT_PATH = os.path.join(REPO, "tmp", "arm-scale-receipt.json")
TOKEN = None


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(code)


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


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


# ---------------------------------------------------------------------------
# substrate lifecycle
# ---------------------------------------------------------------------------
def spawn_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    # Other live lanes may hold the default AMQP ports (5672/5673); route this
    # substrate's AMQP surfaces through free alternate ports via env injection
    # (same mechanism the SDK-smoke harness uses for shifted ports).
    return subprocess.Popen(
        ["mix", "run", "--no-start", "--no-halt", "--eval",
         "Application.put_env(:smalt, :arm_port, 19443); "
         "Application.put_env(:smalt, :arm_tls_port, 19444); "
         "Application.put_env(:smalt, :egress_port, 18443); "
         "Application.put_env(:smalt, :amqp_port, 15672); "
         "Application.put_env(:smalt, :event_hubs_port, 15673); "
         "Application.ensure_all_started(:smalt)"],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )


def wait_for_port(port, proc, timeout_s=120.0):
    t0 = time.monotonic()
    deadline = t0 + timeout_s
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            fail_closed(f"substrate exited rc={proc.poll()} before binding :{port}")
        try:
            with socket.create_connection((HOST, port), timeout=0.25):
                pass
            return time.monotonic() - t0
        except OSError:
            time.sleep(0.02)
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
    for port in (ARM_PORT, DATA_PORT, ARM_TLS_PORT, 15672, 15673):
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


def beam_rss_kb():
    """Total RSS (KB) of every process holding/listening on the substrate ports."""
    pids = set()
    for port in (ARM_PORT, DATA_PORT, ARM_TLS_PORT, 15672, 15673):
        try:
            out = subprocess.run(["lsof", "-ti", f"tcp:{port}"],
                                 capture_output=True, text=True, timeout=10).stdout
        except Exception:
            out = ""
        pids.update(int(p) for p in out.split() if p.isdigit())
    total = 0
    for pid in pids:
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=10).stdout
            total += int(out.strip() or 0)
        except Exception:
            pass
    return total


# ---------------------------------------------------------------------------
# HTTP helpers (per-thread persistent connections)
# ---------------------------------------------------------------------------
_tls = threading.local()


def mint_token():
    """Mint a Bearer token from the substrate's own STS (exempt route)."""
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=15)
    try:
        body = "grant_type=client_credentials&client_id=arm-scale&" \
               "client_secret=arm-scale&scope=https://management.azure.com/.default"
        conn.request("POST", "/oauth2/v2.0/token", body=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            fail_closed(f"token mint -> {resp.status}: {data[:200]!r}")
        tok = json.loads(data).get("access_token")
        if not tok:
            fail_closed("token mint returned no access_token")
        return tok
    finally:
        conn.close()


def _conn():
    c = getattr(_tls, "conn", None)
    if c is None:
        c = http.client.HTTPConnection(HOST, ARM_PORT, timeout=30)
        _tls.conn = c
    return c


def arm_request(method, path, body=None, headers=None, port=ARM_PORT):
    """One request on a per-thread persistent connection. Returns (status, bytes)."""
    c = _conn() if port == ARM_PORT else http.client.HTTPConnection(
        HOST, port, timeout=30)
    hdrs = {"Content-Length": "0"}
    if TOKEN:
        hdrs["Authorization"] = f"Bearer {TOKEN}"
    if headers:
        hdrs.update(headers)
    payload = None
    if body is not None:
        payload = json.dumps(body)
        hdrs["Content-Type"] = "application/json"
        hdrs["Content-Length"] = str(len(payload))
    try:
        try:
            c.request(method, path, body=payload, headers=hdrs)
            resp = c.getresponse()
            data = resp.read()
            return resp.status, data
        except (http.client.HTTPException, OSError):
            # stale keep-alive: reconnect once and retry
            if port == ARM_PORT:
                c.close()
                c = http.client.HTTPConnection(HOST, ARM_PORT, timeout=30)
                _tls.conn = c
                c.request(method, path, body=payload, headers=hdrs)
                resp = c.getresponse()
                data = resp.read()
                return resp.status, data
            raise
    finally:
        if port != ARM_PORT:
            c.close()


def arm_put(path, body):
    status, data = arm_request("PUT", path, body=body)
    if status not in (200, 201):
        fail_closed(f"PUT {path} -> {status}: {data[:200]!r}")
    return status


# ---------------------------------------------------------------------------
# phases
# ---------------------------------------------------------------------------
def plan_rgs():
    """Return list of (rg_name, child_count). Deterministic naming."""
    plan = []
    idx = 0
    for count, n_rgs in sorted(BUCKETS.items()):
        for _ in range(n_rgs):
            plan.append((f"rg-scale-{idx:04d}", count))
            idx += 1
    while len(plan) < N_RGS:
        plan.append((f"rg-scale-{idx:04d}", 0))
        idx += 1
    return plan


def phase1_create(plan):
    print(f"[SCALE] Phase 1: PUT {N_RGS} resource groups")
    t0 = time.monotonic()
    for name, _ in plan:
        arm_put(
            f"/subscriptions/{SUB_ID}/resourcegroups/{name}"
            f"?api-version={RG_API_VERSION}",
            {"location": "scale"},
        )
    rg_put_s = time.monotonic() - t0
    print(f"  200 RG PUTs in {rg_put_s:.2f}s ({N_RGS / rg_put_s:.0f} rps)")

    targets = []
    for name, count in plan:
        for i in range(count):
            targets.append((name, i))
    random.Random(42).shuffle(targets)
    assert len(targets) == N_RESOURCES, f"plan yields {len(targets)} resources"

    lat = []
    lat_lock = threading.Lock()
    errors = []
    done = [0]

    def worker(chunk):
        local = []
        for name, i in chunk:
            path = (f"/subscriptions/{SUB_ID}/resourceGroups/{name}/providers/"
                    f"{RES_TYPE.replace('/', '/')}/{name}-res-{i:05d}"
                    f"?api-version={RES_API_VERSION}")
            t = time.perf_counter()
            try:
                status, data = arm_request("PUT", path, body={"location": "scale"})
                dt = (time.perf_counter() - t) * 1000.0
                if status not in (200, 201):
                    errors.append(f"{path} -> {status} {data[:120]!r}")
                    continue
                local.append(dt)
            except Exception as exc:
                errors.append(f"{path} -> {exc!r}")
            with lat_lock:
                done[0] += 1
                if done[0] % 4000 == 0:
                    print(f"  ... {done[0]}/{N_RESOURCES}")

        with lat_lock:
            lat.extend(local)

    t0 = time.monotonic()
    chunks = [targets[i::PUT_THREADS] for i in range(PUT_THREADS)]
    with ThreadPoolExecutor(max_workers=PUT_THREADS) as ex:
        list(ex.map(worker, chunks))
    wall = time.monotonic() - t0
    if errors:
        fail_closed(f"{len(errors)} resource PUTs failed; first: {errors[0]}")
    if done[0] != N_RESOURCES:
        fail_closed(f"only {done[0]}/{N_RESOURCES} PUTs completed")

    print(f"  {N_RESOURCES} resource PUTs in {wall:.2f}s "
          f"({N_RESOURCES / wall:.0f} rps, {PUT_THREADS} threads)")
    return {
        "rg_puts": {"count": N_RGS, "wall_s": round(rg_put_s, 3)},
        "resource_puts": {
            "count": N_RESOURCES,
            "threads": PUT_THREADS,
            "wall_s": round(wall, 3),
            "rps": round(N_RESOURCES / wall, 1),
            "latency_ms": stats_dict(lat),
        },
    }


def phase2_lists(plan):
    print("[SCALE] Phase 2: LIST latency (RG collection + per-RG provider lists)")
    out = {}

    # RG collection LIST: the router returns all 200 RGs in one page.
    lats = []
    for _ in range(LIST_REPS):
        t = time.perf_counter()
        status, data = arm_request(
            "GET", f"/subscriptions/{SUB_ID}/resourcegroups?api-version={RG_API_VERSION}")
        dt = (time.perf_counter() - t) * 1000.0
        if status != 200:
            fail_closed(f"RG list -> {status}")
        body = json.loads(data)
        if len(body.get("value", [])) != N_RGS:
            fail_closed(f"RG list returned {len(body.get('value', []))} rgs, expected {N_RGS}")
        lats.append(dt)
    out["rg_list_all"] = {
        "note": "router returns all RGs in one page (no $top paging on this route)",
        "entries": N_RGS,
        "pages": 1,
        "latency_ms": stats_dict(lats),
    }
    print(f"  RG collection LIST (all {N_RGS} in one page): "
          f"p50 {out['rg_list_all']['latency_ms']['median']}ms")

    # per-RG provider-type LIST vs child count
    by_bucket = {}
    for name, count in plan:
        by_bucket.setdefault(count, []).append(name)
    curve = {}
    for count in sorted(BUCKETS):
        names = by_bucket.get(count, [])
        if not names:
            continue
        picks = (names if len(names) <= 3
                 else random.Random(7).sample(names, 3))
        lats = []
        got = None
        for name in picks:
            for _ in range(LIST_REPS):
                t = time.perf_counter()
                status, data = arm_request(
                    "GET",
                    f"/subscriptions/{SUB_ID}/resourceGroups/{name}/providers/"
                    f"{RES_TYPE}?api-version={RES_API_VERSION}")
                dt = (time.perf_counter() - t) * 1000.0
                if status != 200:
                    fail_closed(f"provider list {name} -> {status}")
                got = len(json.loads(data).get("value", []))
                lats.append(dt)
        curve[str(count)] = {
            "rgs_sampled": len(picks),
            "children_expected": count,
            "children_returned": got,
            "latency_ms": stats_dict(lats),
        }
        print(f"  provider LIST @ {count:>5} children: "
              f"p50 {curve[str(count)]['latency_ms']['median']}ms  "
              f"p99 {curve[str(count)]['latency_ms']['p99']}ms  "
              f"({got} returned)")
    out["provider_list_vs_children"] = curve
    return out


def phase3_resource_graph():
    print("[SCALE] Phase 3: ResourceGraph query latency (port 8443)")
    out = {}

    def run(label, body, reps=LIST_REPS):
        lats = []
        last = None
        for _ in range(reps):
            t = time.perf_counter()
            status, data = arm_request(
                "POST",
                f"/providers/Microsoft.ResourceGraph/resources?api-version={GRAPH_API_VERSION}",
                body=body, port=DATA_PORT)
            dt = (time.perf_counter() - t) * 1000.0
            if status != 200:
                fail_closed(f"ResourceGraph {label} -> {status}: {data[:200]!r}")
            last = json.loads(data)
            lats.append(dt)
        out[label] = {
            "count": last.get("count"),
            "totalRecords": last.get("totalRecords"),
            "has_skip_token": "$skipToken" in last,
            "latency_ms": stats_dict(lats),
        }
        print(f"  {label}: count={last.get('count')} "
              f"total={last.get('totalRecords')} "
              f"p50 {out[label]['latency_ms']['median']}ms "
              f"p99 {out[label]['latency_ms']['p99']}ms")

    run("unfiltered_top100", {"$top": 100})
    run("subscription_filtered", {"subscriptions": [SUB_ID], "$top": 100})
    run("subscription_filtered_lowercase", {"subscriptions": [SUB_ID.lower()], "$top": 100})
    return out


def phase4_get_single(plan):
    print(f"[SCALE] Phase 4: GET random single resource x{GET_SAMPLES}")
    populated = [(n, c) for n, c in plan if c > 0]
    rng = random.Random(123)
    lats = []
    for i in range(GET_SAMPLES):
        name, count = populated[rng.randrange(len(populated))]
        j = rng.randrange(count)
        path = (f"/subscriptions/{SUB_ID}/resourceGroups/{name}/providers/"
                f"{RES_TYPE}/{name}-res-{j:05d}?api-version={RES_API_VERSION}")
        t = time.perf_counter()
        status, data = arm_request("GET", path)
        dt = (time.perf_counter() - t) * 1000.0
        if status != 200:
            fail_closed(f"GET {path} -> {status}")
        lats.append(dt)
    stats = stats_dict(lats)
    print(f"  GET single: p50 {stats['median']}ms  p95 {stats['p95']}ms  p99 {stats['p99']}ms")
    return {"samples": GET_SAMPLES, "latency_ms": stats}


def phase5_api_version(plan):
    print(f"[SCALE] Phase 5: api-version validation overhead x{API_VERSION_REPS}")
    name, count = next((n, c) for n, c in plan if c >= 1)
    base = (f"/subscriptions/{SUB_ID}/resourceGroups/{name}/providers/"
            f"{RES_TYPE}/{name}-res-00000")

    def measure(path, method="GET", body=None, expect=None):
        lats = []
        for _ in range(API_VERSION_REPS):
            t = time.perf_counter()
            status, data = arm_request(method, path, body=body)
            dt = (time.perf_counter() - t) * 1000.0
            if expect is not None and status != expect:
                fail_closed(f"{method} {path} -> {status} (expected {expect}): {data[:160]!r}")
            lats.append(dt)
        return stats_dict(lats)

    out = {
        "get_valid": measure(f"{base}?api-version={RES_API_VERSION}", expect=200),
        "get_missing": measure(base, expect=400),
        # GET validation (type=nil) admits any api-version value, so a
        # malformed *value* is only rejected on typed routes: measure the PUT
        # rejection path (InvalidApiVersionParameter) instead.
        "put_wrong_version": measure(
            f"{base}?api-version=1999-09-09",
            method="PUT", body={"location": "scale"}, expect=400),
    }
    for k, v in out.items():
        print(f"  {k}: p50 {v['median']}ms  p99 {v['p99']}ms")
    overhead = out["get_valid"]["median"] - out["get_missing"]["median"]
    out["validation_overhead_ms"] = round(overhead, 3)
    print(f"  GET valid-vs-missing median delta: {overhead:+.3f}ms")
    return out


def main():
    if sys.version_info < (3, 9):
        fail_closed("python >= 3.9 required")
    import shutil
    if shutil.which("mix") is None:
        fail_closed("mix not in PATH")

    for port in (ARM_PORT, DATA_PORT):
        try:
            socket.create_connection((HOST, port), timeout=0.3).close()
            fail_closed(f"port {port} already in use — stop the running substrate first")
        except OSError:
            pass

    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)
    proc = spawn_substrate()
    try:
        wait_for_port(ARM_PORT, proc)
        wait_for_port(DATA_PORT, proc)

        global TOKEN
        TOKEN = mint_token()
        print("[SCALE] bearer token minted from substrate STS")

        plan = plan_rgs()
        rss_before = beam_rss_kb()
        print(f"[SCALE] RSS before load: {rss_before} KB")

        put_results = phase1_create(plan)
        rss_after = beam_rss_kb()
        print(f"[RSS] after 20k PUTs: {rss_after} KB "
              f"(delta {rss_after - rss_before:+d} KB)")

        lists = phase2_lists(plan)
        graph = phase3_resource_graph()
        gets = phase4_get_single(plan)
        apiv = phase5_api_version(plan)

        receipt = {
            "schema": "smalt-arm-scale/v1",
            "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "host": "darwin/arm64 local",
            "config": {
                "subscriptions": [SUB_ID],
                "resource_groups": N_RGS,
                "resources": N_RESOURCES,
                "put_threads": PUT_THREADS,
                "resource_type": RES_TYPE,
                "bucket_plan": {str(k): v for k, v in BUCKETS.items()},
            },
            "rss_kb": {"before_load": rss_before, "after_load": rss_after,
                       "delta": rss_after - rss_before},
            "phase1_create": put_results,
            "phase2_lists": lists,
            "phase3_resource_graph": graph,
            "phase4_get_single": gets,
            "phase5_api_version": apiv,
        }
        with open(RECEIPT_PATH, "w") as f:
            f.write(json.dumps(receipt, indent=2))
        print(f"[SCALE] receipt written: {RECEIPT_PATH}")
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

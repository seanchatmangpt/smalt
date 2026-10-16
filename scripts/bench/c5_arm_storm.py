#!/usr/bin/env python3
"""C-5 ARM control-plane saturation storm at the smalt ARM gateway.

Sibling of scripts/bench/b6_lro_sdk.py (B-6, isolated LRO tier); C-5 adds the
saturation dimension: mixed read storms, concurrent write/read interference,
LRO-under-load vs the B-6 isolated baseline, and a rate-limit probe.

Phases:
  1  READ STORM: 2000 mixed reads (subscription get, subscriptions list,
     resourcegroups list, providers list, resources list) across 16 threads
     on raw persistent TLS connections: ops/s + p50/p95/p99.
  2  WRITE+READ MIX: continuous 16-thread read storm while 60 RG
     create+delete writes run concurrently. Write op latency under read
     pressure vs its isolated baseline (control-plane interference check).
  3  LRO UNDER LOAD: 50 storageAccount LRO PUTs (SDK pollers, the real smalt
     LRO type per router lro_type?) while the read storm continues:
     poll-to-terminal percentiles vs the isolated B-6 baseline (267.8 ms).
  4  RATE-LIMIT PROBE: burst 100 raw RG PUTs in <5 s -- does smalt answer
     429 TooManyRequests? Real Azure ARM throttles; 200-class answers are a
     divergence finding.

Self-boots an anonymous substrate on private ports 39850-39853 (same pattern
as b6_lro_sdk.py, via scripts/stress/_substrate). Teardown: killpg + port
sweep. Output: docs/jira/v26.10.14/bench/c5-arm-storm.jsonl.
"""
import argparse
import http.client
import json
import os
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

REPO = os.environ.get(
    "SMALT_REPO",
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
)
sys.path.insert(0, os.path.join(REPO, "scripts", "stress"))
import _substrate  # noqa: E402

HOST = "127.0.0.1"
ARM_PORT = 39850
ARM_TLS_PORT = 39851
AMQP_PORT = 39852
EVENT_HUBS_PORT = 39853
BASE = f"https://{HOST}:{ARM_TLS_PORT}"
SUB = "00000000-0000-0000-0000-000000000000"
API = "2021-04-01"
STAMP = time.strftime("%Y%m%dT%H%M%S")
OUT_JSONL = os.path.join(
    REPO, "docs", "jira", "v26.10.14", "bench", "c5-arm-storm.jsonl")
SERVER_LOG = f"/tmp/c5_arm_storm_server_{STAMP}.log"

TLS_OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(
    context=ssl._create_unverified_context()))

RESULTS = {"phases": {}, "errors": []}
CRED = None

SA_BODY = {"location": "eastus",
           "sku": {"name": "Standard_LRS", "tier": "Standard"},
           "kind": "StorageV2",
           "properties": {"skuName": "Standard_LRS",
                          "supportsHttpsTrafficOnly": True}}


def fail_closed(msg):
    print("FAULT: " + msg, flush=True)
    sys.exit(2)


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    return round(sorted_vals[min(len(sorted_vals) - 1,
                                 int(p / 100.0 * len(sorted_vals)))], 1)


def stats(vals_ms):
    s = sorted(vals_ms)
    if not s:
        return {"n": 0}
    return {"n": len(s), "min": round(s[0], 1),
            "p50": pct(s, 50), "p95": pct(s, 95), "p99": pct(s, 99),
            "max": round(s[-1], 1)}


# ---------------------------------------------------------------------------
# auth + raw wire
# ---------------------------------------------------------------------------
from azure.core.credentials import AccessToken  # noqa: E402


class SmaltTokenCredential:
    """Custom TokenCredential: mints a bearer from smalt's own STS with
    exp-based early refresh."""

    def __init__(self):
        self._lock = threading.Lock()
        self._tok = None

    def get_token(self, *scopes, **kwargs):
        with self._lock:
            if self._tok and self._tok.expires_on - 300 > time.time():
                return self._tok
            self._tok = self._fetch()
            return self._tok

    def _fetch(self):
        body = urllib.parse.urlencode({
            "grant_type": "client_credentials",
            "client_id": "c5-arm-storm-tier",
            "client_secret": "c5-arm-storm-tier",
            "scope": "https://management.azure.com/.default",
        }).encode()
        req = urllib.request.Request(
            BASE + "/oauth2/v2.0/token", data=body,
            headers={"content-type": "application/x-www-form-urlencoded"})
        for attempt in range(3):
            try:
                with TLS_OPENER.open(req, timeout=15) as resp:
                    tok = json.loads(resp.read().decode("utf-8"))
                return AccessToken(tok["access_token"],
                                   int(time.time()) + int(tok["expires_in"]) - 300)
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(0.2)


_tls = threading.local()


def raw(method, path, body=None, timeout=30):
    """Raw wire request on a per-thread persistent TLS connection.
    Returns (status, headers-dict, parsed-body-or-None)."""
    c = getattr(_tls, "conn", None)
    if c is None:
        c = http.client.HTTPSConnection(HOST, ARM_TLS_PORT, timeout=timeout,
                                        context=ssl._create_unverified_context())
        _tls.conn = c
    hdrs = {"authorization": "Bearer " + CRED.get_token().token,
            "accept": "application/json"}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        hdrs["content-type"] = "application/json"
    try:
        c.request(method, path, body=payload, headers=hdrs)
        r = c.getresponse()
        data = r.read()
        rh = {k: v for k, v in r.getheaders()}
        try:
            parsed = json.loads(data) if data else None
        except ValueError:
            parsed = None
        return r.status, rh, parsed
    except Exception:
        try:
            c.close()
        except Exception:
            pass
        _tls.conn = None
        raise


def _sdk(polling_interval=0.05):
    """Thread-scoped ResourceManagementClient."""
    key = f"sdk_{polling_interval}"
    c = getattr(_tls, key, None)
    if c is None:
        from azure.mgmt.resource import ResourceManagementClient
        c = ResourceManagementClient(
            CRED, SUB, base_url=BASE, api_version=API,
            polling_interval=polling_interval, connection_verify=False)
        setattr(_tls, key, c)
    return c


READ_PATHS = [
    f"/subscriptions/{SUB}?api-version={API}",
    f"/subscriptions?api-version={API}",
    f"/subscriptions/{SUB}/resourcegroups?api-version={API}",
    f"/subscriptions/{SUB}/providers?api-version={API}",
    f"/subscriptions/{SUB}/resources?api-version={API}",
]


def read_one(i):
    """One mixed read; returns latency ms and status."""
    t0 = time.perf_counter()
    st, _, _ = raw("GET", READ_PATHS[i % len(READ_PATHS)])
    return (time.perf_counter() - t0) * 1000, st


# ---------------------------------------------------------------------------
# substrate lifecycle (anonymous, private ports)
# ---------------------------------------------------------------------------
def free_port():
    import socket
    s = socket.socket()
    s.bind((HOST, 0))
    p = s.getsockname()[1]
    s.close()
    return p


EGRESS_PORT = None
MCP_PORT = None


def spawn_substrate():
    global EGRESS_PORT, MCP_PORT
    EGRESS_PORT, MCP_PORT = free_port(), free_port()
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    env["MIX_BUILD_ROOT"] = os.environ.get(
        "MIX_BUILD_ROOT", os.path.join(REPO, "_build-c5"))
    return subprocess.Popen(
        ["mix", "run", "--no-start", "--no-halt", "--eval",
         f"Application.put_env(:smalt, :arm_port, {ARM_PORT}); "
         f"Application.put_env(:smalt, :arm_tls_port, {ARM_TLS_PORT}); "
         f"Application.put_env(:smalt, :egress_port, {EGRESS_PORT}); "
         f"Application.put_env(:smalt, :amqp_port, {AMQP_PORT}); "
         f"Application.put_env(:smalt, :event_hubs_port, {EVENT_HUBS_PORT}); "
         f"Application.put_env(:smalt, :mcp_port, {MCP_PORT}); "
         "Application.put_env(:smalt, :lro_delay_ms, 250); "
         "Application.ensure_all_started(:smalt)"],
        cwd=REPO, env=env,
        stdout=open(SERVER_LOG, "w"), stderr=subprocess.STDOUT,
        start_new_session=True, stdin=subprocess.DEVNULL)


def kill_substrate(proc):
    """killpg + port sweep, excluding THIS process (lsof lists our own client
    connections on those ports)."""
    import signal as _signal
    me = {os.getpid(), os.getppid()}
    if proc is not None:
        try:
            os.killpg(os.getpgid(proc.pid), _signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=10)
        except Exception:
            pass
    for port in (ARM_PORT, ARM_TLS_PORT, AMQP_PORT, EVENT_HUBS_PORT,
                 EGRESS_PORT, MCP_PORT):
        try:
            out = subprocess.run(["lsof", "-ti", f"tcp:{port}"],
                                 capture_output=True, text=True,
                                 timeout=10).stdout
        except Exception:
            out = ""
        for pid in out.split():
            if pid.isdigit() and int(pid) not in me:
                try:
                    os.kill(int(pid), _signal.SIGKILL)
                except (ValueError, ProcessLookupError, PermissionError):
                    pass


# ---------------------------------------------------------------------------
# ReadStorm: a start/stop-able 16-thread mixed-read storm
# ---------------------------------------------------------------------------
class ReadStorm:
    def __init__(self, threads=16):
        self.threads = threads
        self.stop = threading.Event()
        self.lat = []
        self.statuses = {}
        self.lock = threading.Lock()
        self.pool = None

    def _worker(self, wid):
        i = wid
        while not self.stop.is_set():
            try:
                ms, st = read_one(i)
            except Exception as e:  # noqa: BLE001
                with self.lock:
                    self.statuses[f"err:{type(e).__name__}"] = \
                        self.statuses.get(f"err:{type(e).__name__}", 0) + 1
                time.sleep(0.01)
                continue
            with self.lock:
                self.lat.append(ms)
                self.statuses[str(st)] = self.statuses.get(str(st), 0) + 1
            i += self.threads

    def start(self):
        self.pool = ThreadPoolExecutor(max_workers=self.threads)
        for w in range(self.threads):
            self.pool.submit(self._worker, w)

    def stop_and_join(self):
        self.stop.set()
        self.pool.shutdown(wait=True)
        return self.snapshot()

    def snapshot(self):
        with self.lock:
            lat = list(self.lat)
            st = dict(self.statuses)
        wall_ops = len(lat)
        return lat, st, wall_ops


def storm_summary(label, lat, statuses, wall_s, extra=None):
    res = {
        "phase": label,
        "ops": len(lat),
        "statuses": statuses,
        "ops_per_sec": round(len(lat) / wall_s, 1) if wall_s > 0 else None,
        "latency_ms": stats(lat),
    }
    if extra:
        res.update(extra)
    RESULTS["phases"][label] = res
    print(json.dumps(res), flush=True)
    return res


def phase1_read_storm(storm):
    """Fixed-size 2000-op mixed read across the 16-thread pool."""
    lat = [None] * 2000
    statuses = {}
    errs = []

    def do(i):
        try:
            ms, st = read_one(i)
            lat[i] = ms
            statuses[str(st)] = statuses.get(str(st), 0) + 1
        except Exception as e:  # noqa: BLE001
            errs.append(f"read{i}: {type(e).__name__}: {e}")

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=16) as ex:
        list(ex.map(do, range(2000)))
    wall = time.perf_counter() - t0
    done = [x for x in lat if x is not None]
    return storm_summary("p1_read_storm_2000", done, statuses, wall, {
        "errors": len(errs), "wall_s": round(wall, 3)}), errs


def phase2_write_read_mix(storm, rg):
    """Read storm runs continuously; 60 RG create+delete writes run under it.
    Isolated baseline: 10 RG create+delete with NO storm."""
    from azure.mgmt.resource import ResourceManagementClient

    # isolated baseline first (no storm)
    base_ms = []

    def base_writer(i):
        name = f"c5-base-rg-{i:03d}"
        t0 = time.perf_counter()
        try:
            _sdk().resource_groups.create_or_update(name, {"location": "eastus"})
            _sdk().resource_groups.begin_delete(name).result(timeout=60)
            base_ms.append((time.perf_counter() - t0) * 1000)
        except Exception as e:  # noqa: BLE001
            RESULTS["errors"].append(f"{name}: {type(e).__name__}: {e}")

    with ThreadPoolExecutor(max_workers=8) as ex:
        list(ex.map(base_writer, range(10)))
    base_summary = {
        "n": len(base_ms), "latency_ms": stats(base_ms),
        "ops_per_sec": round(len(base_ms) / (sum(base_ms) / 1000.0), 2)
        if base_ms else 0}

    # now start the storm and run 60 writers under it
    storm.start()
    write_ms = []
    werrs = []

    def writer(i):
        name = f"c5-mix-rg-{i:03d}"
        t0 = time.perf_counter()
        try:
            _sdk().resource_groups.create_or_update(name, {"location": "eastus"})
            _sdk().resource_groups.begin_delete(name).result(timeout=120)
            with RESULTS_LOCK:
                write_ms.append((time.perf_counter() - t0) * 1000)
        except Exception as e:  # noqa: BLE001
            werrs.append(f"{name}: {type(e).__name__}: {e}")

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=8) as ex:
        list(ex.map(writer, range(60)))
    write_wall = time.perf_counter() - t0

    rlat, rst, rops = storm.stop_and_join()
    storm_wall = write_wall  # reads measured over the write window
    mix_summary = storm_summary("p2_mix_reads", rlat, rst, storm_wall, {
        "note": "read latencies measured over the concurrent write window"})
    res = {
        "phase": "p2_write_read_mix",
        "isolated_write_baseline": base_summary,
        "write_under_load": {
            "n": len(write_ms), "errors": len(werrs),
            "latency_ms": stats(write_ms),
            "ops_per_sec": round(len(write_ms) / write_wall, 2)
            if write_wall else None,
            "wall_s": round(write_wall, 3)},
        "reads_during": {k: mix_summary[k] for k in
                         ("ops", "ops_per_sec", "latency_ms", "statuses")},
        "write_degradation_x": round(
            (stats(write_ms)["p50"] or 0) / max(base_summary["latency_ms"]["p50"] or 1, 0.001), 2),
    }
    RESULTS["phases"]["p2_write_read_mix"] = res
    RESULTS["errors"].extend(werrs)
    print(json.dumps(res), flush=True)
    return res


def phase3_lro_under_load(storm, rg):
    """50 storageAccount LRO PUTs via SDK pollers while the read storm runs.
    Poll-to-terminal vs the isolated B-6 baseline (267.8 ms p50-ish)."""
    B6_BASELINE_MS = 267.8

    # SDK poller per thread; storm provides the read pressure
    term_ms = [None] * 50
    submit_ms = [None] * 50
    errs = []

    def do(i):
        name = f"c5lro{i:04d}"
        c = _sdk()
        t0 = time.perf_counter()
        try:
            rid = (f"/subscriptions/{SUB}/resourceGroups/{rg}"
                   f"/providers/Microsoft.Storage/storageAccounts/{name}")
            poller = c.resources.begin_create_or_update_by_id(rid, API, SA_BODY)
            submit_ms[i] = (time.perf_counter() - t0) * 1000
            t1 = time.perf_counter()
            poller.result(timeout=180)
            term_ms[i] = (time.perf_counter() - t1) * 1000
        except Exception as e:  # noqa: BLE001
            errs.append(f"{name}: {type(e).__name__}: {e}")

    storm.start()
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=16) as ex:
        list(ex.map(do, range(50)))
    wall = time.perf_counter() - t0
    rlat, rst, rops = storm.stop_and_join()

    n_term = sum(1 for t in term_ms if t is not None)
    res = {
        "phase": "p3_lro_under_load_50",
        "submissions": 50,
        "ok": n_term,
        "errors": len(errs),
        "submit_ms": stats([s for s in submit_ms if s is not None]),
        "poll_to_terminal_ms": stats([t for t in term_ms if t is not None]),
        "b6_isolated_baseline_ms": B6_BASELINE_MS,
        "p50_vs_baseline_x": round(
            (stats([t for t in term_ms if t is not None])["p50"] or 0)
            / B6_BASELINE_MS, 2),
        "wall_s": round(wall, 3),
        "reads_during": {"ops": rops, "latency_ms": stats(rlat),
                         "statuses": rst},
    }
    RESULTS["phases"]["p3_lro_under_load_50"] = res
    RESULTS["errors"].extend(errs)
    print(json.dumps(res), flush=True)
    return res


def phase4_rate_limit(rg):
    """Burst 100 raw RG PUTs as fast as 32 threads can fire them (<5 s).
    Verdict: 429 TooManyRequests (parity) vs 200/201 (divergence)."""
    statuses = {}
    retry_after = set()
    lat = []
    errs = []

    def do(i):
        name = f"c5-burst-rg-{i:03d}"
        path = (f"/subscriptions/{SUB}/resourcegroups/{name}?api-version={API}")
        t0 = time.perf_counter()
        try:
            st, rh, _ = raw("PUT", path, body={"location": "eastus"}, timeout=60)
            ms = (time.perf_counter() - t0) * 1000
            with RESULTS_LOCK:
                lat.append(ms)
                statuses[str(st)] = statuses.get(str(st), 0) + 1
                ra = rh.get("retry-after") or rh.get("Retry-After")
                if ra:
                    retry_after.add(ra)
        except Exception as e:  # noqa: BLE001
            errs.append(f"{name}: {type(e).__name__}: {e}")

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=32) as ex:
        list(ex.map(do, range(100)))
    wall = time.perf_counter() - t0

    n429 = statuses.get("429", 0)
    verdict = ("PARITY" if n429 > 0 else
               "DIVERGENCE: no 429 observed; real Azure ARM throttles at this "
               "burst class (control-plane rate limiter absent)")
    res = {
        "phase": "p4_rate_limit_burst_100",
        "burst": 100,
        "burst_wall_s": round(wall, 3),
        "under_5s": wall < 5.0,
        "statuses": statuses,
        "retry_after_headers": sorted(retry_after),
        "latency_ms": stats(lat),
        "errors": len(errs),
        "verdict": verdict,
    }
    RESULTS["phases"]["p4_rate_limit_burst_100"] = res
    RESULTS["errors"].extend(errs)
    print(json.dumps(res), flush=True)
    return res


RESULTS_LOCK = threading.Lock()


def write_jsonl():
    os.makedirs(os.path.dirname(OUT_JSONL), exist_ok=True)
    row = {"lane": "c5-arm-storm", "stamp": STAMP, "base": BASE,
           "api_version": API, "phases": RESULTS["phases"],
           "errors": RESULTS["errors"]}
    with open(OUT_JSONL, "a") as f:
        f.write(json.dumps(row) + "\n")


# ---------------------------------------------------------------------------
def main():
    global CRED
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-boot", action="store_true")
    args = ap.parse_args()

    _substrate.install_sigterm_handler()
    proc = None
    if not args.skip_boot:
        for p in (ARM_PORT, ARM_TLS_PORT, AMQP_PORT, EVENT_HUBS_PORT):
            if not _substrate.wait_port_free(p, timeout_s=5):
                fail_closed(f"private port {p} busy; refusing to share")
        proc = spawn_substrate()
        _substrate.wait_for_port(ARM_PORT, proc, timeout_s=300,
                                 fail=fail_closed, poll=0.05)
        print(f"substrate up on :{ARM_PORT} (log {SERVER_LOG})", flush=True)

    CRED = SmaltTokenCredential()
    try:
        from azure.mgmt.resource import ResourceManagementClient
        client = ResourceManagementClient(
            CRED, SUB, base_url=BASE, api_version=API,
            polling_interval=0.05, connection_verify=False)

        RG = "c5-arm-storm-rg"
        t0 = time.perf_counter()
        client.resource_groups.create_or_update(RG, {"location": "eastus"})
        print(f"RG {RG} up in {(time.perf_counter() - t0) * 1000:.0f}ms",
              flush=True)

        phase1_read_storm(None)
        storm = ReadStorm(threads=16)
        phase2_write_read_mix(storm, RG)
        phase3_lro_under_load(storm, RG)
        phase4_rate_limit(RG)

        st, _, _ = raw("DELETE",
                       f"/subscriptions/{SUB}/resourceGroups/{RG}?api-version={API}")
        print(f"cleanup RG delete -> {st}", flush=True)
    finally:
        write_jsonl()
        if proc is not None:
            kill_substrate(proc)

    p1 = RESULTS["phases"].get("p1_read_storm_2000", {})
    p2 = RESULTS["phases"].get("p2_write_read_mix", {})
    p3 = RESULTS["phases"].get("p3_lro_under_load_50", {})
    p4 = RESULTS["phases"].get("p4_rate_limit_burst_100", {})
    ok = (p1.get("errors", 1) == 0
          and p2.get("write_under_load", {}).get("errors", 1) == 0
          and p3.get("errors", 1) == 0
          and p4.get("errors", 1) == 0)
    print("C5 " + ("PASSED" if ok else "FAILED"), flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
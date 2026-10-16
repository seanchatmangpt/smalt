#!/usr/bin/env python3
"""LRO storm: real-wire stress of the smalt ARM gateway's long-running-operation seam.

Phases
  1. 1,000 concurrent storageAccount PUTs (LRO type) -> 202 rate; op-table
     growth introspected live from :smalt_operations; poll ALL ops in waves --
     all reach Succeeded; poll latency measured vs backlog (wave index).
  2. 100 ops with :lro_delay_ms 30000 (set live via :erpc into the server
     node) + interleaved resource GETs -- GET latency must not bleed.
  3. Delete-created-resource sweep: DELETE every created account, resource GET
     -> 404, op records remain queryable (200 Succeeded).

Process-count introspection (before / peak / during / after) rides a
distributed-erlang probe node (:erpc into the server node) -- asserts no
unbounded process spawn.

Usage: python3 scripts/stress/lro_storm.py [--keep-server]
"""
import argparse
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
from concurrent.futures import ThreadPoolExecutor

REPO = os.environ.get(
    "SMALT_REPO",
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
)
NODE = "smalt_storm@127.0.0.1"
COOKIE = "lro_storm_cookie"
HOST, PORT = "127.0.0.1", 9443
SUB = "00000000-0000-0000-0000-000000000000"
API_VERSION = "2021-04-01"
STAMP = time.strftime("%Y%m%d%H%M%S")
SERVER_LOG = f"/tmp/lro_storm_server_{STAMP}.log"

results = {"checks": [], "metrics": {}}


def check(name, ok, detail):
    results["checks"].append({"name": name, "ok": bool(ok), "detail": detail})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")
    return bool(ok)


def bucket(samples_ms):
    s = sorted(x for x in samples_ms if x is not None)
    if not s:
        return {}

    def pct(p):
        return round(s[min(len(s) - 1, int(p * len(s)))], 1)

    return {"n": len(s), "p50": pct(0.5), "p95": pct(0.95), "max": round(s[-1], 1)}


class Client:
    """Thread-scoped keep-alive HTTP client. One instance per thread."""

    def __init__(self, token):
        self.token = token
        self.conn = None

    def request(self, method, path, body=None, retries=1):
        headers = {
            "host": f"{HOST}:{PORT}",
            "accept": "application/json",
            "authorization": f"Bearer {self.token}",
        }

        payload = None

        if body is not None:
            payload = json.dumps(body).encode()
            headers["content-type"] = "application/json"

        for attempt in range(retries + 1):
            try:
                if self.conn is None:
                    self.conn = http.client.HTTPConnection(HOST, PORT, timeout=60)
                self.conn.request(method, path, body=payload, headers=headers)
                resp = self.conn.getresponse()
                data = resp.read()
                hdrs = {k.lower(): v for k, v in resp.getheaders()}
                return resp.status, hdrs, data
            except Exception:
                self._drop()
                if attempt == retries:
                    raise
                time.sleep(0.05 * (attempt + 1))

    def _drop(self):
        try:
            self.conn.close()
        except Exception:
            pass
        self.conn = None


def fetch_token():
    c = http.client.HTTPConnection(HOST, PORT, timeout=10)
    c.request(
        "POST",
        "/oauth2/v2.0/token",
        body=b"grant_type=client_credentials&client_id=lro_storm",
        headers={"content-type": "application/x-www-form-urlencoded"},
    )
    r = c.getresponse()
    data = r.read()
    c.close()
    assert r.status == 200, f"token request failed: {r.status} {data[:200]}"
    return json.loads(data)["access_token"]


def _run_probe(code):
    uniq = random.randrange(1 << 30)
    argv = [
        "elixir",
        "--name",
        f"probe{uniq}@127.0.0.1",
        "--cookie",
        COOKIE,
        "-e",
        code,
    ]
    out = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    return out


def probe():
    """Live introspection: beam process_count + :smalt_operations size."""
    code = (
        'n = :"smalt_storm@127.0.0.1"; '
        "pong = :net_adm.ping(n); "
        "pc = :erpc.call(n, :erlang, :system_info, [:process_count]); "
        "os = :erpc.call(n, :ets, :info, [:smalt_operations, :size]); "
        'IO.puts("PROBE process_count=#{pc} op_size=#{os}")'
    )
    out = _run_probe(code)
    line = [ln for ln in (out.stdout or "").splitlines() if "PROBE" in ln]

    if not line:
        raise RuntimeError(f"probe failed rc={out.returncode} stderr={out.stderr[-400:]}")

    fields = dict(kv.split("=") for kv in line[0].split()[1:])
    return {"process_count": int(fields["process_count"]), "op_size": int(fields["op_size"])}


def set_lro_delay(ms):
    code = f':ok = :erpc.call(:"{NODE}", Application, :put_env, [:smalt, :start_at_ms, {ms}])'
    code = f':ok = :erpc.call(:"{NODE}", Application, :put_env, [:smalt, :lro_delay_ms, {ms}])'
    out = _run_probe(
        f':ok = :erpc.call(:"{NODE}", Application, :put_env, [:smalt, :lro_delay_ms, {ms}])'
    )
    if out.returncode != 0:
        raise RuntimeError(f"set_lro_delay failed: {out.stderr[-400:]}")


def wait_ready(timeout=240):
    print(f"waiting for server on {HOST}:{PORT} (log {SERVER_LOG})")
    t0 = time.time()

    while time.time() - t0 < timeout:
        try:
            c = http.client.HTTPConnection(HOST, PORT, timeout=2)
            c.request("GET", "/metadata/endpoints")
            r = c.getresponse()
            r.read()
            c.close()

            if r.status == 200:
                return time.time() - t0
        except OSError:
            pass
        time.sleep(1)
    raise RuntimeError(f"server never became ready in {timeout}s")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start_server():
    # All listeners on runtime-free ports: other smalt lanes actively race for
    # the defaults (AMQP 5672 was taken mid-run earlier). --no-start +
    # ensure_all_started so put_env lands BEFORE the supervision tree binds.
    global PORT
    PORT = free_port()
    boot = (
        f'Application.put_env(:smalt, :arm_port, {PORT}); '
        f'Application.put_env(:smalt, :arm_tls_port, {free_port()}); '
        f'Application.put_env(:smalt, :amqp_port, {free_port()}); '
        f'Application.put_env(:smalt, :event_hubs_port, {free_port()}); '
        f'Application.put_env(:smalt, :egress_port, {free_port()}); '
        f'Application.put_env(:smalt, :mcp_port, {free_port()}); '
        '{:ok, _} = Application.ensure_all_started(:smalt); '
        'Process.sleep(:infinity)'
    )
    argv = [
        "elixir",
        "--name", NODE,
        "--cookie", COOKIE,
        "-S", "mix", "run", "--no-start", "-e", boot,
    ]
    # Own process group (lens-4 cycle 5): teardown killpg's the whole group
    # so the mix wrapper's beam children can never outlive the harness as
    # orphaned beams — the class behind lens-2/3's reaped 19443 orphans.
    return subprocess.Popen(
        argv,
        cwd=REPO,
        stdout=open(SERVER_LOG, "w"),
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )


def stop_server(srv):
    """SIGTERM the server's process group, wait, then SIGKILL the group —
    killpg-only teardown (never a port sweep), lens-4."""
    try:
        os.killpg(os.getpgid(srv.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        srv.wait(timeout=30)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(os.getpgid(srv.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        srv.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-server", action="store_true")
    args = ap.parse_args()

    print("== smalt LRO storm ==")

    # Boot retry: concurrent lanes editing lib/ can freeze compilation mid-boot;
    # the shared-tree compile-freeze SLA says the owner fixes within ~10 min, so
    # retry the boot rather than aborting the storm.
    srv = None
    ready_s = None

    for attempt in range(6):
        srv = start_server()

        try:
            ready_s = wait_ready(timeout=120)
            break
        except RuntimeError as e:
            print(f"boot attempt {attempt + 1} failed: {e}; retrying")
            stop_server(srv)
            ready_s = None
            time.sleep(20)

    if ready_s is None:
        print("STORM FAILED: server never became ready after retries")
        return 1

    print(f"server ready in {ready_s:.1f}s")

    try:
        run_all()
    finally:
        if args.keep_server:
            print(f"--keep-server: leaving server up (pid {srv.pid})")
        else:
            stop_server(srv)

    print(json.dumps({"checks": results["checks"]}, indent=2))
    print(json.dumps(results["metrics"], indent=2))
    failed = [c for c in results["checks"] if not c["ok"]]

    if failed:
        print(f"STORM FAILED: {len(failed)} check(s) failed")
        return 1

    print("STORM PASSED")
    return 0


def rg_path():
    return f"/subscriptions/{SUB}/resourceGroups/lro-storm-{STAMP}?api-version={API_VERSION}"


def acct_path(name):
    return (
        f"/subscriptions/{SUB}/resourceGroups/lro-storm-{STAMP}"
        f"/providers/Microsoft.Storage/storageAccounts/{name}?api-version={API_VERSION}"
    )


def op_path(op_id):
    return f"/subscriptions/{SUB}/operations/{op_id}?api-version={API_VERSION}"


ACCT_BODY = {"location": "eastus", "properties": {"skuName": "Standard_LRS"}}


def run_all():
    tok = fetch_token()
    client = Client(tok)
    base = probe()
    check("probe.up", True, f"before process_count={base['process_count']} op_size={base['op_size']}")

    st, _, _ = client.request("PUT", rg_path(), body={"location": "eastus"})
    check("rg.put", st == 201, f"resource group PUT status={st}")

    before = probe()

    # ---------- Phase 1: 1,000 concurrent LRO PUTs ----------
    N1 = 1000
    print(f"phase1: {N1} concurrent storageAccount PUTs")
    put_lat = [None] * N1
    op_ids = [None] * N1
    ok202 = [False] * N1
    peak = {"pc": before["process_count"]}

    stop = threading.Event()

    def sampler():
        while not stop.is_set():
            try:
                p = probe()
                peak["pc"] = max(peak["pc"], p["process_count"])
            except Exception:
                pass
            stop.wait(1.0)

    sthr = threading.Thread(target=sampler, daemon=True)
    sthr.start()

    def do_put(i):
        c = Client(tok)
        t0 = time.perf_counter()
        st, hdrs, _ = c.request("PUT", acct_path(f"storm{i:04d}"), body=ACCT_BODY)
        put_lat[i] = (time.perf_counter() - t0) * 1000
        ok202[i] = st == 202
        if st == 202:
            op_ids[i] = hdrs.get("azure-asyncoperation", "").rsplit("/", 1)[-1]

    with ThreadPoolExecutor(max_workers=N1) as ex:
        list(ex.map(do_put, range(N1)))
    stop.set()
    sthr.join()

    n202 = sum(ok202)
    check("phase1.202_rate", n202 == N1, f"{n202}/{N1} PUTs returned 202")
    check(
        "phase1.op_ids",
        all(op_ids),
        f"{sum(1 for x in op_ids if x)}/{N1} carried Azure-AsyncOperation op ids",
    )

    mid = probe()
    check(
        "phase1.op_table_growth",
        mid["op_size"] == before["op_size"] + N1,
        f":smalt_operations {before['op_size']} -> {mid['op_size']} (+{N1} expected)",
    )

    # ---------- Phase 1: poll ALL ops in waves ----------
    print("phase1: polling all 1000 ops in waves of 250")
    WAVE = 250
    poll_by_wave = {}

    for w0 in range(0, N1, WAVE):
        chunk = op_ids[w0:w0 + WAVE]
        lat = [None] * len(chunk)
        ok = [False] * len(chunk)

        def do_poll(j):
            c = Client(tok)
            t0 = time.perf_counter()
            st, _, body = c.request("GET", op_path(chunk[j]))
            lat[j] = (time.perf_counter() - t0) * 1000
            ok[j] = st == 200 and json.loads(body).get("status") == "Succeeded"

        with ThreadPoolExecutor(max_workers=len(chunk)) as ex:
            list(ex.map(do_poll, range(len(chunk))))

        b = bucket(lat)
        poll_by_wave[f"wave@{w0}"] = b
        check(
            f"phase1.poll_wave@{w0}",
            all(ok),
            f"all Succeeded; latency p50={b['p50']}ms p95={b['p95']}ms max={b['max']}ms",
        )

    results["metrics"]["phase1_put_ms"] = bucket(put_lat)
    results["metrics"]["phase1_poll_ms_by_wave"] = poll_by_wave

    # ---------- Phase 2: 100 long ops (30 s) + interleaved GETs ----------
    print("phase2: 100 ops with lro_delay_ms=30000 + interleaved GETs")
    set_lro_delay(30_000)
    NL = 100
    long_ids = [None] * NL
    long_ok = [False] * NL

    def do_long_put(i):
        c = Client(tok)
        st, hdrs, _ = c.request("PUT", acct_path(f"long{i:04d}"), body=ACCT_BODY)
        long_ok[i] = st == 202
        if st == 202:
            long_ids[i] = hdrs.get("azure-asyncoperation", "").rsplit("/", 1)[-1]

    with ThreadPoolExecutor(max_workers=NL) as ex:
        list(ex.map(do_long_put, range(NL)))
    set_lro_delay(0)
    check("phase2.100x202", all(long_ok), f"{sum(long_ok)}/{NL} long-op PUTs returned 202")

    # immediate poll: expect 202 InProgress
    def poll_one(op_id):
        c = Client(tok)
        st, _, body = c.request("GET", op_path(op_id))
        return st, (json.loads(body).get("status") if st in (200, 202) else None)

    rows = ThreadPoolExecutor(max_workers=NL).map(poll_one, long_ids)
    inprog = sum(1 for st, s in rows if st == 202 and s == "InProgress")
    check("phase2.inprogress_202", inprog == NL, f"{inprog}/{NL} polls returned 202 InProgress")

    # baseline GET latency
    base_lat = [None] * 200

    def do_base_get(i):
        c = Client(tok)
        t0 = time.perf_counter()
        st, _, _ = c.request("GET", acct_path(f"storm{i % N1:04d}"))
        base_lat[i] = (time.perf_counter() - t0) * 1000
        return st

    sts = list(ThreadPoolExecutor(max_workers=20).map(do_base_get, range(200)))
    check("phase2.get_baseline_200", all(s == 200 for s in sts), f"{sum(1 for s in sts if s == 200)}/200 GETs 200")

    # interleaved GET load while the 30 s delay elapses
    load_lat = []
    load_ok = []
    lk = threading.Lock()
    stop2 = threading.Event()

    def load_worker():
        c = Client(tok)
        rng = random.Random(threading.get_ident())

        while not stop2.is_set():
            i = rng.randrange(N1)
            t0 = time.perf_counter()

            try:
                st, _, _ = c.request("GET", acct_path(f"storm{i:04d}"))
                dt = (time.perf_counter() - t0) * 1000
                with lk:
                    load_lat.append(dt)
                    load_ok.append(st == 200)
            except Exception:
                with lk:
                    load_ok.append(False)

    loaders = [threading.Thread(target=load_worker, daemon=True) for _ in range(8)]

    for t in loaders:
        t.start()

    # poll the long ops to Succeeded (lazy flip at startedAtMs+delayMs)
    remaining = set(range(NL))
    deadline = time.time() + 45

    while remaining and time.time() < deadline:
        for i in list(remaining):
            try:
                st, s = poll_one(long_ids[i])
            except Exception:
                continue

            if st == 200 and s == "Succeeded":
                remaining.discard(i)
        time.sleep(1)
    stop2.set()

    for t in loaders:
        t.join(timeout=5)

    check("phase2.long_ops_succeed", not remaining, f"{NL - len(remaining)}/{NL} long ops reached Succeeded")
    get_ok_rate = sum(load_ok) / max(1, len(load_ok))
    check("phase2.get_availability", get_ok_rate == 1.0, f"{sum(load_ok)}/{len(load_ok)} interleaved GETs 200")

    bl = bucket(base_lat)
    ll = bucket(load_lat)
    results["metrics"]["phase2_get_baseline_ms"] = bl
    results["metrics"]["phase2_get_under_lro_load_ms"] = ll

    bleed_threshold = max(250.0, 5 * (bl["p95"] if bl else 0.0))
    check(
        "phase2.no_latency_bleed",
        ll and ll["p95"] <= bleed_threshold,
        f"GET p95 under LRO load {ll.get('p95')}ms vs baseline p95 {bl.get('p95')}ms (threshold {bleed_threshold}ms)",
    )

    # ---------- Phase 3: delete sweep ----------
    print("phase3: delete-created-resource sweep")
    del_ok = [False] * N1

    def do_delete(i):
        c = Client(tok)
        p = acct_path(f"storm{i:04d}").split("?")[0]
        st, _, _ = c.request("DELETE", p)
        del_ok[i] = st == 200

    with ThreadPoolExecutor(max_workers=100) as ex:
        list(ex.map(do_delete, range(N1)))
    check("phase3.deletes", all(del_ok), f"{sum(del_ok)}/{N1} DELETEs returned 200")

    # resource GETs must 404; op records must remain queryable
    forties = [False] * 50
    opq = [False] * 50

    def verify(i):
        c = Client(tok)
        st, _, _ = c.request("GET", acct_path(f"storm{i:04d}"))
        forties[i] = st == 404
        st2, _, body = c.request("GET", op_path(op_ids[i]))
        opq[i] = st2 == 200 and json.loads(body).get("status") == "Succeeded"

    list(ThreadPoolExecutor(max_workers=50).map(verify, range(50)))
    check("phase3.resource_404", all(forties), f"{sum(forties)}/50 deleted-resource GETs returned 404")
    check(
        "phase3.op_records_queryable",
        all(opq),
        f"{sum(opq)}/50 op records still queryable after resource deletion",
    )

    after = probe()
    check(
        "phase3.op_records_persist",
        after["op_size"] >= before["op_size"] + N1 + NL,
        f":smalt_operations after sweep = {after['op_size']} (>= {before['op_size'] + N1 + NL})",
    )

    # process count: no unbounded spawn
    check(
        "process.no_unbounded_spawn",
        after["process_count"] <= before["process_count"] + 100,
        f"beam process_count before={before['process_count']} peak={peak['pc']} after={after['process_count']}",
    )
    results["metrics"]["process_count"] = {
        "before": before["process_count"],
        "peak": peak["pc"],
        "after": after["process_count"],
    }
    results["metrics"]["op_table_size"] = {
        "before": before["op_size"],
        "after_phase1": mid["op_size"],
        "after_sweep": after["op_size"],
    }


if __name__ == "__main__":
    sys.exit(main())

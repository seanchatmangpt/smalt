#!/usr/bin/env python3
"""Bench lane C-6: Sentinel (Log Analytics) ingest + KQL + Resource Graph.

Surfaces under test (smalt substrate, private ports, MIX_ENV=test anonymous):
  - DCR ingest:  POST /dataCollectionRules/<dcr>/streams/Custom-Logs?api-version=2023-01-01
                 (5000 rows x 500-byte telemetry events, 100-row batches)
  - KQL queries: LogsQueryClient.query_workspace (where/order/project/take)
  - Resource Graph over storage accounts seeded via ARM PUT.

Phases:
  1. INGEST       — 5000 rows in 100-row batches, rows/s + batch latency percentiles
  2. QUERY-UNDER-INGEST — idle KQL baseline vs concurrent-with-ingest latency
  3. RG           — Resource Graph query/s over seeded storage accounts
  4. TAKE CAP     — take 100000 under ingest load; 101-row cap must hold

Emits JSONL rows to docs/jira/v26.10.14/bench/c6-sentinel-rg.jsonl
(bench_emit schema + phase extras). Run via scripts/bench/lib.sh:

  source scripts/bench/lib.sh
  pid=$(bench_boot c6)
  C6_ARM=... C6_EGRESS=... python3 scripts/bench/c6_sentinel_rg.py
  bench_down "$pid"
"""
import json
import os
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request

from azure.core.credentials import AccessToken
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions
from azure.monitor.query import LogsQueryClient, LogsQueryStatus

ARM = os.environ.get("C6_ARM", "http://127.0.0.1:39060")
EGRESS = os.environ.get("C6_EGRESS", "http://127.0.0.1:39061")
SUB = os.environ.get("C6_SUB", "sub-c6")
RG_API = "2022-10-01"
DCR = os.environ.get("C6_DCR", "ws-c6-" + str(int(time.time())))
STREAM = "Custom-Logs"

TOTAL_ROWS = 5000
BATCH = 100
ROW_BYTES = 500
RG_ACCOUNTS = 100

RESULT_FILE = os.environ.get(
    "C6_RESULT_FILE",
    "/Users/sac/smalt/docs/jira/v26.10.14/bench/c6-sentinel-rg.jsonl")

results = []


def probe(name, ok, detail):
    tag = "PASS" if ok else "FAIL"
    results.append((name, tag, detail))
    print(f"{tag} {name} :: {detail}", flush=True)


# Dummy credential — substrate is MIX_ENV=test anonymous auth; the SDKs need
# a TokenCredential-shaped object, the server accepts any bearer.
class AnonCred:
    def get_token(self, *scopes, **kwargs):
        return AccessToken("c6-anon-token", time.time() + 3600)


CRED = AnonCred()


def http(method, url, body=None, headers=None, timeout=60):
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode("utf-8", "replace")


def make_rows(start, count):
    # 500-byte telemetry-ish events: pad msg to reach ~500 bytes per row.
    pad = "x" * (ROW_BYTES - 40)
    return [{"TimeGenerated": "2026-10-15T00:00:00Z",
             "msg": f"row-{start + i}",
             "n": start + i,
             "pad": pad} for i in range(count)]


def ingest_batch(rows):
    url = (f"{EGRESS}/dataCollectionRules/{DCR}/streams/{STREAM}"
           f"?api-version=2023-01-01")
    st, body = http("POST", url, rows)
    if st != 204:
        raise RuntimeError(f"ingest -> {st}: {body}")
    return st


def logs_client():
    return LogsQueryClient(endpoint=EGRESS, credential=CRED)


def run_kql(client, query, expect_rows=None, label=""):
    t0 = time.perf_counter()
    res = client.query_workspace(DCR, query, timespan=None,
                                 enforce_https=False)
    dt_ms = (time.perf_counter() - t0) * 1000.0
    assert res.status == LogsQueryStatus.SUCCESS, \
        f"{label} status={res.status}"
    table = res.tables[0]
    if expect_rows is not None:
        assert len(table.rows) == expect_rows, \
            f"{label}: rows={len(table.rows)} expected {expect_rows}"
    return dt_ms, len(table.rows)


def pct(vals, p):
    v = sorted(vals)
    return v[round((p / 100.0) * (len(v) - 1))] if v else 0.0


def emit(surface, op, n, ops, p50, p95, p99, errors, **extra):
    rec = {"lane": "c6", "surface": surface, "op": op, "n": n,
           "ops_per_sec": round(ops, 2), "p50_ms": round(p50, 3),
           "p95_ms": round(p95, 3), "p99_ms": round(p99, 3),
           "errors": errors}
    rec.update(extra)
    with open(RESULT_FILE, "a") as f:
        f.write(json.dumps(rec) + "\n")


def machine_spec():
    import subprocess
    cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                         capture_output=True, text=True).stdout.strip()
    cores = subprocess.run(["sysctl", "-n", "hw.ncpu"],
                           capture_output=True, text=True).stdout.strip()
    ram = int(subprocess.run(["sysctl", "-n", "hw.memsize"],
                             capture_output=True, text=True).stdout) // (1024 ** 3)
    elixir = subprocess.run(["elixir", "-e", "IO.puts System.version()"],
                            capture_output=True, text=True).stdout.strip()
    otp = subprocess.run(["elixir", "-e",
                          "IO.puts :erlang.system_info(:otp_release)"],
                         capture_output=True, text=True).stdout.strip()
    darwin = subprocess.run(["sw_vers", "-productVersion"],
                            capture_output=True, text=True).stdout.strip()
    return {"cpu": cpu, "cores": int(cores), "ram_gb": ram,
            "elixir": elixir, "otp": otp, "darwin": darwin}


# ---------------------------------------------------------------------------
# Phase 1: INGEST
# ---------------------------------------------------------------------------
def phase1_ingest():
    print(f"\n== Phase 1: INGEST {TOTAL_ROWS} rows x {ROW_BYTES}B, "
          f"batches of {BATCH} ==", flush=True)
    lats = []
    errors = 0
    n_batches = TOTAL_ROWS // BATCH
    for b in range(n_batches):
        rows = make_rows(b * BATCH, BATCH)
        t0 = time.perf_counter()
        try:
            ingest_batch(rows)
        except Exception as e:
            errors += 1
            print(f"  ingest batch {b} ERROR: {e}", flush=True)
            continue
        lats.append((time.perf_counter() - t0) * 1000.0)
    rows_s = len(lats) * BATCH / (sum(lats) / 1000.0)
    p50, p95, p99 = pct(lats, 50), pct(lats, 95), pct(lats, 99)
    print(f"  batches={len(lats)} errors={errors} rows/s={rows_s:.1f} "
          f"p50={p50:.2f}ms p95={p95:.2f}ms p99={p99:.2f}ms", flush=True)
    emit("sentinel", "dcr_ingest_500B_rows", len(lats) * BATCH, rows_s,
         p50, p95, p99, errors,
         unit="rows_per_sec", batch_rows=BATCH, row_bytes=ROW_BYTES,
         total_rows_target=TOTAL_ROWS)
    return errors == 0


# ---------------------------------------------------------------------------
# Phase 2: QUERY-UNDER-INGEST
# ---------------------------------------------------------------------------
KQL_Q = "Custom-Logs | where n >= 100 | order by n desc | take 10 | project n, msg"


def kql_lats(client, iters, stop_evt=None, collect=None):
    lats, errs = [], 0
    for _ in range(iters):
        try:
            dt, rows = run_kql(client, KQL_Q, label="query-under-ingest")
            lats.append(dt)
            if collect is not None:
                collect.append(rows)
        except Exception as e:
            errs += 1
            if not getattr(e, "_c6_quiet", False):
                print(f"  query error: {type(e).__name__}: {e}", flush=True)
        if stop_evt is not None and stop_evt.is_set():
            break
    return lats, errs


def phase2_query_under_ingest():
    print("\n== Phase 2: QUERY-UNDER-INGEST (idle baseline vs concurrent) ==",
          flush=True)
    client = logs_client()
    idle_lats, idle_errs = kql_lats(client, 30)
    if not idle_lats:
        probe("phase2.idle baseline", False, "no successful idle queries")
        return False
    idle = (pct(idle_lats, 50), pct(idle_lats, 95), pct(idle_lats, 99),
            1000.0 * len(idle_lats) / sum(idle_lats))
    emit("sentinel", "kql_where_order_project_take_idle", len(idle_lats),
         idle[3], idle[0], idle[1], idle[2], idle_errs)
    print(f"  IDLE: n={len(idle_lats)} q/s={idle[3]:.1f} "
          f"p50={idle[0]:.2f} p95={idle[1]:.2f} p99={idle[2]:.2f}", flush=True)

    # Concurrent: ingest stream + query loop
    stop = threading.Event()
    q_lats, q_errs = [], [0]
    ing_errs = [0]
    ing_count = [0]

    def ingest_worker():
        i = 0
        while not stop.is_set():
            try:
                ingest_batch(make_rows(TOTAL_ROWS + i * BATCH, BATCH))
                ing_count[0] += BATCH
                i += 1
            except Exception as e:
                ing_errs[0] += 1
                print(f"  concurrent ingest error: {e}", flush=True)
                time.sleep(0.05)

    def query_worker():
        # Separate client (thread-safe use anyway); collect latencies.
        cl = logs_client()
        while not stop.is_set():
            try:
                dt, _ = run_kql(cl, KQL_Q, label="under-load")
                q_lats.append(dt)
            except Exception as e:
                q_errs[0] += 1
                print(f"  under-load query error: {e}", flush=True)

    ing = threading.Thread(target=ingest_worker, daemon=True)
    q1 = threading.Thread(target=query_worker)
    q2 = threading.Thread(target=query_worker)
    ing.start(); q1.start(); q2.start()
    time.sleep(10.0)          # 10 s interference window
    stop.set()
    q1.join(); q2.join()
    load = (pct(q_lats, 50), pct(q_lats, 95), pct(q_lats, 99),
            len(q_lats) / 10.0)
    emit("sentinel", "kql_where_order_project_take_under_ingest",
         len(q_lats), load[3], load[0], load[1], load[2],
         q_errs[0] + ing_errs[0],
         ingest_rows_during_window=ing_count[0],
         window_s=10.0, query_threads=2)
    print(f"  LOAD: n={len(q_lats)} q/s={load[3]:.1f} "
          f"p50={load[0]:.2f} p95={load[1]:.2f} p99={load[2]:.2f} "
          f"(ingested {ing_count[0]} rows during window, "
          f"ingest errors={ing_errs[0]})", flush=True)
    degr = (load[1] / idle[1] if idle[1] else float("inf"))
    print(f"  INTERFERENCE: p95 ratio load/idle = {degr:.2f}x", flush=True)
    ok = idle_errs == 0 and q_errs[0] == 0 and ing_errs[0] == 0
    return ok


# ---------------------------------------------------------------------------
# Phase 3: Resource Graph over seeded storage accounts
# ---------------------------------------------------------------------------
def seed_accounts():
    made = 0
    for i in range(1, RG_ACCOUNTS + 1):
        url = (f"{ARM}/subscriptions/{SUB}/resourceGroups/c6rg/providers/"
               f"Microsoft.Storage/storageAccounts/c6sa{i}?api-version=2021-04-01")
        st, body = http("PUT", url, {"location": "eastus",
                                     "properties": {"skuName": "Standard_LRS"}})
        if st not in (200, 201, 202):
            raise RuntimeError(f"seed c6sa{i} -> {st}: {body}")
        made += 1
    return made


def phase3_rg():
    print(f"\n== Phase 3: Resource Graph over {RG_ACCOUNTS} seeded accounts ==",
          flush=True)
    made = seed_accounts()
    print(f"  [seed] {made} storage accounts via ARM PUT", flush=True)
    client = ResourceGraphClient(credential=CRED, base_url=EGRESS,
                                 api_version=RG_API)
    req = QueryRequest(subscriptions=[SUB], query="project id, name, type",
                       options=QueryRequestOptions(top=RG_ACCOUNTS))
    t0 = time.perf_counter()
    resp = client.resources(req, enforce_https=False)
    assert resp.total_records == RG_ACCOUNTS, \
        f"totalRecords={resp.total_records}"
    first_ms = (time.perf_counter() - t0) * 1000.0
    print(f"  sanity: totalRecords={resp.total_records} "
          f"({first_ms:.1f} ms)", flush=True)

    lats, errs = [], 0
    deadline = time.perf_counter() + 10.0
    while time.perf_counter() < deadline:
        t0 = time.perf_counter()
        try:
            client.resources(req, enforce_https=False)
            lats.append((time.perf_counter() - t0) * 1000.0)
        except Exception as e:
            errs += 1
            print(f"  rg error: {type(e).__name__}: {e}", flush=True)
    qps = len(lats) / 10.0
    p50, p95, p99 = pct(lats, 50), pct(lats, 95), pct(lats, 99)
    print(f"  RG: n={len(lats)} q/s={qps:.1f} p50={p50:.2f} p95={p95:.2f} "
          f"p99={p99:.2f} errors={errs}", flush=True)
    emit("resourcegraph", "rg_project_top100", len(lats), qps,
         p50, p95, p99, errs, seeded_accounts=made)
    return errs == 0 and len(lats) > 0


# ---------------------------------------------------------------------------
# Phase 4: TAKE CAP under load
# ---------------------------------------------------------------------------
def phase4_take_cap():
    print("\n== Phase 4: TAKE CAP under ingest load (101-row fence) ==",
          flush=True)
    stop = threading.Event()
    errs = [0]
    count = [0]

    def ingest_worker():
        i = 0
        while not stop.is_set():
            try:
                ingest_batch(make_rows(100_000 + i * BATCH, BATCH))
                i += 1
                count[0] += BATCH
            except Exception as e:
                errs[0] += 1
                print(f"  take-cap ingest error: {e}", flush=True)
                time.sleep(0.05)

    ing = threading.Thread(target=ingest_worker, daemon=True)
    ing.start()

    client = logs_client()
    checks, cap_ok, cap_bad = 0, 0, 0
    deadline = time.perf_counter() + 8.0
    lats = []
    while time.perf_counter() < deadline:
        try:
            dt, rows = run_kql(client, "Custom-Logs | take 100000",
                               label="take-cap")
            lats.append(dt)
            checks += 1
            if rows == 101:
                cap_ok += 1
            else:
                cap_bad += 1
                print(f"  CAP VIOLATION: take 100000 -> {rows} rows", flush=True)
        except Exception as e:
            errs[0] += 1
            print(f"  take-cap query error: {type(e).__name__}: {e}",
                  flush=True)
    stop.set()
    ing.join(timeout=5)

    total_rows_at_query = TOTAL_ROWS + count[0]
    print(f"  checks={checks} cap_ok={cap_ok} cap_bad={cap_bad} "
          f"(~{total_rows_at_query} rows in table)", flush=True)
    emit("sentinel", "kql_take100000_cap_under_load", checks,
         (checks / 8.0), pct(lats, 50), pct(lats, 95), pct(lats, 99),
         errs[0] + cap_bad,
         cap_ok=cap_ok, cap_violations=cap_bad,
         approx_table_rows=total_rows_at_query)
    return checks > 0 and cap_bad == 0


# ---------------------------------------------------------------------------
def main():
    print("== C-6 Sentinel ingest + KQL + Resource Graph bench ==", flush=True)
    print(f"ARM={ARM} EGRESS={EGRESS} DCR={DCR}", flush=True)
    with open(RESULT_FILE, "a") as f:
        pass  # ensure file exists

    ok1 = phase1_ingest()
    ok2 = phase2_query_under_ingest()
    ok3 = phase3_rg()
    ok4 = phase4_take_cap()

    n_pass = sum(1 for _, s, _ in results if s == "PASS")
    n_fail = sum(1 for _, s, _ in results if s == "FAIL")
    print(f"\n== PHASES: {n_pass} ok / {n_fail} failed ==", flush=True)
    print(f"results: {RESULT_FILE}", flush=True)
    return 0 if (ok1 and ok2 and ok3 and ok4) else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Cosmos bulk stress harness for the smalt substrate (stdlib-only).

Spawns one live substrate (`mix run --no-halt`), then over the real data-plane
HTTP surface (plain HTTP on :8443) drives, in order:

  1. Insert 20,000 docs   (10 partitions x 2k, 16 threads) -> wall, rps, p50/p99
  2. Point-read 2,000 random docs                          -> p50/p99
  3. Cross-partition query at 20k-doc scale                -> latency + page-cap
     honesty: the engine hard-caps at 100 docs/query with NO continuation
     token, so the assertion is first-100 semantics returned without hanging.
  4. Deep pagination: 100 sequential page requests         -> latency; records
     whether any continuation token is emitted (there is none — every "page"
     returns the same first 100 docs; recorded honestly in the receipt).
  5. Delete sweep of all 20,000 docs                       -> wall, rps, and
     RSS reclamation.

Memory: substrate RSS is sampled before inserts, after inserts, and after the
delete sweep (the BEAM listening on :8443, via lsof+ps). bytes/doc is the
insert-phase RSS delta over 20,000. No mocks: every measurement is a real
HTTP round-trip against the live substrate.
"""
import concurrent.futures
import http.client
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = "127.0.0.1"
DATA_PORT = 8443
DB = "stressdb"
COLL = "stresscoll"
N_PARTITIONS = 10
DOCS_PER_PARTITION = 2000
TOTAL_DOCS = N_PARTITIONS * DOCS_PER_PARTITION
THREADS = 16
PAYLOAD_BYTES = 256
QUERY_ROUNDS = 20
PAGES = 100
PAGINATION_TIMEOUT_S = 30.0
RECEIPT_PATH = os.path.join(REPO, "tmp", "cosmos_bulk_receipt.json")
SCHEMA = "smalt-cosmos-bulk/v1"

PK_HEADER = "x-ms-documentdb-partitionkey"


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    try:
        os.killpg(os.getpgid(SUBSTRATE["proc"].pid), signal.SIGKILL)
    except Exception:
        pass
    sys.exit(code)


SUBSTRATE = {"proc": None}


def free_port():
    s = socket.socket()
    s.bind((HOST, 0))
    port = s.getsockname()[1]
    s.close()
    return port


EGRESS_PORT = None


def spawn_substrate():
    """Spawn the substrate on free non-default ports (other lanes may hold
    the defaults on this shared checkout). Ports are pinned via
    Application.put_env/--eval, matching the existing lane pattern."""
    global EGRESS_PORT, AMQP_PORT, DATA_PORT
    # Bind ALL ports simultaneously so the OS cannot hand the same one out
    # twice (sequential free_port() calls can collide after close).
    socks = []
    ports = []
    while len(ports) < 5:
        s = socket.socket()
        s.bind((HOST, 0))
        p = s.getsockname()[1]
        if p in ports:
            s.close()
            continue
        ports.append(p)
        socks.append(s)
    for s in socks:
        s.close()
    EGRESS_PORT, AMQP_PORT = ports[0], ports[1]
    DATA_PORT = EGRESS_PORT
    eval_expr = (
        "Application.put_env(:smalt, :egress_port, %d); "
        "Application.put_env(:smalt, :amqp_port, %d); "
        "Application.put_env(:smalt, :arm_port, %d); "
        "Application.put_env(:smalt, :arm_tls_port, %d); "
        "Application.put_env(:smalt, :event_hubs_port, %d); "
        "Application.ensure_all_started(:smalt)" % (
            EGRESS_PORT, AMQP_PORT, ports[2], ports[3], ports[4])
    )
    globals()["ARM_PORT"] = ports[2]
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    proc = subprocess.Popen(
        ["mix", "run", "--no-start", "--no-halt", "--eval", eval_expr],
        cwd=REPO, env=env,
        stdout=open("/tmp/smalt_stress_substrate.log", "w"),
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    SUBSTRATE["proc"] = proc
    return proc


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
            time.sleep(0.01)
    fail_closed(f"substrate never bound :{port} within {timeout_s}s")


def kill_substrate():
    proc = SUBSTRATE["proc"]
    if proc is None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), kill_sig())
    except (ProcessLookupError, PermissionError):
        try:
            proc.kill()
        except Exception:
            pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass
    try:
        out = subprocess.run(["lsof", "-ti", f"tcp:{DATA_PORT}"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        out = ""
    for pid in out.split():
        try:
            os.kill(int(pid), signal.SIGKILL)
        except (ValueError, ProcessLookupError, PermissionError):
            pass


def kill_sig():
    return signal.SIGKILL


_TLS = threading.local()
_TOKEN = {"value": None}


def acquire_token():
    """Dev mode enforces bearer tokens; the ARM STS mints one per beam."""
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10.0)
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
    finally:
        conn.close()


def request(method, path, body=None, headers=None, timeout=30.0):
    """Keep-alive, thread-local connection; reconnects once on stale socket."""
    conn = getattr(_TLS, "conn", None)
    for attempt in (0, 1):
        try:
            if conn is None:
                conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=timeout)
            h = {"Authorization": f"Bearer {_TOKEN['value']}"}
            h.update(headers or {})
            payload = None
            if body is not None:
                payload = body if isinstance(body, str) else json.dumps(body)
                h.setdefault("Content-Type", "application/json")
                h["Content-Length"] = str(len(payload))
            else:
                h.setdefault("Content-Length", "0")
            conn.request(method, path, body=payload, headers=h)
            resp = conn.getresponse()
            raw = resp.read()
            _TLS.conn = conn
            return resp.status, dict(resp.getheaders()), raw
        except (OSError, http.client.HTTPException):
            try:
                conn.close()
            except Exception:
                pass
            conn = None
            _TLS.conn = None
            if attempt == 1:
                raise
    raise RuntimeError("unreachable")


def doc_id(p, i):
    return f"d-{p:03d}-{i:06d}"


def insert_batch(args):
    p, ids = args
    lats = []
    for i in ids:
        doc = {
            "id": doc_id(p, i),
            "pk": f"p{p:03d}",
            "region": f"r{p % 3}",
            "payload": "x" * PAYLOAD_BYTES,
        }
        t0 = time.perf_counter()
        status, _, _ = request(
            "POST", f"/dbs/{DB}/colls/{COLL}/docs", doc,
            headers={PK_HEADER: '["p%03d"]' % p},
        )
        dt = (time.perf_counter() - t0) * 1000.0
        if status != 201:
            return ("insert_error", p, i, status)
        lats.append(dt)
    return ("ok", lats)


def delete_batch(args):
    p, ids = args
    lats = []
    for i in ids:
        t0 = time.perf_counter()
        status, _, _ = request(
            "DELETE", f"/dbs/{DB}/colls/{COLL}/docs/{doc_id(p, i)}",
            headers={PK_HEADER: '["p%03d"]' % p},
        )
        dt = (time.perf_counter() - t0) * 1000.0
        if status != 204:
            return ("delete_error", p, i, status)
        lats.append(dt)
    return ("ok", lats)


def point_read_batch(args):
    p, ids = args
    lats = []
    for i in ids:
        t0 = time.perf_counter()
        status, _, _ = request(
            "GET", f"/dbs/{DB}/colls/{COLL}/docs/{doc_id(p, i)}",
            headers={PK_HEADER: '["p%03d"]' % p},
        )
        dt = (time.perf_counter() - t0) * 1000.0
        if status != 200:
            return ("read_error", p, i, status)
        lats.append(dt)
    return ("ok", lats)


def pct(sorted_vals, p):
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


def lat_stats(vals_ms):
    s = sorted(vals_ms)
    return {
        "n": len(s),
        "min_ms": round(s[0], 3),
        "p50_ms": round(statistics.median(s), 3),
        "p99_ms": round(pct(s, 99), 3),
        "max_ms": round(s[-1], 3),
    }


def substrate_rss_kb():
    """RSS of the BEAM process holding :8443 (via lsof -> ps)."""
    try:
        out = subprocess.run(["lsof", "-ti", f"tcp:{DATA_PORT}", "-sTCP:LISTEN"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return None
    pids = [pid for pid in out.split() if pid.strip()]
    if not pids:
        return None
    total = 0
    for pid in pids:
        try:
            ps = subprocess.run(["ps", "-o", "rss=", "-p", pid],
                                capture_output=True, text=True, timeout=10).stdout
            total += int(ps.strip() or 0)
        except (ValueError, subprocess.TimeoutExpired):
            return None
    return total


def phase(name, started, extra=None):
    wall = time.monotonic() - started
    print(f"  {name}: {wall:.2f}s" + (f" {extra}" if extra else ""))
    return round(wall, 3)


def main():
    # Escape any process-group-wide kill (other lanes pkill beam.smp and sweep
    # default ports on this shared checkout); this harness is session-isolated.
    try:
        os.setsid()
    except OSError:
        pass
    if shutil.which("mix") is None:
        print("[FAULT] mix not in PATH", file=sys.stderr)
        sys.exit(1)

    receipt = {
        "schema": SCHEMA,
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": "darwin/arm64 local",
        "scale": {
            "docs": TOTAL_DOCS,
            "partitions": N_PARTITIONS,
            "docs_per_partition": DOCS_PER_PARTITION,
            "threads": THREADS,
            "payload_bytes": PAYLOAD_BYTES,
        },
    }
    errors = []

    print("[STRESS] spawning substrate")
    # Shared-checkout reality: other lanes pkill beam.smp and sweep ports.
    # Retry boot + a liveness probe up to 5 times before giving up.
    proc = None
    for boot in range(5):
        proc = spawn_substrate()
        wait_for_port(DATA_PORT, proc)
        try:
            acquire_token()
            # liveness probe: substrate can be pkill'd between bind and use
            request("GET", "/dbs", timeout=5.0)
            if proc.poll() is not None:
                raise OSError("substrate died between bind and probe")
            break
        except (OSError, http.client.HTTPException) as e:
            print(f"  boot attempt {boot + 1} lost substrate ({e}); retrying")
            kill_substrate()
            time.sleep(2)
    else:
        fail_closed("substrate could not stay alive after 5 boot attempts")
    try:
        print(f"  data plane up on :{DATA_PORT}")

        # Provision db + container (pk = /pk)
        s, _, b = request("POST", "/dbs", {"id": DB})
        if s not in (200, 201):
            errors.append(f"create db -> {s}")
        s, _, b = request("POST", f"/dbs/{DB}/colls", {
            "id": COLL,
            "partitionKey": {"paths": ["/pk"]},
        })
        if s != 201:
            errors.append(f"create coll -> {s}")

        rss_before = substrate_rss_kb()
        receipt["rss_before_kb"] = rss_before

        # ---- Phase 1: bulk insert -------------------------------------------
        print(f"[STRESS] insert {TOTAL_DOCS} docs "
              f"({N_PARTITIONS} partitions x {DOCS_PER_PARTITION}, {THREADS} threads)")
        t0 = time.monotonic()
        work = [(p, range(DOCS_PER_PARTITION)) for p in range(N_PARTITIONS)]
        lats = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as pool:
            for res in pool.map(insert_batch, work):
                if res[0] != "ok":
                    errors.append(f"insert {res[1:]}")
                else:
                    lats.extend(res[1])
        wall_ins = time.monotonic() - t0
        ins = lat_stats(lats)
        ins.update({
            "wall_s": round(wall_ins, 3),
            "rps": round(len(lats) / wall_ins, 1),
            "errors": len(errors),
        })
        receipt["insert"] = ins
        print(f"  wall {ins['wall_s']}s  {ins['rps']} rps  "
              f"p50 {ins['p50_ms']}ms  p99 {ins['p99_ms']}ms  errs {len(errors)}")

        rss_after_insert = substrate_rss_kb()
        receipt["rss_after_insert_kb"] = rss_after_insert

        # ---- Phase 2: point reads -------------------------------------------
        print(f"[STRESS] point-read 2000 random docs")
        import random
        rng = random.Random(20260114)
        sample = [(rng.randrange(N_PARTITIONS), rng.randrange(DOCS_PER_PARTITION))
                  for _ in range(2000)]
        by_p = {}
        for p, i in sample:
            by_p.setdefault(p, []).append(i)
        t0 = time.monotonic()
        read_lats = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as pool:
            for res in pool.map(point_read_batch, sorted(by_p.items())):
                if res[0] != "ok":
                    errors.append(f"read {res[1:]}")
                else:
                    read_lats.extend(res[1])
        wall_rd = time.monotonic() - t0
        rd = lat_stats(read_lats)
        rd["wall_s"] = round(wall_rd, 3)
        rd["rps"] = round(len(read_lats) / wall_rd, 1)
        receipt["point_reads"] = rd
        print(f"  p50 {rd['p50_ms']}ms  p99 {rd['p99_ms']}ms  ({rd['rps']} rps)")

        # ---- Phase 3: cross-partition query at 20k scale --------------------
        print(f"[STRESS] cross-partition query x{QUERY_ROUNDS} at 20k-doc scale")
        qlats = []
        cap_ok = True
        count_ok = True
        for _ in range(QUERY_ROUNDS):
            t0 = time.perf_counter()
            s, h, b = request(
                "POST", f"/dbs/{DB}/colls/{COLL}/docs",
                body={"query": "SELECT * FROM c"},
                headers={
                    "Content-Type": "application/query+json",
                    "Content-Length": str(len(json.dumps({"query": "SELECT * FROM c"}))),
                },
            )
            dt = (time.perf_counter() - t0) * 1000.0
            if s != 200:
                errors.append(f"query -> {s}")
                cap_ok = False
                continue
            qlats.append(dt)
            docset = json.loads(b)
            n = docset.get("_count", -1)
            if n > 100:
                cap_ok = False
                errors.append(f"query returned {n} docs (>100 cap violated)")
            if n != 100:
                count_ok = False
        q = lat_stats(qlats)
        q.update({
            "rounds": QUERY_ROUNDS,
            "page_cap_100_respected": cap_ok,
            "always_full_100": count_ok,
            "continuation_token_emitted": False,  # verified below in phase 4
        })
        receipt["cross_partition_query"] = q
        print(f"  p50 {q['p50_ms']}ms  p99 {q['p99_ms']}ms  "
              f"cap100={cap_ok} full100={count_ok}")

        # ---- Phase 4: deep pagination (100 page requests) -------------------
        print(f"[STRESS] deep pagination: {PAGES} sequential page requests")
        page_lats = []
        continuation_seen = False
        t0 = time.monotonic()
        first_page_ids = None
        same_page = True
        for page in range(PAGES):
            body = {"query": "SELECT * FROM c"}
            t0p = time.perf_counter()
            s, h, b = request(
                "POST", f"/dbs/{DB}/colls/{COLL}/docs",
                body=body,
                headers={
                    "Content-Type": "application/query+json",
                    PK_HEADER: '["p000"]',  # page within one partition's 2k docs
                    "Content-Length": str(len(body)),
                },
            )
            dt = (time.perf_counter() - t0p) * 1000.0
            if s != 200:
                errors.append(f"page {page} -> {s}")
                break
            page_lats.append(dt)
            if any(k.lower() == "x-ms-continuation" for k in h):
                continuation_seen = True
            ids = [d["id"] for d in json.loads(b).get("Documents", [])]
            if page == 0:
                first_page_ids = ids
            elif ids != first_page_ids:
                same_page = False
        wall_pg = time.monotonic() - t0
        pg = lat_stats(page_lats) if page_lats else {"n": 0}
        pg.update({
            "pages": PAGES,
            "wall_s": round(wall_pg, 3),
            "continuation_token_emitted": continuation_seen,
            "every_page_identical_first_100": same_page,
            "no_hang_assert": True if len(page_lats) == PAGES else False,
        })
        receipt["deep_pagination"] = pg
        receipt["cross_partition_query"]["continuation_token_emitted"] = continuation_seen
        print(f"  pages {len(page_lats)}/{PAGES}  wall {pg['wall_s']}s  "
              f"p99 {pg.get('p99_ms')}ms  continuation={continuation_seen} "
              f"identical={same_page}")

        # ---- Phase 5: delete sweep ------------------------------------------
        print(f"[STRESS] delete sweep {TOTAL_DOCS} docs")
        t0 = time.monotonic()
        del_lats = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=THREADS) as pool:
            for res in pool.map(delete_batch, work):
                if res[0] != "ok":
                    errors.append(f"delete {res[1:]}")
                else:
                    del_lats.extend(res[1])
        wall_del = time.monotonic() - t0
        dl = lat_stats(del_lats)
        dl.update({
            "wall_s": round(wall_del, 3),
            "rps": round(len(del_lats) / wall_del, 1),
        })
        receipt["delete_sweep"] = dl

        # ---- Phase 6: residual + memory -------------------------------------
        s, _, b = request(
            "POST", f"/dbs/{DB}/colls/{COLL}/docs",
            body={"query": "SELECT * FROM c"},
            headers={"Content-Type": "application/query+json"},
        )
        residual = json.loads(b).get("_count", -1) if s == 200 else -1
        receipt["residual_docs"] = residual
        print(f"  residual docs after sweep: {residual}")

        rss_after_delete = substrate_rss_kb()
        receipt["rss_after_delete_kb"] = rss_after_delete
        if rss_before and rss_after_insert:
            growth = rss_after_insert - rss_before
            receipt["rss_growth_kb"] = growth
            receipt["bytes_per_doc_estimate"] = round(growth * 1024 / TOTAL_DOCS, 1)
            print(f"  RSS growth {growth} KB -> "
                  f"~{receipt['bytes_per_doc_estimate']} bytes/doc")
        if rss_after_insert and rss_after_delete:
            reclaimed = rss_after_insert - rss_after_delete
            receipt["rss_reclaimed_kb"] = reclaimed
            print(f"  RSS reclaimed after delete: {reclaimed} KB")

        receipt["errors"] = errors[:50]
        receipt["error_count"] = len(errors)
        receipt["verdict"] = (
            "PASS" if not errors and cap_ok and residual == 0
            and pg.get("no_hang_assert") is True else "FAIL"
        )
        os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)
        with open(RECEIPT_PATH, "w") as f:
            json.dump(receipt, f, indent=2)
        print(f"[STRESS] receipt -> {RECEIPT_PATH}  verdict={receipt['verdict']}")

    finally:
        kill_substrate()
        print("[STRESS] substrate killed")


if __name__ == "__main__":
    main()

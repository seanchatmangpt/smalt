#!/usr/bin/env python3
"""B-5 lane: Python SDK parity numbers — azure-storage-blob + azure-cosmos.

Mirrors the B-2 (blob) / B-3 (cosmos) TS-SDK surfaces so TS-vs-Python SDK
overhead is directly comparable:

  blob   put-block-blob 8 KiB sustained ops/sec + point latencies
  blob   download MB/s (16 MiB blob)
  cosmos point-read latency percentiles (>=500 reads)
  cosmos `SELECT * FROM c` wall time over 1000 docs

Usage (run under each lane venv):
  .venv-blob/bin/python   scripts/bench/b5_python_mirror.py blob   <egress_base>
  .venv-cosmos/bin/python scripts/bench/b5_python_mirror.py cosmos <egress_base>

Auth shapes mirror test/sdk-python/py_storage_blob.py (SharedKey conn string,
account smaltacct) and py_cosmos.py (64-hex master key, substrate anonymous
mode signs with real master-key wire headers).

Emits one JSONL record per measure in lib.sh result format.
"""
import base64
import json
import secrets
import statistics
import subprocess
import sys
import time

BASE = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:39051"
MODE = sys.argv[1] if len(sys.argv) > 1 else "blob"
ACCOUNT = "smaltacct"
KEY = "smaltacct-key"
LANE = "b5"
MACHINE = json.loads(subprocess.run(
    ["bash", "-c", "source scripts/bench/lib.sh && bench_machine_spec"],
    capture_output=True, text=True, check=True).stdout)

WARMUP_OPS = 50
WINDOW_S = 10.0
DOWNLOAD_BYTES = 1_048_576  # substrate per-PUT cap; Put Block List path diverges (see receipt)
DOWNLOAD_ITERS = 20
POINT_READS = 500
QUERY_ITERS = 5
SEED_DOCS = 1000


def emit(file, surface, op, n, ops, p50, p95, p99, errors, extra=""):
    rec = {
        "lane": LANE, "surface": surface, "op": op, "n": n,
        "ops_per_sec": round(ops, 2), "p50_ms": round(p50, 3),
        "p95_ms": round(p95, 3), "p99_ms": round(p99, 3),
        "errors": errors, "machine": MACHINE,
    }
    if extra:
        rec.update(extra)
    with open(file, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps(rec))


def pcts(lat_ms):
    v = sorted(lat_ms)
    if not v:
        return 0.0, 0.0, 0.0
    def pct(p):
        return v[round((p / 100.0) * (len(v) - 1))]
    return pct(50), pct(95), pct(99)


RESULTS = "docs/jira/v26.10.14/bench/b5-python-mirror.jsonl"


# ---------------------------------------------------------------------------
# Blob surface
# ---------------------------------------------------------------------------
def run_blob():
    from azure.storage.blob import BlobServiceClient

    conn = (
        f"DefaultEndpointsProtocol=http;AccountName={ACCOUNT};"
        f"AccountKey={base64.b64encode(KEY.encode()).decode()};"
        f"BlobEndpoint={BASE}/{ACCOUNT};"
    )
    svc = BlobServiceClient.from_connection_string(
        conn, max_single_put_size=1024 * 1024)  # substrate: 1 MiB per-PUT cap
    cname = f"b5-bench-{int(time.time() * 1000)}"
    # Mutable container via the substrate opt-out header (raw PUT, same as
    # py_storage_blob.make_mutable_container) so deletes/overwrites are legal.
    import urllib.request
    req = urllib.request.Request(
        f"{BASE}/{ACCOUNT}/{cname}", method="PUT", data=b"",
        headers={"x-ms-version": "2021-04-01", "x-ms-immutable-policy": "false"})
    with urllib.request.urlopen(req, timeout=30) as r:
        assert r.status == 201, r.status
    cont = svc.get_container_client(cname)
    blob = cont.get_blob_client("b5-8k.bin")
    payload = secrets.token_bytes(8192)

    errors = 0

    # -- put-block-blob 8 KiB: sustained ops/sec + point latencies ----------
    for _ in range(WARMUP_OPS):
        try:
            blob.upload_blob(payload, overwrite=True)
        except Exception:
            errors += 1
    lat = []
    errors = 0
    t_end = time.perf_counter() + WINDOW_S
    n = 0
    while time.perf_counter() < t_end:
        op0 = time.perf_counter()
        try:
            blob.upload_blob(payload, overwrite=True)
        except Exception:
            errors += 1
        lat.append((time.perf_counter() - op0) * 1000.0)
        n += 1
    wall = WINDOW_S
    p50, p95, p99 = pcts(lat)
    emit(RESULTS, "blob", "put_block_blob_8k", n, n / wall, p50, p95, p99, errors,
         extra={"payload_bytes": 8192, "window_s": WINDOW_S, "warmup_ops": WARMUP_OPS})

    # -- download MB/s -------------------------------------------------------
    big = secrets.token_bytes(DOWNLOAD_BYTES)
    big_blob = cont.get_blob_client("b5-big.bin")
    # NOTE: substrate Put Block List currently stores the request XML as the
    # blob body (divergence, see receipt) — so the download measure uses a
    # single Put Blob at the substrate's 1 MiB per-PUT cap.
    big_blob.upload_blob(big, overwrite=True)
    derr = 0
    for _ in range(3):
        try:
            big_blob.download_blob().readall()
        except Exception:
            derr += 1
    lat = []
    total = 0
    t0 = time.perf_counter()
    for _ in range(DOWNLOAD_ITERS):
        op0 = time.perf_counter()
        try:
            data = big_blob.download_blob().readall()
            if len(data) != len(big):
                derr += 1
            else:
                total += len(data)
        except Exception:
            derr += 1
        lat.append((time.perf_counter() - op0) * 1000.0)
    wall = time.perf_counter() - t0
    p50, p95, p99 = pcts(lat)
    mibps = total / (1024 * 1024) / wall
    emit(RESULTS, "blob", "download_1mib", DOWNLOAD_ITERS, mibps,
         p50, p95, p99, derr,
         extra={"bytes_total": total, "wall_s": round(wall, 3),
                "unit": "MiB_per_s", "blob_bytes": len(big),
                "iters_downloaded": DOWNLOAD_ITERS})
    try:
        big_blob.delete_blob()
    except Exception:
        pass
    print(f"BLOB DONE: put {n} ops, download {mibps:.1f} MiB/s", file=sys.stderr)


# ---------------------------------------------------------------------------
# Cosmos surface
# ---------------------------------------------------------------------------
def run_cosmos():
    import azure.cosmos.cosmos_client as cc

    client = cc.CosmosClient(BASE, credential=secrets.token_hex(32))
    db = client.create_database("b5bench-" + secrets.token_hex(4))
    cont = db.create_container(id="c1", partition_key="/pk")
    errors = 0

    # -- seed 1000 docs across 10 partitions --------------------------------
    docs = [{"id": f"d{i}", "pk": f"p{i % 10}", "n": i} for i in range(SEED_DOCS)]
    for d in docs:
        try:
            cont.create_item(d)
        except Exception:
            errors += 1

    # -- point reads (500) ----------------------------------------------------
    lat = []
    rerr = 0
    for i in range(POINT_READS):
        d = docs[i]
        op0 = time.perf_counter()
        try:
            got = cont.read_item(d["id"], partition_key=d["pk"])
            if got["id"] != d["id"]:
                rerr += 1
        except Exception:
            rerr += 1
        lat.append((time.perf_counter() - op0) * 1000.0)
    wall = sum(lat) / 1000.0
    p50, p95, p99 = pcts(lat)
    emit(RESULTS, "cosmos", "point_read", POINT_READS, POINT_READS / wall,
         p50, p95, p99, rerr, extra={"seed_docs": SEED_DOCS, "unit": "ops_per_sec"})

    # -- SELECT * FROM c over 1000 docs: wall time ---------------------------
    walls = []
    qerr = 0
    rows_last = 0
    for _ in range(QUERY_ITERS):
        t0 = time.perf_counter()
        try:
            rows = list(cont.query_items("SELECT * FROM c",
                                         enable_cross_partition_query=True))
            rows_last = len(rows)
        except Exception:
            qerr += 1
        walls.append((time.perf_counter() - t0) * 1000.0)
    p50, p95, p99 = pcts(walls)
    med = statistics.median(walls)
    emit(RESULTS, "cosmos", "query_select_all_1000docs", rows_last,
         1000.0 / (med / 1000.0), p50, p95, p99, qerr,
         extra={"wall_ms_median": round(med, 3), "iters": QUERY_ITERS,
                "unit": "queries_per_sec_at_1000_docs"})
    print(f"COSMOS DONE: {rows_last} docs per full scan", file=sys.stderr)


if __name__ == "__main__":
    {"blob": run_blob, "cosmos": run_cosmos}[MODE]()

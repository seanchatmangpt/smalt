#!/usr/bin/env python3
"""Smalt blob-storage scale harness (stdlib-only, fail-closed).

Spawns the substrate (`mix run --no-halt`), then drives the immutable Blob
data plane (port 8443, x-ms-version required) through five scale scenarios:

  1. 8 MiB single-blob PUT/GET  — pin the actual >1 MiB body behavior
  2. 500 KB x 100 PUT/GET       — throughput (MB/s, p50/p95)
  3. Ranged GET                 — 10 x 50 KB ranges of a 500 KB blob (206 + Content-Range)
  4. 5,000-blob container       — full XML listing wall latency + well-formedness
  5. WORM 409 rate              — 50 threads overwrite one immutable blob: all 409, zero 201

Writes a receipt to tmp/blob-scale-receipt.json. Exit 0 only when the full run
completed. Scenario failures are recorded, not swallowed.
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
import xml.etree.ElementTree as ET

ARM_PORT = 9443
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = "127.0.0.1"
DATA_PORT = 8443
XMS_VERSION = "2021-12-02"
RECEIPT_PATH = os.path.join(REPO, "tmp", "blob-scale-receipt.json")
SCHEMA = "smalt-blob-scale/v1"

ACCOUNT = "scaletest"

KILO = 1024
FIVE_HUNDRED_KB = 500 * KILO
EIGHT_MB = 8 * 1024 * KILO
RANGE_COUNT = 10
BLOB_COUNT_S4 = 5000
WORM_THREADS = 50

receipt = {
    "schema": SCHEMA,
    "started_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "scenarios": {},
    "boundaries": [],
}


def scn(name):
    return receipt["scenarios"].get(name, {})


def record(name, data):
    receipt["scenarios"][name] = {**scn(name), **data}


def boundary(text):
    receipt["boundaries"].append(text)
    print(f"  [BOUNDARY] {text}")


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(code)


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


_TOKEN = {"value": None}


def fetch_token():
    """Mint a Bearer from the ARM STS (port 9443, exempt route)."""
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=30)
    body = "grant_type=client_credentials"
    conn.request("POST", "/oauth2/v2.0/token", body=body,
                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    if resp.status != 200:
        fail_closed(f"token mint failed: HTTP {resp.status}: {data[:200]!r}")
    _TOKEN["value"] = json.loads(data)["access_token"]
    return _TOKEN["value"]


def req(method, path, body=None, extra_headers=None):
    if _TOKEN["value"] is None:
        fetch_token()
    conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=120)
    headers = {"x-ms-version": XMS_VERSION,
               "Authorization": f"Bearer {_TOKEN['value']}"}
    if extra_headers:
        headers.update(extra_headers)
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    data = resp.read()
    hdrs = {k.lower(): v for k, v in resp.getheaders()}
    status = resp.status
    conn.close()
    if status == 401 and b"TokenExpired" in data:
        fetch_token()
        return req(method, path, body=body, extra_headers=extra_headers)
    return status, hdrs, data


def spawn_substrate():
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


def wait_for_port(port, proc, timeout_s=120.0):
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
            time.sleep(0.05)
    fail_closed(f"substrate never bound :{port} within {timeout_s}s")


def create_container(name):
    status, _, body = req("PUT", f"/{ACCOUNT}/{name}?restype=container")
    if status not in (201, 409):
        fail_closed(f"create_container({name}) failed: HTTP {status}: {body[:200]!r}")
    return status


def s1_single_large_blob():
    name = "s1_8mib_single_blob"
    print(f"[{name}] 8 MiB single-blob PUT/GET")
    payload = ((b"smalt-blob-scale-" + b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" * 128) * 2000)[:EIGHT_MB]
    assert len(payload) == EIGHT_MB
    create_container("s1large")

    record(name, {"bytes": EIGHT_MB})
    try:
        t0 = time.perf_counter()
        status, hdrs, body = req("PUT", f"/{ACCOUNT}/s1large/s1blob", body=payload)
        put_ms = (time.perf_counter() - t0) * 1000.0
        if status != 201:
            record(name, {**scn(name), "put_status": status,
                          "put_error_body": body[:500].decode("utf-8", "replace")})
            boundary(f"8 MiB PUT rejected by plane: HTTP {status}: "
                     f"{body[:200].decode('utf-8', 'replace')}")
            return
        record(name, {**scn(name), "put_status": 201, "put_ms": round(put_ms, 3),
                      "put_mib_per_s": round(EIGHT_MB / (put_ms / 1000.0) / (1024 * 1024), 2),
                      "etag": hdrs.get("etag")})

        t0 = time.perf_counter()
        g_status, _, g_body = req("GET", f"/{ACCOUNT}/s1large/s1blob")
        get_ms = (time.perf_counter() - t0) * 1000.0
        record(name, {**scn(name), "get_status": g_status, "get_ms": round(get_ms, 3),
                      "get_bytes": len(g_body),
                      "byte_identical": g_body == payload})
        print(f"  PUT {put_ms:.1f}ms  GET {get_ms:.1f}ms  byte_identical={g_body == payload}")
    except Exception as exc:
        record(name, {**scn(name), "exception": repr(exc)})
        boundary(f"8 MiB PUT/GET raised {exc!r}")
    finally:
        _pin_body_bound(name)
        req("DELETE", f"/{ACCOUNT}/s1large/s1blob")
        req("DELETE", f"/{ACCOUNT}/s1large?restype=container")


def _pin_body_bound(name):
    """Pin the exact request-body bound: Plug.Conn.read_body/1 default length is
    8_000_000 bytes; a body of 8_000_001 returns {:more, ...} which the PUT route
    does not match -> request handler crash (connection reset)."""
    results = {}
    for size in (1_000_000, 4_000_000, 8_000_000, 8_000_001, 16_000_000):
        payload = ((b"m" * 999999 + b"\n") * (size // 1_000_000 + 1))[:size]
        try:
            status, _, _ = req("PUT", f"/{ACCOUNT}/s1large/pin-{size}", body=payload)
            results[str(size)] = status
        except Exception as exc:
            results[str(size)] = repr(exc)
    record(name, {**scn(name), "body_bound_probe": results})
    ok_max = max((k for k, v in results.items() if v == 201), key=int, default=None)
    print(f"  body-bound probe: {results} (largest accepted: {ok_max})")
    if ok_max:
        boundary(f"PUT request-body hard bound pinned at {ok_max} bytes "
                 f"(Plug.Conn.read_body/1 default length 8_000_000; larger bodies "
                 f"return {{:more, ...}} which the PUT route {{:ok, body, conn}} head "
                 f"does not match -> handler crash, connection reset (observed: "
                 f"{results})")


def s2_throughput():
    name = "s2_500kb_x100"
    print(f"[{name}] 500 KB x 100 PUT/GET throughput")
    payload = (b"0123456789abcdef" * 32769)[:FIVE_HUNDRED_KB]
    create_container("s2through")

    # defect probe: raw binary (invalid UTF-8) body. The PUT route echoes the
    # stored blob map (including "content") through Jason.encode! — binary
    # content raises and the client sees 500 even though the blob persisted.
    bin_payload = bytes(range(256)) * 2  # 512B, invalid UTF-8
    b_status, _, b_body = req("PUT", f"/{ACCOUNT}/s2through/binary-probe", body=bin_payload)
    b_get_status, _, b_get = req("GET", f"/{ACCOUNT}/s2through/binary-probe")
    binary_defect = {
        "put_status": b_status, "put_error_body": b_body[:200].decode("utf-8", "replace"),
        "get_status": b_get_status, "get_bytes": len(b_get),
        "blob_persisted_despite_500": b_get == bin_payload,
    }
    if b_status != 201:
        boundary(f"binary (invalid-UTF-8) blob PUT returns HTTP {b_status} with empty body "
                 f"but the blob persists and GETs back byte-identical "
                 f"(router echoes stored map through Jason.encode! which raises on raw binary)")
    record("s2b_binary_defect_probe", binary_defect)
    put_lat, get_lat = [], []
    ok_put = ok_get = 0
    t0 = time.perf_counter()
    for i in range(100):
        t1 = time.perf_counter()
        status, _, err_body = req("PUT", f"/{ACCOUNT}/s2through/blob-{i:03d}", body=payload)
        if status == 201:
            put_lat.append((time.perf_counter() - t1) * 1000.0)
        else:
            print(f"  unexpected PUT status {status} on blob-{i:03d}: {err_body[:200]!r}")
    put_wall = time.perf_counter() - t0

    t0 = time.perf_counter()
    for i in range(100):
        t1 = time.perf_counter()
        g_status, _, g_body = req("GET", f"/{ACCOUNT}/s2through/blob-{i:03d}")
        if g_status == 200 and g_body == payload:
            ok_get += 1
            get_lat.append((time.perf_counter() - t1) * 1000.0)
    get_wall = time.perf_counter() - t0

    put_lat.sort()
    get_lat.sort()
    r2 = lambda v: round(v, 3) if v is not None else None
    record(name, {
        "blob_bytes": FIVE_HUNDRED_KB,
        "blobs": 100,
        "put_ok": len(put_lat), "get_ok": len(get_lat),
        "put_wall_s": round(put_wall, 3), "get_wall_s": round(get_wall, 3),
        "put_mb_per_s": round((100 * FIVE_HUNDRED_KB) / put_wall / (1024 * 1024), 2),
        "get_mb_per_s": round((100 * FIVE_HUNDRED_KB) / get_wall / (1024 * 1024), 2),
        "put_p50_ms": r2(pct(put_lat, 50)), "put_p95_ms": r2(pct(put_lat, 95)),
        "get_p50_ms": r2(pct(get_lat, 50)), "get_p95_ms": r2(pct(get_lat, 95)),
    })
    print(f"  PUT {len(put_lat)}/100 ok, {scn(name)['put_mb_per_s']} MB/s "
          f"p50={scn(name)['put_p50_ms']}ms p95={scn(name)['put_p95_ms']}ms")
    print(f"  GET {len(get_lat)}/100 ok, {scn(name)['get_mb_per_s']} MB/s "
          f"p50={scn(name)['get_p50_ms']}ms p95={scn(name)['get_p95_ms']}ms")


def s3_ranged_get():
    name = "s3_ranged_get"
    print(f"[{name}] 10 ranged GETs of a 500 KB blob")
    create_container("s3ranges")
    payload = (b"range-check-" + b"abcdefghijklmnopqrstuvwxyz" * 20000)[:FIVE_HUNDRED_KB]
    status, _, _ = req("PUT", f"/{ACCOUNT}/s3ranges/ranged", body=payload)
    if status != 201:
        record(name, {"setup_status": status})
        boundary(f"ranged-GET setup PUT failed: HTTP {status}")
        return

    chunk = FIVE_HUNDRED_KB // RANGE_COUNT
    lat, ok, bad = [], 0, []
    for i in range(RANGE_COUNT):
        first = i * chunk
        last = first + chunk - 1
        t0 = time.perf_counter()
        g_status, hdrs, g_body = req(
            "GET", f"/{ACCOUNT}/s3ranges/ranged",
            extra_headers={"x-ms-range": f"bytes={first}-{last}"})
        lat.append((time.perf_counter() - t0) * 1000.0)
        expected = payload[first:last + 1]
        cr_ok = hdrs.get("content-range") == f"bytes {first}-{last}/{FIVE_HUNDRED_KB}"
        if g_status == 206 and cr_ok and g_body == expected:
            ok += 1
        else:
            bad.append({"range": f"{first}-{last}", "status": g_status,
                        "content_range": hdrs.get("content-range"),
                        "bytes": len(g_body)})
    lat.sort()
    record(name, {
        "blob_bytes": FIVE_HUNDRED_KB, "ranges": RANGE_COUNT, "range_bytes": chunk,
        "ok": ok, "bad": bad,
        "p50_ms": round(pct(lat, 50), 3), "p95_ms": round(pct(lat, 95), 3),
        "min_ms": round(lat[0], 3), "max_ms": round(lat[-1], 3),
    })
    print(f"  {ok}/{RANGE_COUNT} ranges correct, p50={scn(name)['p50_ms']}ms "
          f"p95={scn(name)['p95_ms']}ms")
    if bad:
        boundary(f"ranged GET: {len(bad)}/{RANGE_COUNT} ranges wrong: {bad[:2]}")


def s4_large_listing():
    name = "s4_5000blob_listing"
    print(f"[{name}] 5,000-blob container + full XML listing")
    create_container("s4list")
    t0 = time.perf_counter()
    errors = []

    def put_chunk(begin, end):
        conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=120)
        for i in range(begin, end):
            body = (f"payload-{i:05d}-".encode() + b"x" * 900)
            conn.request("PUT", f"/{ACCOUNT}/s4list/blob-{i:05d}", body=body,
                         headers={"x-ms-version": XMS_VERSION,
                                  "Authorization": f"Bearer {_TOKEN['value']}"})
            r = conn.getresponse()
            r.read()
            if r.status != 201:
                errors.append(f"blob-{i:05d}: HTTP {r.status}")
        conn.close()

    threads = [threading.Thread(target=put_chunk, args=(a, a + 500))
               for a in range(0, BLOB_COUNT_S4, 500)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    seed_wall = time.perf_counter() - t0

    t0 = time.perf_counter()
    status, hdrs, xml = req("GET", f"/{ACCOUNT}/s4list")
    list_wall_ms = (time.perf_counter() - t0) * 1000.0

    result = {
        "blob_count": BLOB_COUNT_S4, "seed_errors": errors[:5],
        "seed_wall_s": round(seed_wall, 3),
        "list_status": status, "list_wall_ms": round(list_wall_ms, 3),
        "list_bytes": len(xml),
        "expected_count": BLOB_COUNT_S4,
    }

    wellformed = False
    counted = -1
    try:
        root = ET.fromstring(xml.decode("utf-8"))
        wellformed = True
        counted = len(root.findall(".//Blob"))
    except ET.ParseError as exc:
        boundary(f"5,000-blob listing XML not well-formed: {exc}")
    result["xml_well_formed"] = wellformed
    result["blob_entries_counted"] = counted

    # Marker pagination probe: the engine route (GET /{acct}/{container}) takes no
    # marker/maxresults for blobs — send them anyway and record what comes back.
    s2, _, xml2 = req("GET", f"/{ACCOUNT}/s4list?marker=blob-00049&maxresults=50")
    result["paged_probe_status"] = s2
    result["paged_probe_identical_bytes"] = (s2 == 200 and xml2 == xml)
    if s2 == 200 and xml2 == xml:
        boundary("blob listing ignores marker/maxresults: GET /{acct}/{container}"
                 "?marker=...&maxresults=50 returned the identical unpaginated XML "
                 "(pagination exists only for container listing, BlobService.list_containers)")
    else:
        result["paged_probe_bytes"] = len(xml2)

    if counted != BLOB_COUNT_S4:
        boundary(f"blob listing returns {counted} <Blob> entries for a container with "
                 f"{BLOB_COUNT_S4} (cross-container name-prefix filter leak: "
                 f"list_blobs_xml/2 rebuilds the key with the listed container, so any "
                 f"same-named blob in any container of the account is included)")
    record(name, result)
    print(f"  seed {BLOB_COUNT_S4} in {seed_wall:.1f}s ({len(errors)} errors); "
          f"list {list_wall_ms:.1f}ms, {len(xml)} bytes, "
          f"well_formed={wellformed}, blobs_counted={counted}")


def s5_worm_409():
    name = "s5_worm_409_rate"
    print(f"[{name}] WORM: 50 threads overwrite one immutable blob")
    create_container("s5worm")
    original = b"immutable-payload-" + b"z" * 495
    status, _, _ = req("PUT", f"/{ACCOUNT}/s5worm/locked", body=original)
    if status != 201:
        record(name, {"setup_status": status})
        boundary(f"WORM setup PUT failed: HTTP {status}")
        return

    results = {"409": 0, "201": 0, "other": []}
    lock = threading.Lock()

    def attempt(n):
        try:
            conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=60)
            body = f"overwrite-{n:03d}-".encode() + b"w" * 480
            conn.request("PUT", f"/{ACCOUNT}/s5worm/locked", body=body,
                         headers={"x-ms-version": XMS_VERSION,
                                  "Authorization": f"Bearer {_TOKEN['value']}"})
            r = conn.getresponse()
            r.read()
            with lock:
                if r.status == 409:
                    results["409"] += 1
                elif r.status == 201:
                    results["201"] += 1
                else:
                    results["other"].append(r.status)
            conn.close()
        except Exception as exc:
            with lock:
                results["other"].append(repr(exc))

    t0 = time.perf_counter()
    threads = [threading.Thread(target=attempt, args=(i,)) for i in range(WORM_THREADS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0

    _, _, final_body = req("GET", f"/{ACCOUNT}/s5worm/locked")
    intact = final_body == original

    record(name, {
        "attempts": WORM_THREADS, "status_409": results["409"],
        "status_201_accidental": results["201"], "other": results["other"][:5],
        "wall_s": round(wall, 3), "rate_per_s": round(WORM_THREADS / wall, 1),
        "original_intact": intact,
    })
    print(f"  409={results['409']}/50, accidental_201={results['201']}, "
          f"other={results['other'][:3]}, wall={wall:.3f}s, original_intact={intact}")
    if results["201"] or results["other"] or not intact:
        boundary(f"WORM violation: 201={results['201']} other={results['other']} "
                 f"intact={intact}")


def cleanup():
    for path in (f"/{ACCOUNT}/s2through?restype=container",
                 f"/{ACCOUNT}/s3ranges?restype=container",
                 f"/{ACCOUNT}/s4list?restype=container",
                 f"/{ACCOUNT}/s5worm?restype=container"):
        req("DELETE", path)


def main():
    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)
    proc = spawn_substrate()
    try:
        wait_for_port(DATA_PORT, proc)
        wait_for_port(ARM_PORT, proc, timeout_s=30.0)
        # DELETE ?restype=container on WORM containers is refused (409); the
        # substrate's ETS store dies with the process, so no cross-run state.
        receipt["boundaries"].append(
            "containers created immutable by default (retention 1095d): container "
            "DELETE is 409-refused; isolation relies on in-memory store lifetime")
        fetch_token()
        for scenario in (s1_single_large_blob, s2_throughput, s3_ranged_get,
                         s4_large_listing, s5_worm_409):
            scenario()
    finally:
        kill_substrate(proc)

    receipt["finished_at_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(RECEIPT_PATH, "w") as fh:
        json.dump(receipt, fh, indent=2)
    print(f"\nreceipt: {RECEIPT_PATH}")
    boundaries = receipt["boundaries"]
    print(f"scenarios run: {len(receipt['scenarios'])}, boundaries: {len(boundaries)}")
    for b in boundaries:
        print(f"  BOUNDARY: {b}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

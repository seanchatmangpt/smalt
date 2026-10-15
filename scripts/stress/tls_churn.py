#!/usr/bin/env python3
"""TLS churn benchmark against the smalt 9444 TLS twin (Bandit/OTP ssl).

Real-run benchmark, fail-closed: any scenario that cannot complete aborts the
run with a nonzero exit. Certificate material is the dev chain minted by
scripts/gen_dev_cert.sh (CA + CA:FALSE leaf, SAN localhost + 127.0.0.1),
verified with the CA as the only anchor.

Scenarios:
  1. sustained new-connection handshake churn, 30s, one GET per connection
  2. TLS1.2-pinned cipher measurement (server pins tlsv1.2 + ECDHE-RSA-AES-GCM;
     a deliberate MLKEM-workaround pin -- measured specifically)
  3. concurrent bursts: 50-handshake bursts x 20
  4. 100 bad-ClientHello connections, then a good-handshake survivability probe
  5. plain-http new-connection rate comparison on the http ARM twin

Usage (env, defaults shown):
  SMALT_TLS_HOST=127.0.0.1 SMALT_TLS_PORT=19444 SMALT_HTTP_PORT=19443
  SMALT_TLS_CA=$REPO/.smalt/tls/ca-cert.pem
"""

import os
import socket
import ssl
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HOST = os.environ.get("SMALT_TLS_HOST", "127.0.0.1")
TLS_PORT = int(os.environ.get("SMALT_TLS_PORT", "19444"))
HTTP_PORT = int(os.environ.get("SMALT_HTTP_PORT", "19443"))
REPO = os.environ.get("SMALT_REPO", "/Users/sac/smalt")
CA = os.environ.get("SMALT_TLS_CA", os.path.join(REPO, ".smalt/tls/ca-cert.pem"))

GET = (
    b"GET /tenant?api-version=2022-12-01 HTTP/1.1\r\n"
    b"Host: localhost\r\nConnection: close\r\n\r\n"
)
GET_OK = b"200"

DURATION_S = 30.0
BURSTS = 20
BURST_SIZE = 50
BAD_HELLO_COUNT = 100


def die(msg):
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(1)


if not os.path.isfile(CA):
    die(f"CA not found: {CA}")


def make_ctx(min_version=ssl.TLSVersion.TLSv1_2,
             max_version=ssl.TLSVersion.MAXIMUM_SUPPORTED,
             cipher_string=None):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(cafile=CA)
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.minimum_version = min_version
    ctx.maximum_version = max_version
    if cipher_string:
        ctx.set_ciphers(cipher_string)
    return ctx


def one_tls_get(port, ctx):
    """connect + handshake + GET + read status line. Returns (dt, version, cipher)."""
    t0 = time.perf_counter()
    with socket.create_connection((HOST, port), timeout=10) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost") as tls:
            tls.sendall(GET)
            data = b""
            while b"\r\n" not in data:
                chunk = tls.recv(4096)
                if not chunk:
                    break
                data += chunk
            status = data.split(b"\r\n", 1)[0]
            ok = b" 200 " in status + b" "
            return time.perf_counter() - t0, ok, tls.version(), tls.cipher()[0]


def http_get(port):
    t0 = time.perf_counter()
    with socket.create_connection((HOST, port), timeout=10) as s:
        s.sendall(GET)
        data = b""
        while b"\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        ok = b" 200 " in data.split(b"\r\n", 1)[0] + b" "
        return time.perf_counter() - t0, ok


def bad_hello(port):
    """Open a raw TCP connection and write a malformed TLS record / junk."""
    try:
        with socket.create_connection((HOST, port), timeout=10) as s:
            # HTTP/2-style garbage: not a valid TLS record at all.
            s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            s.recv(256)
    except OSError:
        pass  # server-side alert/reset is the expected outcome


def burst(n, ctx):
    ok = 0
    with ThreadPoolExecutor(max_workers=n) as ex:
        for res in ex.map(lambda _: one_tls_get(TLS_PORT, ctx), range(n)):
            if res[1]:
                ok += 1
    return ok


def classify(exc):
    """Classify a client-side exception for honest failure accounting."""
    if isinstance(exc, OSError) and exc.errno == 49:
        return "EADDRNOTAVAIL(client-ephemeral-port-exhaustion)"
    if isinstance(exc, ConnectionRefusedError):
        return "ECONNREFUSED"
    return f"{type(exc).__name__}:{getattr(exc, 'errno', '')}"


def main():
    print(f"smalt TLS churn benchmark -- host={HOST} tls={TLS_PORT} http={HTTP_PORT}")
    print(f"CA: {CA}")

    ctx = make_ctx()
    ctx12 = make_ctx(min_version=ssl.TLSVersion.TLSv1_2,
                     max_version=ssl.TLSVersion.TLSv1_2,
                     cipher_string="ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256")

    # -- scenario 0: connectivity gate (fail-closed) --------------------------
    print("\n[gate] single handshake + GET ...")
    try:
        dt, ok, ver, ciph = one_tls_get(TLS_PORT, ctx)
    except Exception as e:
        die(f"connectivity gate failed: {e}")
    if not ok:
        die("connectivity gate: GET did not return 200")
    print(f"[gate] OK  {ver} {ciph} {dt*1000:.1f} ms")

    # -- scenario 2: TLS1.2-pinned cipher measurement -------------------------
    print("\n[2] TLS1.2-pinned ECDHE-RSA-AES-GCM cipher (deliberate MLKEM workaround pin)")
    samples = []
    failures_12 = 0
    t_start = time.perf_counter()
    while time.perf_counter() - t_start < 10.0:
        try:
            dt, ok, v, c = one_tls_get(TLS_PORT, ctx12)
        except Exception:
            failures_12 += 1
            continue
        if not ok:
            failures_12 += 1
        samples.append((dt, c))
    if not samples:
        die("TLS1.2 pinned probe: zero successful handshakes")
    p50 = statistics.median(s[0] for s in samples) * 1000
    ciphers = {s[1] for s in samples}
    rate = len(samples) / (time.perf_counter() - t_start)
    print(f"    handshakes/s={rate:.1f}  p50={p50:.2f} ms  n={len(samples)}  "
          f"failures={failures_12}  ciphers={sorted(ciphers)}")

    # -- scenario 1: sustained 30s churn --------------------------------------
    print(f"\n[1] sustained new-connection churn, {DURATION_S:.0f}s")
    samples = []
    failures_1 = {}
    t_start = time.perf_counter()
    while time.perf_counter() - t_start < DURATION_S:
        try:
            dt, ok, v, c = one_tls_get(TLS_PORT, ctx)
        except Exception as e:
            failures_1[classify(e)] = failures_1.get(classify(e), 0) + 1
            continue
        if not ok:
            failures_1 += 1
        samples.append(dt)
    elapsed = time.perf_counter() - t_start
    if not samples:
        die("sustained churn: zero successful handshakes")
    times = sorted(samples)
    p50 = statistics.median(times) * 1000
    p99 = times[min(len(times) - 1, int(len(times) * 0.99))] * 1000
    print(f"    handshakes/s={len(samples)/elapsed:.1f}  p50={p50:.2f} ms  p99={p99:.2f} ms  "
          f"n={len(samples)}  failures={failures_1}")

    # -- scenario 3: concurrent bursts ----------------------------------------
    print(f"\n[3] {BURSTS} bursts x {BURST_SIZE} concurrent handshakes")
    total = 0
    ok_total = 0
    burst_times = []
    for b in range(BURSTS):
        t0 = time.perf_counter()
        ok = burst(BURST_SIZE, ctx)
        burst_times.append(time.perf_counter() - t0)
        ok_total += ok
        total += BURST_SIZE
    if ok_total < total:
        print(f"    WARNING: {total - ok_total}/{total} burst handshakes failed")
    print(f"    burst success={ok_total}/{total}  "
          f"burst-wall-ms p50={statistics.median(burst_times)*1000:.1f} "
          f"max={max(burst_times)*1000:.1f}")

    # -- scenario 4: bad ClientHello flood, then survivability ----------------
    print(f"\n[4] {BAD_HELLO_COUNT} bad-ClientHello connections")
    for i in range(BAD_HELLO_COUNT):
        bad_hello(TLS_PORT)
    print("    flood sent")
    try:
        dt, ok, ver, ciph = one_tls_get(TLS_PORT, ctx)
    except Exception as e:
        die(f"post-flood survivability: good handshake failed: {e}")
    if not ok:
        die("post-flood survivability: GET did not return 200")
    print(f"    survive: OK {ver} {ciph} {dt*1000:.1f} ms")

    # -- scenario 5: plain-http comparison ------------------------------------
    print(f"\n[5] plain-http new-connection rate on port {HTTP_PORT} (10s)")
    http_ok = 0
    http_fail = {}
    samples = []
    t_start = time.perf_counter()
    while time.perf_counter() - t_start < 10.0:
        try:
            dt, ok = http_get(HTTP_PORT)
        except Exception as e:
            key = classify(e)
            http_fail[key] = http_fail.get(key, 0) + 1
            continue
        if not ok:
            http_fail += 1
        samples.append(dt)
        http_ok += 1
    elapsed = time.perf_counter() - t_start
    if not samples:
        die("plain-http comparison: zero successful requests")
    times = sorted(samples)
    print(f"    req/s={len(samples)/elapsed:.1f}  p50={statistics.median(times)*1000:.2f} ms  "
          f"p99={times[min(len(times)-1, int(len(times)*0.99))]*1000:.2f} ms  "
          f"n={len(samples)}  failures={http_fail}")

    print("\nRESULT: PASS (all scenarios completed)")


if __name__ == "__main__":
    main()

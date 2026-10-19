#!/usr/bin/env python3
"""Smalt benchmark — fail-closed measurement harness (stdlib-only).

Measures PRD CTQs against a live substrate spawned by this script:

  1. Doctor runtime          (target <= 3s, against a live substrate)
  2. Substrate boot          spawn -> TCP accept on 9443, 5 runs (target <= 5s)
  3. ARM PUT round-trip      200 PUTs, p50/p95/p99 (target p95 < 50ms)
  4. Cosmos doc round-trip   200x POST+GET, p50/p95 (target p95 < 20ms)
  5. AMQP header exchange    50x raw socket, first-frame latency (target < 100ms)

The substrate is killed in a finally/trap on every path. Exit code 0 only
when the full run completed; per-CTQ PASS/FAIL is reported per measurement.
"""
import http.client
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "stress"))
import _substrate  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = "127.0.0.1"
# Fixed-port front door is `just bench` (9443/8443/5672). When the fixed ports
# are held by another lane's substrate, run against a private block from the
# documented range instead (docs/how-to/dev-loop.md "Private port allocation"):
#   SMALT_BENCH_ARM_PORT=39443 SMALT_BENCH_DATA_PORT=39453 \
#   SMALT_BENCH_AMQP_PORT=39456 python3 scripts/bench.py
# Same functions, same receipt schema; only the bind ports move.
ARM_PORT = int(os.environ.get("SMALT_BENCH_ARM_PORT", "9443"))
DATA_PORT = int(os.environ.get("SMALT_BENCH_DATA_PORT", "8443"))
AMQP_PORT = int(os.environ.get("SMALT_BENCH_AMQP_PORT", "5672"))
SUB_ID = "bench-sub"
# 2021-04-01: floor for Microsoft.Resources/resourceGroups (ARM rejects 2021-01-01
# with InvalidApiVersionParameter — found by the 2026-10-15 bench re-run).
API_VERSION = "2021-04-01"

DOCTOR_TARGET_S = 3.0
BOOT_TARGET_S = 5.0
ARM_P95_TARGET_MS = 50.0
COSMOS_P95_TARGET_MS = 20.0
AMQP_READY_TARGET_MS = 100.0

SCHEMA = "smalt-bench/v1"
RECEIPT_PATH = os.path.join(REPO, "tmp", "bench-receipt.json")


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(1)


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


def spawn_substrate():
    """Spawn `mix run --no-halt` in its own process group; caller must killpg.

    Injects the resolved bench ports at config time (put_env, plus the
    SMALT_TEST_*_PORT env vars test config reads) so a private-port run never
    touches the fixed front-door ports. With defaults the injection is the
    same values dev config already binds — a no-op equivalence.
    """
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    env["SMALT_TEST_ARM_PORT"] = str(ARM_PORT)
    env["SMALT_TEST_EGRESS_PORT"] = str(DATA_PORT)
    env["SMALT_TEST_AMQP_PORT"] = str(AMQP_PORT)
    env["SMALT_TEST_EVENT_HUBS_PORT"] = str(AMQP_PORT + 1)
    # Scope EVERY fixed listener, not just the three bench CTQ ports: the
    # Application also binds arm_tls_port (default 9444) and mcp_port
    # (default 9545). Witnessed 2026-10-15 (lens-2 cycle 2/4): a partially
    # scoped dev-env boot answers the ARM readiness probe, then the whole app
    # dies eaddrinuse on 9444/9545 when a sibling substrate holds the front
    # door. Derived offsets are collision-checked below against the already
    # chosen ephemeral picks.
    scoped = {"arm_tls_port": ARM_PORT + 1, "mcp_port": ARM_PORT + 2}
    taken = {ARM_PORT, DATA_PORT, AMQP_PORT, AMQP_PORT + 1}
    while scoped["arm_tls_port"] in taken:
        scoped["arm_tls_port"] += 1
    while scoped["mcp_port"] in taken or scoped["mcp_port"] == scoped["arm_tls_port"]:
        scoped["mcp_port"] += 1
    eval_code = (
        f"Application.put_env(:smalt, :arm_port, {ARM_PORT}); "
        f"Application.put_env(:smalt, :egress_port, {DATA_PORT}); "
        f"Application.put_env(:smalt, :amqp_port, {AMQP_PORT}); "
        f"Application.put_env(:smalt, :event_hubs_port, {AMQP_PORT + 1}); "
        f"Application.put_env(:smalt, :arm_tls_port, {scoped['arm_tls_port']}); "
        f"Application.put_env(:smalt, :mcp_port, {scoped['mcp_port']}); "
        "{:ok, _} = Application.ensure_all_started(:smalt); "
        "Process.sleep(:infinity)"
    )
    # Substrate output goes to a real log file, not DEVNULL: a rc=1 boot with
    # DEVNULL output is unattributable (witnessed: silent bench death mid-run,
    # lens-2 cycle 4). The log path is deterministic so failures are readable.
    log_path = os.path.join(REPO, "tmp", "bench-substrate.log")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    log_f = open(log_path, "w")
    return subprocess.Popen(
        ["mix", "run", "--no-start", "-e", eval_code, "--no-halt"],
        cwd=REPO,
        env=env,
        stdout=log_f,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )


def wait_for_port(port, proc, timeout_s=90.0):
    """Poll TCP connect until the port accepts; return elapsed seconds since spawn."""
    return _substrate.wait_for_port(port, proc=proc, timeout_s=timeout_s,
                                    fail=fail_closed, poll=0.01)


def kill_substrate(proc):
    """SIGKILL the whole process group, then sweep any surviving port holder; never raise."""
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
    # sweep: a BEAM child can outlive the mix wrapper's process group
    for port in (ARM_PORT, DATA_PORT, AMQP_PORT):
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
    try:
        os.remove("/tmp/smalt-bench.pid")
    except OSError:
        pass


def doctor_time():
    """Time `scripts/doctor.py` against the live substrate (ports held by caller)."""
    env = dict(os.environ)
    if ARM_PORT != 9443 or DATA_PORT != 8443 or AMQP_PORT != 5672:
        env["SMALT_BENCH_ARM_PORT"] = str(ARM_PORT)
        env["SMALT_BENCH_DATA_PORT"] = str(DATA_PORT)
        env["SMALT_BENCH_AMQP_PORT"] = str(AMQP_PORT)
    t0 = time.monotonic()
    r = subprocess.run(
        [sys.executable, os.path.join(REPO, "scripts", "doctor.py")],
        cwd=REPO,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    elapsed = time.monotonic() - t0
    if r.returncode != 0:
        return elapsed, False, (r.stderr or r.stdout).strip()[-300:]
    return elapsed, True, ""


def wait_port_free(port, timeout_s=15.0):
    return _substrate.wait_port_free(port, timeout_s=timeout_s)


def bench_boot(n=5):
    boot_times = []
    for i in range(n):
        if not wait_port_free(ARM_PORT, timeout_s=20.0):
            fail_closed(f"port {ARM_PORT} not free before boot run {i + 1}")
        proc = spawn_substrate()
        try:
            # 240s: absorbs sibling compile contention on the shared build
            # dir (witnessed: "Waiting for lock on the build directory" ate
            # the old 90s budget; lens-2 cycle 4).
            t = wait_for_port(ARM_PORT, proc, timeout_s=240.0)
            boot_times.append(t)
            print(f"  boot run {i + 1}/{n}: {t:.3f}s")
        finally:
            kill_substrate(proc)
        if not wait_port_free(ARM_PORT):
            fail_closed(f"port {ARM_PORT} still held after teardown of boot run {i + 1}")
        time.sleep(0.5)
    return boot_times


def mint_token(port=None):
    """Mint a bearer from the ARM STS (exempt route) for enforce-mode parity.

    `port=None` resolves to the CURRENT ARM_PORT at call time — the old
    `port=ARM_PORT` default bound the import-time value (9443), so on the
    auto-scope path the mint went to whatever front-door holder was on 9443
    (witnessed: 401 NoSigningSecretConfigured at ARM PUT #0, deterministic
    on the auto-scope path, lens-2 cycle 4)."""
    """Mint a bearer from the ARM STS (exempt route) for enforce-mode parity.

    Carried finding (docs lane, 2026-10-15): bench.py sent no token and would
    401 on every PUT in dev enforce mode. Minting is harmless in anonymous
    mode (the token is simply unused).
    """
    conn_body = "grant_type=client_credentials&client_id=bench&client_secret=bench"
    if port is None:
        port = ARM_PORT
    # Bounded retry: the STS can 500 (empty body) in the first moments after
    # port bind while the auth subsystem warms (observed 2026-10-15 bench run).
    last = "no attempt"
    for attempt in range(5):
        conn = http.client.HTTPConnection(HOST, port, timeout=10)
        try:
            conn.request("POST", "/oauth2/v2.0/token", body=conn_body, headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Content-Length": str(len(conn_body)),
            })
            resp = conn.getresponse()
            payload = resp.read()
            status = resp.status
        except OSError as e:
            # A just-spawned full-app substrate binds its planes asynchronously:
            # the data/amqp port can accept while the ARM listener is still
            # coming up, so the first mint attempt can hit ConnectionRefused
            # (witnessed 2026-10-19: cosmos leg mint raced the arm listener on
            # the private-port block; the Oct 17 run won the same race). This
            # is the same post-bind warmup class the status-retry already
            # covers — never a verdict, always a retry.
            last = f"STS token mint attempt {attempt + 1}/5 connection failed: {e!r}"
            time.sleep(1.0 * (attempt + 1))
            continue
        finally:
            try:
                conn.close()
            except Exception:
                pass
        if status == 200:
            return json.loads(payload)["access_token"]
        last = f"STS token mint attempt {attempt + 1}/5 returned {status}: {payload[:200]!r}"
        time.sleep(1.0 * (attempt + 1))
    fail_closed(last)


def _arm_put_once(i, token):
    body = json.dumps({"location": "bench"})
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10)
    path = f"/subscriptions/{SUB_ID}/resourceGroups/rg-bench-{i}?api-version={API_VERSION}"
    try:
        t0 = time.perf_counter()
        conn.request("PUT", path, body=body, headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        resp_body = resp.read()
        dt = (time.perf_counter() - t0) * 1000.0
        if resp.status not in (200, 201):
            fail_closed(f"ARM PUT #{i} returned {resp.status} (expected 200/201): "
                        f"{resp_body[:300]!r}")
        return dt
    finally:
        conn.close()


def spawn_and_wait(target, tries=3):
    """Spawn the substrate and wait for `target` ("arm"|"data"|"amqp") to
    bind. On a pre-bind substrate exit — the ephemeral TOCTOU: a sibling lane
    takes the freshly-picked port in the window between pick_free_port() and
    the substrate's bind (witnessed: [FAULT] substrate exited rc=1 before
    binding :50861, lens-2 cycle 4) — kill, re-pick a fresh port, retry.
    Raises SystemExit after the last try (fail-closed, typed)."""
    global ARM_PORT, DATA_PORT, AMQP_PORT
    for attempt in range(tries):
        proc = spawn_substrate()
        port = {"arm": ARM_PORT, "data": DATA_PORT, "amqp": AMQP_PORT}[target]
        try:
            wait_for_port(port, proc)
            return proc
        except SystemExit:
            kill_substrate(proc)
            if attempt == tries - 1:
                raise
            fresh = pick_free_port()
            if target == "arm":
                ARM_PORT = fresh
            elif target == "data":
                DATA_PORT = fresh
            else:
                AMQP_PORT = fresh
            print(f"[BENCH] target port stolen pre-bind; re-picked {target} "
                  f"-> {fresh} (attempt {attempt + 2}/{tries})")


def bench_arm_puts(n=200):
    if not wait_port_free(ARM_PORT, timeout_s=20.0):
        fail_closed(f"port {ARM_PORT} not free before ARM bench")
    proc = spawn_and_wait("arm")
    try:
        wait_for_port(ARM_PORT, proc)
        # Durability gate (court parity, lens-2 cycle 4): a partially-scoped
        # boot can answer one probe then die; re-probe after a settle window
        # before minting, and require the process to still be alive.
        time.sleep(2)
        if proc.poll() is not None:
            fail_closed(f"substrate exited rc={proc.returncode} after bind")
        token = mint_token()
        return [_arm_put_once(i, token) for i in range(n)]
    finally:
        kill_substrate(proc)


def bench_cosmos(n=200):
    if not wait_port_free(DATA_PORT, timeout_s=20.0):
        fail_closed(f"port {DATA_PORT} not free before Cosmos bench")
    proc = spawn_and_wait("data")
    try:
        wait_for_port(DATA_PORT, proc)
        token = mint_token(ARM_PORT)
        times_ms = []
        for i in range(n):
            body = json.dumps({"id": f"bench-{i}", "pk": "bench", "payload": "x" * 128})
            headers = {"Authorization": f"Bearer {token}",
                       "Content-Type": "application/json",
                       "Content-Length": str(len(body))}
            t0 = time.perf_counter()
            conn = http.client.HTTPConnection(HOST, DATA_PORT, timeout=10)
            conn.request("POST", "/dbs/bench/colls/c/docs", body=body, headers=headers)
            r1 = conn.getresponse()
            r1.read()
            t1 = time.perf_counter()
            conn.request("GET", f"/dbs/bench/colls/c/docs/bench-{i}",
                         headers={"Authorization": f"Bearer {token}",
                                  "Content-Length": "0"})
            r2 = conn.getresponse()
            r2.read()
            t2 = time.perf_counter()
            conn.close()
            if r1.status != 201:
                fail_closed(f"Cosmos POST #{i} returned {r1.status} (expected 201)")
            if r2.status != 200:
                fail_closed(f"Cosmos GET #{i} returned {r2.status} (expected 200)")
            times_ms.extend([(t1 - t0) * 1000.0, (t2 - t1) * 1000.0])
        return times_ms
    finally:
        kill_substrate(proc)


def bench_amqp(rounds=50):
    if not wait_port_free(AMQP_PORT, timeout_s=20.0):
        fail_closed(f"port {AMQP_PORT} not free before AMQP bench")
    proc = spawn_and_wait("amqp")
    try:
        wait_for_port(AMQP_PORT, proc)
        lats = []
        for _ in range(rounds):
            t0 = time.perf_counter()
            s = socket.create_connection((HOST, AMQP_PORT), timeout=5)
            s.sendall(b"AMQP\x00\x01\x00\x00")
            peer = s.recv(8)
            dt = (time.perf_counter() - t0) * 1000.0
            s.close()
            if not peer.startswith(b"AMQP"):
                fail_closed(f"AMQP peer header not AMQP: {peer!r}")
            lats.append(dt)
        return lats
    finally:
        kill_substrate(proc)


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


def verdict(d, target, key="p95", cmp="lt"):
    val = d[key] if key in d else d["latency_ms"][key]
    ok = val < target if cmp == "lt" else val <= target
    d["target"] = target
    d["verdict"] = "PASS" if ok else "FAIL"
    return d


def pick_free_port():
    """Bind :0 to get an OS-assigned free port; returns the int."""
    s = socket.socket()
    s.bind((HOST, 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    global ARM_PORT, DATA_PORT, AMQP_PORT
    if shutil.which("mix") is None:
        fail_closed("mix not in PATH")
    # SIGTERM -> SystemExit (lens-5 cycle 5): every bench_* function tears its
    # substrate down in a finally; a bare SIGTERM mid-boot would bypass all of
    # them and orphan the BEAM (the class gates/common guards against,
    # mutation-verified lens-5 cycle 1).
    _substrate.install_sigterm_handler()

    override = any(os.environ.get(v) for v in
                   ("SMALT_BENCH_ARM_PORT", "SMALT_BENCH_DATA_PORT",
                    "SMALT_BENCH_AMQP_PORT"))
    for port in (ARM_PORT, DATA_PORT, AMQP_PORT):
        if not wait_port_free(port, timeout_s=30.0):
            if override:
                holder = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
                                        capture_output=True, text=True).stdout.strip()
                fail_closed(f"port {port} still in use after 30s: {holder}")
            # No override: front door held by another lane -> auto-scope to an
            # ephemeral private block instead of fail-closing (cycle 16). The
            # chosen ports are recorded in the receipt; same functions, same
            # schema.
            ARM_PORT = pick_free_port()
            DATA_PORT = pick_free_port()
            AMQP_PORT = pick_free_port()
            print(f"[BENCH] fixed ports held; auto-scoped to private block "
                  f"{ARM_PORT}/{DATA_PORT}/{AMQP_PORT}")
            break

    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)

    # --- doctor: pre-flight court, defined to run with the substrate DOWN ---
    print("[BENCH] doctor (substrate stopped, as doctor requires)")
    doctor_elapsed, doctor_ok, doctor_err = doctor_time()
    doctor_pass = False
    if doctor_ok:
        doctor_pass = doctor_elapsed <= DOCTOR_TARGET_S
        print(f"  {doctor_elapsed:.3f}s (target <= {DOCTOR_TARGET_S}s) -> "
              f"{'PASS' if doctor_pass else 'FAIL'}")
    else:
        fail_closed(f"doctor failed: {doctor_err}")

    print("[BENCH] substrate boot (spawn -> TCP accept on 9443), 5 runs")
    boots = bench_boot(5)

    print("[BENCH] ARM PUT round-trip, 200 PUTs")
    arm_vals = bench_arm_puts(200)
    arm = verdict(stats_dict(arm_vals), ARM_P95_TARGET_MS, cmp="lt")

    print("[BENCH] Cosmos doc POST+GET round-trips, 200x")
    cosmos_vals = bench_cosmos(200)
    cosmos = verdict(stats_dict(cosmos_vals), COSMOS_P95_TARGET_MS, cmp="lt")

    print("[BENCH] AMQP first-frame latency (connect + 8-byte header), 50 rounds")
    amqp_vals = bench_amqp(50)
    amqp = verdict(stats_dict(amqp_vals), AMQP_READY_TARGET_MS, cmp="lt")

    boot_sorted = sorted(boots)
    boot_stats = {
        "runs": [round(b, 3) for b in boots],
        "n": len(boots),
        "min_s": round(boot_sorted[0], 3),
        "median_s": round(statistics.median(boots), 3),
        "p95_s": round(pct(boot_sorted, 95), 3),
        "target_s": BOOT_TARGET_S,
        "verdict": "PASS" if pct(boot_sorted, 95) <= BOOT_TARGET_S else "FAIL",
    }
    doctor_stats = {
        "elapsed_s": round(doctor_elapsed, 3),
        "target_s": DOCTOR_TARGET_S,
        "verdict": "PASS" if doctor_pass else "FAIL",
    }

    print("\n== Results ==")
    print(f"  doctor        : {doctor_stats['elapsed_s']}s "
          f"(<= {DOCTOR_TARGET_S}s) -> {doctor_stats['verdict']}")
    print(f"  boot median   : {boot_stats['median_s']}s  p95 {boot_stats['p95_s']}s "
          f"(<= {BOOT_TARGET_S}s) -> {boot_stats['verdict']}")
    for name, d in (("arm_put", arm), ("cosmos", cosmos), ("amqp_first_frame", amqp)):
        lat = d["latency_ms"] if "latency_ms" in d else d
        print(f"  {name:14s}: p50 {lat['median']}ms  p95 {lat['p95']}ms  p99 {lat['p99']}ms "
              f"(p95 < {d['target']}ms) -> {d['verdict']}")

    receipt = {
        "schema": SCHEMA,
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": "darwin/arm64 local",
        "ports": {"arm": ARM_PORT, "data": DATA_PORT, "amqp": AMQP_PORT},
        "doctor": doctor_stats,
        "boot": boot_stats,
        "arm_put": arm,
        "cosmos_roundtrip": cosmos,
        "amqp_first_frame": amqp,
    }
    with open(RECEIPT_PATH, "w") as f:
        f.write(json.dumps(receipt, indent=2))
    print(f"[BENCH] receipt written: {RECEIPT_PATH}")

    # Exit contract: the receipt records verdicts, the EXIT CODE must carry
    # them too — `just bench` and CI read the exit code, not the receipt.
    # Witnessed defect (lens-2 cycle 4): a boot-p95 FAIL row printed and the
    # process still exited 0.
    failed = [name for name, d in (("doctor", doctor_stats), ("boot", boot_stats),
                                   ("arm_put", arm), ("cosmos", cosmos),
                                   ("amqp_first_frame", amqp))
              if d.get("verdict") != "PASS"]
    if failed:
        print("[BENCH] GATE: FAIL (%s)" % ", ".join(failed))
        sys.exit(1)
    print("[BENCH] GATE: PASS (5/5 CTQs)")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        sys.exit(1)

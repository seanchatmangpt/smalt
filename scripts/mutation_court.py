#!/usr/bin/env python3
"""Mutation court: prove the 422/400 hard-crash gate in
lib/smalt/graphlaw/validator.ex is NON-VACUOUS.

Phases:
  1. Gate-present: boot substrate (mix run --no-halt, port 9443), run
     mutations M1-M4, expect refusals on M2/M3/M4.
  2. Gate-absent: stop substrate, inject a clearly-marked MUTATION-COURT
     patch into validator.ex making validate_resource/2 always return
     {:ok}, reboot, re-run M2/M3 -- they MUST now be admitted (2xx).
  3. Restore validator.ex byte-exact (sha256 verified), reboot, re-run
     M2 -- refusal must be back.

Exit codes: 0 = gate non-vacuous; 1 = gate vacuous/failed; 2 = BLOCKED
(shared compile broken after 3 retries, 60s apart). Never fakes.

Stdlib only. No git operations. The validator.ex mutation is transient
and restored byte-exact with sha256 verification; disclosed in receipt.
"""

import hashlib
import http.client
import json
import os
import shutil
import socket
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
import urllib.parse

REPO = os.environ.get("SMALT_REPO", os.getcwd())
VALIDATOR = os.path.join(REPO, "lib/smalt/graphlaw/validator.ex")
# SMALT_BENCH_ARM_PORT scoping (DX lane cycle 15): the last-resort port sweep
# in stop() SIGKILLs whatever still holds this port — on the fixed 9443 that
# can be a sibling lane's substrate. Override puts the whole court (bind + sweep)
# on a private port; default stays the fixed front door.
PORT = int(os.environ.get("SMALT_BENCH_ARM_PORT", "9443"))
HOST = "127.0.0.1"
# Ports chosen by auto-scope for every fixed listener (arm_port key holds the
# value mirrored into PORT). Empty on the front-door path.
SCOPED_PORTS = {}


def allocate_block():
    """Ephemeral, collision-checked block for all six fixed listeners."""
    keys = ("arm_port", "arm_tls_port", "egress_port", "mcp_port",
            "amqp_port", "event_hubs_port")
    socks, ports = [], {}
    for k in keys:
        s = socket.socket()
        s.bind((HOST, 0))
        socks.append(s)
        ports[k] = s.getsockname()[1]
    # Release BEFORE spawn: the substrate must bind these itself, so holding
    # them through Popen guarantees eaddrinuse (witnessed cycle 2, second
    # form). Closing re-opens a TOCTOU window; boot's durability gate + the
    # retry loop (fresh block each attempt) absorb it.
    for s in socks:
        s.close()
    return ports
API_VERSION = "2021-04-01"
SUB = "00000000-0000-0000-0000-000000000000"
RG = "mutationcourt-rg"
BOOT_TIMEOUT = 240          # includes first-compile time
RETRY_DELAYS = [5] * 48      # dense retry: shared-checkout port contention
                             # (sibling lanes boot substrates on 9443) and
                             # compile-freeze both resolve by re-trying boot

MUTATION_MARK = "MUTATION-COURT"
ORIGINAL = """    case engine_verdict(type, payload) do
      :no_engine -> validate_local(type, payload)
      other -> other
    end
"""
MUTATED = """    {:ok} # MUTATION-COURT: gate bypass, temporary, restored+verified
"""

results = []  # (mutation, phase, http_status, expected, pass)


# --- substrate lifecycle ------------------------------------------------------

def port_open():
    try:
        conn = http.client.HTTPConnection(HOST, PORT, timeout=2)
        conn.request("GET", "/metadata/endpoints")
        conn.getresponse().read()
        conn.close()
        return True
    except Exception:
        return False


def boot():
    """Boot substrate via mix run --no-halt; wait until PORT answers.
    Fail-closed if PORT is ALREADY occupied and no override/auto-scope is
    possible: the court must probe the substrate it booted (gate-absent phase
    REQUIRES the mutated code to be the code serving PORT); a stale foreign VM
    would silently re-run the gate-present verdicts and make the court read
    vacuous-by-proxy."""
    global PORT, SCOPED_PORTS
    if port_open():
        if os.environ.get("SMALT_BENCH_ARM_PORT"):
            raise RuntimeError(
                "port %s already occupied before boot — refusing to probe a "
                "foreign/stale substrate. Remediation: wait for the holder to "
                "exit, or choose a private port from the documented range "
                "39000-39999 (docs/DEV_LOOP.md 'Private port allocation')")
        # No override: front door held by another lane -> auto-scope to an
        # ephemeral block (cycle 17). A PARTIALLY-scoped boot is worse than
        # none: witnessed 2026-10-15, scoping only arm_port let the ARM
        # listener answer the readiness probe, then the whole app died
        # eaddrinuse on the TLS twin (9444, held by the front-door beam) and
        # the court crashed on the next probe. Auto-scope therefore moves
        # EVERY fixed listener the Application binds.
        SCOPED_PORTS = allocate_block()
        PORT = SCOPED_PORTS["arm_port"]
        print("[court] front door held; auto-scoped to private block %s"
              % SCOPED_PORTS, flush=True)
    log = tempfile.NamedTemporaryFile(
        prefix="mutation_court_boot_", suffix=".log", delete=False)
    if PORT != 9443:
        env_stmts = "; ".join(
            f"Application.put_env(:smalt, :{name}, {p})"
            for name, p in SCOPED_PORTS.items())
        cmd = ["mix", "run", "--no-start", "--no-halt", "-e",
               f"{env_stmts}; "
               "{:ok, _} = Application.ensure_all_started(:smalt); "
               "Process.sleep(:infinity)"]
    else:
        cmd = ["mix", "run", "--no-halt"]
    proc = subprocess.Popen(
        cmd,
        cwd=REPO,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,  # own process group so we can kill -pgid
        env={**os.environ, "MIX_ENV": "dev"},
    )
    deadline = time.time() + BOOT_TIMEOUT
    while time.time() < deadline:
        if port_open():
            # Durability gate: a partially-scoped boot can answer one probe
            # then die eaddrinuse on a listener we did not scope (witnessed
            # cycle 2). Require the ARM port to still answer after a settle
            # window, with the process still alive, before trusting boot.
            time.sleep(2)
            if proc.poll() is None and port_open():
                return proc, log.name
        if proc.poll() is not None:
            raise RuntimeError(
                "substrate exited rc=%s; log=%s" % (proc.returncode, log.name))
        time.sleep(1)
    raise RuntimeError("substrate never bound %s within %ss; log=%s"
                       % (PORT, BOOT_TIMEOUT, log.name))


def stop(proc):
    if proc is None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.wait(timeout=15)
    # The mix wrapper may die before its beam child (or the beam may ignore
    # SIGTERM entirely); verify the PORT is released, escalating to SIGKILL
    # on the process group and, as a last resort, on whatever still holds
    # the port. A surviving VM would serve the NEXT phase with stale code.
    for _ in range(20):
        if not port_open():
            return
        time.sleep(0.5)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    for _ in range(20):
        if not port_open():
            return
        time.sleep(0.5)
    # Last resort: kill whatever still listens on the court port.
    try:
        out = subprocess.run(
            ["lsof", "-ti", "tcp:%s" % PORT],
            capture_output=True, text=True, timeout=10).stdout.split()
        for pid in out:
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ValueError, ProcessLookupError, PermissionError):
                pass
    except subprocess.SubprocessError:
        pass
    for _ in range(20):
        if not port_open():
            return
        time.sleep(0.5)
    raise RuntimeError(
        "port %s still held after stop(); refusing to continue — a stale "
        "VM would poison the next phase. Remediation: lsof -ti tcp:%s | "
        "xargs kill -9" % (PORT, PORT))


def mint_token():
    """Mint a Bearer token from the substrate's own STS (POST
    /oauth2/v2.0/token, client_credentials). Exempt route: no token needed
    to mint. The ARM gateway signs HS256 with the dev secret generated at
    boot and cached in :persistent_term — every reboot rotates the secret,
    so the token must be re-minted after each boot."""
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "mutation-court",
        "client_secret": "mutation-court",
        "scope": "https://management.azure.com/.default",
    }).encode()
    req = urllib.request.Request(
        "http://%s:%s/oauth2/v2.0/token" % (HOST, PORT),
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        payload = json.loads(resp.read().decode())
    token = payload.get("access_token")
    if not token:
        raise RuntimeError("token endpoint returned no access_token: %s" % payload)
    return token


_TOKEN = {"bearer": None}


def probe(url_path, method, body):
    headers = {"Content-Type": "application/json"}
    if _TOKEN["bearer"]:
        headers["Authorization"] = "Bearer %s" % _TOKEN["bearer"]
    req = urllib.request.Request(
        "http://%s:%s%s" % (HOST, PORT, url_path),
        data=body if method in ("PUT", "POST") else None,
        method=method,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()


# --- mutations ----------------------------------------------------------------

def vm_path(name):
    return ("/subscriptions/%s/resourceGroups/%s/providers/"
            "Microsoft.Compute/virtualMachines/%s?api-version=%s"
            % (SUB, RG, name, API_VERSION))


def vnet_path(name):
    return ("/subscriptions/%s/resourceGroups/%s/providers/"
            "Microsoft.Network/virtualNetworks/%s?api-version=%s"
            % (SUB, RG, name, API_VERSION))


def run_mutations(gate_present):
    """Run M1-M4 (gate present) or M2/M3 only (gate absent). Returns
    list of (mutation, phase, status, expected, ok)."""
    phase = "BEFORE" if gate_present else "AFTER"
    out = []
    # Fresh boot -> rotated dev signing secret -> re-mint before probing.
    _TOKEN["bearer"] = mint_token()
    print("  [%s] bearer token minted from /oauth2/v2.0/token" % phase)

    def record(m, status, expected, ok, body=""):
        out.append((m, phase, status, expected, ok))
        print("  [%s] %s -> %s (expected %s) %s"
              % (phase, m, status, expected, "PASS" if ok else "FAIL"))
        if not ok and body:
            snippet = body[:200].replace("\n", " ")
            print("        body: %s" % snippet)
        if not ok:
            with open(VALIDATOR, "r", encoding="utf-8") as fh:
                mutated_on_disk = MUTATION_MARK in fh.read()
            print("        validator.ex contains MUTATION-COURT marker at "
                  "probe time: %s" % mutated_on_disk)

    if gate_present:
        # M1 valid VM PUT -> admission (200/201; VM is LRO type -> 202 is
        # the substrate's admission code for virtualMachines).
        status, _ = probe(vm_path("m1vm"), "PUT", json.dumps({
            "location": "eastus",
            "properties": {"vmSize": "Standard_DC16ads_v5"},
        }).encode())
        record("M1 valid VM PUT",
               status, "200/201/202", status in (200, 201, 202))

    # M2 missing required vmSize. Gate present: -> 400 InvalidResourceShape.
    # Gate absent: the mutation MUST admit (2xx) — that flip IS the
    # non-vacuity proof. (The pinned validator subset enforces sh:minCount
    # only, so the violable input is a missing required property.)
    status, body = probe(vm_path("m2vm"), "PUT", json.dumps({
        "location": "eastus",
        "properties": {},
    }).encode())
    if gate_present:
        ok = status == 400 and "InvalidResourceShape" in body
        record("M2 missing vmSize", status, "400 InvalidResourceShape", ok, body)
    else:
        ok = status in (200, 201, 202)
        record("M2 missing vmSize", status, "200/201/202 (admitted)", ok)

    # M3 missing location on an admitted type (virtualNetworks) -> 400 when
    # the gate is present; admission when it is bypassed.
    status, body = probe(vnet_path("m3vnet"), "PUT", json.dumps({
        "properties": {"addressSpace": {}},
    }).encode())
    if gate_present:
        ok = status == 400 and "InvalidResourceShape" in body
        record("M3 missing location", status, "400 InvalidResourceShape", ok, body)
    else:
        ok = status in (200, 201, 202)
        record("M3 missing location", status, "200/201/202 (admitted)", ok)

    if gate_present:
        # M4 unadmitted type -> 400 refusal (router-side check_admitted;
        # expected refused in BOTH phases, verified BEFORE only).
        status, body = probe(
            "/subscriptions/%s/resourceGroups/%s/providers/"
            "Microsoft.Foo/bars/m4x?api-version=%s" % (SUB, RG, API_VERSION),
            "PUT", json.dumps({"location": "eastus"}).encode())
        ok = status == 400 and "InvalidResourceShape" in body
        record("M4 unadmitted type", status, "400 InvalidResourceShape", ok, body)

    return out


# --- validator mutation / restore ---------------------------------------------

def sha256_of(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def apply_mutation():
    """Inject the MUTATION-COURT bypass into validator.ex.
    Returns backup path. Fails closed if the anchor text is absent."""
    with open(VALIDATOR, "r", encoding="utf-8") as fh:
        original = fh.read()
    if ORIGINAL not in original:
        raise RuntimeError(
            "validator.ex anchor text not found; file changed under us? "
            "Refusing to mutate.")
    fd, backup = tempfile.mkstemp(prefix="validator.orig.",
                                  suffix=".ex", dir="/tmp")
    os.close(fd)
    with open(backup, "w", encoding="utf-8") as fh:
        fh.write(original)
    mutated = original.replace(ORIGINAL, MUTATED, 1)
    with open(VALIDATOR, "w", encoding="utf-8") as fh:
        fh.write(mutated)
    return backup, hashlib.sha256(original.encode()).hexdigest()


def restore(backup, expected_sha):
    """Restore validator.ex from backup; verify byte-exact by sha256.
    Returns True iff restore verified."""
    with open(backup, "rb") as fh:
        data = fh.read()
    with open(VALIDATOR, "wb") as fh:
        bytes_written = fh.write(data)
    actual = sha256_of(VALIDATOR)
    return (actual == expected_sha
            and bytes_written == len(data)
            and os.path.getsize(VALIDATOR) == len(data))


# --- self-check: restore-failure detection on a temp copy ----------------------

def self_check():
    """Simulate a corrupted restore on a TEMP COPY (never the real file):
    corrupt the copy after 'restore', assert detection fires. Exit nonzero
    on any self-check failure."""
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, "validator.ex")
        shutil.copyfile(VALIDATOR, target)
        # mutate the copy as the court would
        with open(target, "r", encoding="utf-8") as fh:
            text = fh.read()
        if ORIGINAL not in text:
            print("[self-check] FAIL: anchor not found in temp copy")
            return False
        fd, backup = tempfile.mkstemp(dir=tmp)
        os.close(fd)
        with open(backup, "w", encoding="utf-8") as fh:
            fh.write(text)
        expected_sha = hashlib.sha256(text.encode()).hexdigest()
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(text.replace(ORIGINAL, MUTATED, 1))

        # good-restore path: reuse restore() logic on the copy via monkey-
        # free parameterization: replicate detection inline (no mocking of
        # real files; this is a real temp-copy exercise).
        def restore_copy(expected_sha, corrupt):
            with open(backup, "rb") as fh:
                data = fh.read()
            if corrupt:
                data = data.replace(b"smalt", b"SMALT", 1)
            with open(target, "wb") as fh:
                fh.write(data)
            return hashlib.sha256(
                open(target, "rb").read()).hexdigest() == expected_sha

        good = restore_copy(expected_sha, corrupt=False)
        bad = restore_copy(expected_sha, corrupt=True)
        detected = not bad  # corrupted restore must NOT verify
        print("[self-check] clean restore verifies: %s; corrupted restore "
              "detected: %s" % (good, detected))
        return good and detected


# --- receipt -------------------------------------------------------------------

def receipt(before, after, restored, mutation_applied=False, blocked_msg=None):
    print()
    print("=" * 78)
    print("MUTATION COURT RECEIPT  (subject: " + REPO + " @ "
          "lib/smalt/graphlaw/validator.ex)")
    print("served port: %s%s" % (PORT, "  (auto-scoped: front door was held)"
                                 if PORT != 9443 else ""))
    print("=" * 78)
    print("%-22s %-7s %-6s %-24s %s" % ("MUTATION", "PHASE", "HTTP", "EXPECTED", "VERDICT"))
    for (m, phase, status, expected, ok) in before + after:
        print("%-22s %-7s %-6s %-24s %s"
              % (m, phase, status, expected, "PASS" if ok else "FAIL"))
    print()
    if mutation_applied:
        print("validator.ex restored byte-exact (sha256): %s" % restored)
    else:
        print("validator.ex never mutated; on-disk file untouched by court.")
    if blocked_msg:
        print("BLOCKED: %s" % blocked_msg)
    print("=" * 78)


def main():
    args = sys.argv[1:]
    if "--self-check" in args:
        sys.exit(0 if self_check() else 1)

    before = after = []
    blocked_msg = None
    restored = False
    proc = None
    try:
        # Phase 1: gate present
        try:
            proc, _log = boot()
        except RuntimeError as exc:
            # compile-freeze retry loop
            for delay in RETRY_DELAYS:
                print("[court] boot failed (%s); retry in %ss" % (exc, delay))
                time.sleep(delay)
                try:
                    proc, _log = boot()
                    break
                except RuntimeError as exc2:
                    exc = exc2
            else:
                receipt([], [], False, mutation_applied=False,
                        blocked_msg="boot failed 4 attempts: %s" % exc)
                sys.exit(2)

        try:
            before = run_mutations(gate_present=True)
        finally:
            stop(proc)

        # Phase 2: mutate
        backup, expected_sha = apply_mutation()
        try:
            try:
                proc, _log = boot()
            except RuntimeError as exc:
                for delay in RETRY_DELAYS:
                    print("[court] boot failed (%s); retry in %ss" % (exc, delay))
                    time.sleep(5)
                    try:
                        proc, _log = boot()
                        break
                    except RuntimeError as exc2:
                        exc = exc2
                else:
                    restored = restore(backup, expected_sha)
                    receipt(before, [], restored,
                            mutation_applied=True,
                            blocked_msg="post-mutation boot failed: %s" % exc)
                    sys.exit(2)
            try:
                after = run_mutations(gate_present=False)
            finally:
                stop(proc)
        finally:
            restored = restore(backup, expected_sha)
            os.unlink(backup)
            print("[court] validator.ex restored, sha256 match: %s" % restored)

        # Phase 3: reboot + confirm refusal returns
        try:
            proc, _log = boot()
        except RuntimeError as exc:
            receipt(before, after, restored, mutation_applied=True,
                    blocked_msg="post-restore boot failed: %s" % exc)
            sys.exit(2)
        try:
            _TOKEN["bearer"] = mint_token()
            status, body = probe(vm_path("m2vm"), "PUT", json.dumps({
                "location": "eastus", "properties": {}}).encode())
            confirm_ok = status == 400 and "InvalidResourceShape" in body
            print("%-22s %-7s %-6s %-24s %s"
                  % ("M2 (post-restore)", "CONFIRM", status,
                     "400 InvalidResourceShape",
                     "PASS" if confirm_ok else "FAIL"))
        finally:
            stop(proc)

        gate_refuses = all(ok for (_, _, _, _, ok) in before)
        gate_absent_admits = (len(after) > 0
                              and all(ok for (_, _, _, _, ok) in after))
        passed = gate_refuses and gate_absent_admits and restored and confirm_ok

        receipt(before, after, restored, mutation_applied=True)
        if passed:
            print("VERDICT: NON-VACUOUS — gate present refuses, gate absent "
                  "admits, restore verified.")
            sys.exit(0)
        else:
            print("VERDICT: FAILED or VACUOUS — see table above.")
            sys.exit(1)
    except KeyboardInterrupt:
        stop(proc)
        raise


if __name__ == "__main__":
    main()

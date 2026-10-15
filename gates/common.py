"""Shared substrate-boot + verdict-receipt machinery for the invariant gates.

Pattern source: scripts/bench.py (spawn -> TCP wait -> killpg + lsof sweep)
and scripts/stress/amqp_throughput.py (MIX_ENV=test private ports via
SMALT_TEST_*_PORT env). Stdlib only.

Fail-closed contract: a gate exits 0 only when
  (a) the positive capture against the LIVE substrate passes its verdict, and
  (b) every negative fixture (mutated observation copy) is REFUSED by the
      same verdict function -- proving the gate is non-vacuous.
"""

import json
import os
import signal
import socket
import subprocess
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = "127.0.0.1"
API_VERSION = "2021-01-01"
RECEIPT_DIR = os.path.join(REPO, "tmp", "invariant-gates")
DRIVER = os.path.join(REPO, "gates", "amqp_invariant_driver.exs")

PORT_KEYS = ("arm", "arm_tls", "egress", "amqp", "event_hubs", "mcp")
ENV_NAMES = {
    "arm": "SMALT_TEST_ARM_PORT",
    "arm_tls": "SMALT_TEST_ARM_TLS_PORT",
    "egress": "SMALT_TEST_EGRESS_PORT",
    "amqp": "SMALT_TEST_AMQP_PORT",
    "event_hubs": "SMALT_TEST_EVENT_HUBS_PORT",
}


def free_port():
    s = socket.socket()
    s.bind((HOST, 0))
    port = s.getsockname()[1]
    s.close()
    return port


def pick_ports():
    return {k: free_port() for k in PORT_KEYS}


def wait_port_free(port, timeout_s=20.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            socket.create_connection((HOST, port), timeout=0.2).close()
            time.sleep(0.05)
        except OSError:
            return True
    return False


def spawn_substrate(ports, shared_key=None):
    """Boot `mix run --no-halt` under MIX_ENV=test on private ports."""
    if not wait_port_free(ports["arm"]):
        raise RuntimeError(f"arm port {ports['arm']} not free before boot")
    env = dict(os.environ)
    env["MIX_ENV"] = "test"
    for key, var in ENV_NAMES.items():
        env[var] = str(ports[key])
    cmd = [
        "mix", "run", "--no-start", "-e",
        # put_env BEFORE app start: :mcp_port has no SMALT_TEST_* env override
        # (config/test.exs covers arm/arm_tls/egress/amqp/event_hubs only), and
        # another lane's substrate may hold the default 9545.
        f'Application.put_env(:smalt, :mcp_port, {ports["mcp"]}); '
        f'Application.put_env(:smalt, :sb_shared_key, "{shared_key or ""}"); '
        '{:ok, _} = Application.ensure_all_started(:smalt); '
        'Process.sleep(:infinity)',
    ]
    log_path = os.environ.get("SMALT_GATE_LOG")
    logf = open(log_path, "w") if log_path else None
    proc = subprocess.Popen(
        cmd,
        cwd=REPO,
        env=env,
        stdout=logf or subprocess.DEVNULL,
        stderr=subprocess.STDOUT if logf else subprocess.DEVNULL,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )
    if logf:
        logf.close()
    wait_for_port(ports["arm"], proc)
    wait_for_port(ports["egress"], proc)
    wait_for_port(ports["amqp"], proc)
    return proc


def wait_for_port(port, proc, timeout_s=120.0):
    t0 = time.monotonic()
    deadline = t0 + timeout_s
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"substrate exited rc={proc.poll()} before binding :{port}")
        try:
            with socket.create_connection((HOST, port), timeout=0.25):
                return time.monotonic() - t0
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"substrate never bound :{port} within {timeout_s}s")


def kill_substrate(proc, ports):
    """SIGKILL the process group, then sweep any surviving port holder."""
    if proc is not None:
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
    for port in ports.values():
        kill_port_holder(port)


def kill_port_holder(port):
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


def http(port, method, path, body=None, headers=None, timeout=15):
    """Return (status, header-dict, parsed-json-or-raw-text)."""
    import http.client
    conn = http.client.HTTPConnection(HOST, port, timeout=timeout)
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = body if isinstance(body, (bytes, str)) else json.dumps(body)
        if isinstance(data, str):
            data = data.encode()
        hdrs.setdefault("Content-Type", "application/json")
        hdrs["Content-Length"] = str(len(data))
    try:
        conn.request(method, path, body=data, headers=hdrs)
        resp = conn.getresponse()
        raw = resp.read()
        status = resp.status
        resp_headers = {k.lower(): v for k, v in resp.getheaders()}
    finally:
        conn.close()
    try:
        parsed = json.loads(raw) if raw else None
    except ValueError:
        parsed = raw.decode("utf-8", "replace")
    return status, resp_headers, parsed


class GateFailure(RuntimeError):
    pass


def run_gate(name, capture, verdict, mutate_fixtures):
    """Fail-closed gate driver shared by every checker.

    capture() -> observations dict from the LIVE substrate.
    verdict(obs) -> (ok: bool, details: list[str]).
    mutate_fixtures(obs) -> list[(fixture_name, mutated_obs)] — each MUST be
    refused by verdict() or the gate is vacuous and fails.
    """
    ports = pick_ports()
    proc = None
    t0 = time.monotonic()
    positive, details, fixtures = "ERROR", [], []
    import base64
    shared_key = base64.b64encode(os.urandom(48)).decode()
    try:
        proc = spawn_substrate(ports, shared_key)
        obs = capture(ports, shared_key)
        obs["ports"] = ports
        ok, details = verdict(obs)
        positive = "PASS" if ok else "FAIL"
        print(f"{'PASS' if ok else 'FAIL'} {name}/positive: {details}")

        fixtures = []
        for fname, fobs in mutate_fixtures(obs):
            fok, fdetails = verdict(fobs)
            detected = not fok
            print(f"{'PASS' if detected else 'FAIL'} {name}/fixture:{fname} "
                  f"({'refused' if detected else 'ACCEPTED — VACUOUS GATE'}: {fdetails})")
            fixtures.append({"fixture": fname, "detected": detected,
                             "verdict_details": fdetails})

        verdict_ok = ok and all(f["detected"] for f in fixtures)
    except Exception as exc:
        verdict_ok = False
        positive = "ERROR"
        details = [f"{type(exc).__name__}: {exc}"]
        print(f"ERROR {name}: {details[0]}")
    finally:
        kill_substrate(proc, ports)

    receipt = {
        "schema": "smalt-invariant-gate/v1",
        "name": name,
        "date": time.strftime("%Y-%m-%d"),
        "elapsed_s": round(time.monotonic() - t0, 3),
        "subject": {"repo": REPO, "mix_env": "test", "private_ports": ports},
        "positive": positive,
        "positive_details": details if positive != "PASS" else [],
        "fixtures": fixtures,
        "verdict": "PASS" if verdict_ok else "FAIL",
    }
    os.makedirs(RECEIPT_DIR, exist_ok=True)
    path = os.path.join(RECEIPT_DIR, f"{name}-receipt.json")
    with open(path, "w") as f:
        json.dump(receipt, f, indent=2)
    print(f"{name}: receipt {path} verdict={receipt['verdict']}")
    return 0 if verdict_ok else 1


def run_amqp_driver(mode, extra_env, timeout_s=300):
    """Run gates/amqp_invariant_driver.exs; parse its final GATE_JSON line."""
    env = dict(os.environ)
    env["MIX_ENV"] = "test"
    env["SMALT_GATE_MODE"] = mode
    if "SMALT_SB_SHARED_KEY" not in env:
        env["SMALT_SB_SHARED_KEY"] = extra_env.pop(
            "SMALT_SB_SHARED_KEY",
            "Z0FhdGVzLXNoYXJlZC1rZXktbXVzdC1iZS1hdC1sZWFzdC0zMi1ieXRlcy1sb25nIQ==")
    env.update({k: str(v) for k, v in extra_env.items()})
    r = subprocess.run(["mix", "run", "--no-start", DRIVER], cwd=REPO, env=env,
                       capture_output=True, text=True, timeout=timeout_s)
    line = None
    for raw in (r.stdout or "").splitlines():
        if raw.startswith("GATE_JSON "):
            line = raw[len("GATE_JSON "):].strip()
    if line is None:
        raise RuntimeError(
            f"driver mode={mode} produced no GATE_JSON (rc={r.returncode})\n"
            f"stdout tail: {(r.stdout or '')[-800:]}\nstderr tail: {(r.stderr or '')[-800:]}")
    return json.loads(line)

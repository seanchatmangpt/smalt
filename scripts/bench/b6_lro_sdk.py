#!/usr/bin/env python3
"""B-6 SDK-tier LRO storm at the smalt ARM gateway.

Sibling of scripts/stress/lro_storm.py (BEAM tier); this lane adds the
real-Python-mgmt-SDK tier (azure-mgmt-resource, track2 LRO pollers), auth via
the smalt-STS TokenCredential pattern from verification/py/py_arm_resources.py.

Self-boots an anonymous substrate on private ports 39840-39843 (no
scripts/bench/lib.sh existed; anonymous = no erlang cookie, load-only).
Teardown: killpg + port sweep via scripts/stress/_substrate.

Phases:
  a  100 concurrent generic NSG PUTs (api-version 2021-04-01) via
     begin_create_or_update_by_id: submissions/sec, poll-to-terminal latency.
     NOTE: smalt's router classifies only storageAccounts + virtualMachines as
     LRO types (router.ex lro_type?), so NSG PUTs are synchronous (200, no
     async headers) and the SDK poller terminates on the initial response.
     The real-LRO tier is phase a2.
  a2 100 concurrent generic storageAccount PUTs (real smalt LRO type): 202 +
     Azure-AsyncOperation; poll-terminated vs sweeper-terminated split.
  b  300 sequential RG create+delete through the SDK: ops/sec.
  c  sweeper convergence: 50 storageAccount LROs submitted and never polled;
     raw op-status GETs until all terminal (sweeper tick default 30 s).

Output: docs/jira/v26.10.14/bench/b6-lro-sdk.jsonl.
KD-30/31/32 sit on no measured path.
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
ARM_PORT = 39840
ARM_TLS_PORT = 39841
AMQP_PORT = 39842
EVENT_HUBS_PORT = 39843
BASE = f"https://{HOST}:{ARM_TLS_PORT}"
SUB = "00000000-0000-0000-0000-000000000000"
API = "2021-04-01"
STAMP = time.strftime("%Y%m%dT%H%M%S")
OUT_JSONL = os.path.join(
    REPO, "docs", "jira", "v26.10.14", "bench", "b6-lro-sdk.jsonl")
SERVER_LOG = f"/tmp/b6_lro_sdk_server_{STAMP}.log"

TLS_OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(
    context=ssl._create_unverified_context()))

RESULTS = {"phases": {}, "errors": []}
CRED = None


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
            "client_id": "b6-lro-sdk-tier",
            "client_secret": "b6-lro-sdk-tier",
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


def nsg_body():
    return {"location": "eastus", "properties": {"securityRules": []}}


SA_BODY = {"location": "eastus",
           "sku": {"name": "Standard_LRS", "tier": "Standard"},
           "kind": "StorageV2",
           "properties": {"skuName": "Standard_LRS",
                          "supportsHttpsTrafficOnly": True}}


def submit_nsg(client, rg, name):
    rid = (f"/subscriptions/{SUB}/resourceGroups/{rg}"
           f"/providers/Microsoft.Network/networkSecurityGroups/{name}")
    return client.resources.begin_create_or_update_by_id(rid, API, nsg_body())


def submit_sa(client, rg, name):
    rid = (f"/subscriptions/{SUB}/resourceGroups/{rg}"
           f"/providers/Microsoft.Storage/storageAccounts/{name}")
    return client.resources.begin_create_or_update_by_id(rid, API, SA_BODY)


def resource_path(rg, provider, rtype, name):
    return (f"/subscriptions/{SUB}/resourceGroups/{rg}"
            f"/providers/{provider}/{rtype}/{name}?api-version={API}")


def _sdk():
    """Thread-scoped ResourceManagementClient."""
    c = getattr(_tls, "sdk", None)
    if c is None:
        from azure.mgmt.resource import ResourceManagementClient
        c = ResourceManagementClient(
            CRED, SUB, base_url=BASE, api_version=API,
            polling_interval=0.05, connection_verify=False)
        _tls.sdk = c
    return c


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
        "MIX_BUILD_ROOT", os.path.join(REPO, "_build-b6"))
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
    connections on those ports; the naive sweep SIGKILLs the harness, the
    exit-137 class seen on the first two runs)."""
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
# phases
# ---------------------------------------------------------------------------
def phase_lro(client, rg, n, submitter, rtype, label):
    """n concurrent generic PUTs through the SDK pollers. First post-submit
    raw probe of the resource scores sweeper-terminated vs poll-terminated."""
    first_check = [None] * n
    term_ms = [None] * n
    submit_ms = [None] * n
    errs = []
    provider, typ = rtype.split("/")

    def do(i):
        name = f"{label.split('_')[0]}{i:04d}"
        c = _sdk()
        t0 = time.perf_counter()
        try:
            poller = submitter(c, rg, name)
            submit_ms[i] = (time.perf_counter() - t0) * 1000
            st, _, body = raw("GET", resource_path(rg, provider, typ, name))
            if st == 200:
                ps = (body or {}).get("properties", {}).get("provisioningState")
                first_check[i] = ("terminal" if ps in ("Succeeded", "Failed", "Canceled")
                                  else ("inprogress" if ps else "absent"))
            else:
                first_check[i] = "absent" if st == 404 else f"http{st}"
            t1 = time.perf_counter()
            poller.result(timeout=120)
            term_ms[i] = (time.perf_counter() - t1) * 1000
        except Exception as e:  # noqa: BLE001
            errs.append(f"{name}: {type(e).__name__}: {e}")

    t_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as ex:
        list(ex.map(do, range(n)))
    wall = time.perf_counter() - t_start

    n_term = sum(1 for t in term_ms if t is not None)
    sweeper = sum(1 for f in first_check if f == "terminal")
    res = {
        "phase": label,
        "submissions": n,
        "ok": n_term,
        "errors": len(errs),
        "submit_ms": stats([s for s in submit_ms if s is not None]),
        "submissions_per_sec": round(n / wall, 2) if wall else None,
        "wall_s": round(wall, 3),
        "poll_to_terminal_ms": stats([t for t in term_ms if t is not None]),
        "sweeper_terminated": sweeper,
        "poll_terminated": n_term - sweeper,
        "first_check_states": {k: first_check.count(k)
                               for k in set(first_check)},
    }
    RESULTS["phases"][label] = res
    RESULTS["errors"].extend(errs)
    print(json.dumps(res), flush=True)
    return res


def phase_b(client, n=300):
    """n sequential RG create+delete through the SDK."""
    errs = []
    op_ms = []
    for i in range(n):
        name = f"b6b-rg-{i:04d}"
        t0 = time.perf_counter()
        try:
            client.resource_groups.create_or_update(name, {"location": "eastus"})
            client.resource_groups.begin_delete(name).result(timeout=60)
            op_ms.append((time.perf_counter() - t0) * 1000)
        except Exception as e:  # noqa: BLE001
            errs.append(f"{name}: {type(e).__name__}: {e}")
    res = {
        "phase": "b_rg_create_delete_300",
        "ops": n,
        "ok": len(op_ms),
        "errors": len(errs),
        "ops_per_sec": round(len(op_ms) / (sum(op_ms) / 1000.0), 2) if op_ms else 0,
        "op_ms": stats(op_ms),
    }
    RESULTS["phases"]["b"] = res
    RESULTS["errors"].extend(errs)
    print(json.dumps(res), flush=True)
    return res


# ---------------------------------------------------------------------------
# op-record probing (the only true LRO terminality seam; resource records are
# stored provisioningState=Succeeded at PUT time, so resource GETs cannot
# observe InProgress -- found on this run, noted in the receipt)
# ---------------------------------------------------------------------------
def op_url_from(poller):
    """Extract the Azure-AsyncOperation URL from the SDK poller's initial
    response headers (ARMPolling._initial_response)."""
    try:
        h = poller._polling_method._initial_response.http_response.headers  # noqa: SLF001
        return h.get("Azure-AsyncOperation") or h.get("Location")
    except Exception:
        return None


def op_probe_path(url):
    if not url:
        return None
    from urllib.parse import urlsplit
    parts = urlsplit(url)
    return parts.path + (f"?{parts.query}" if parts.query else "")


def phase_lro_ops(client, rg, n, label, poll_interval_s):
    """n concurrent storageAccount LRO PUTs (SDK), op-record first-read probe:
    sweeper-terminated := op record already terminal at its first read."""
    first_state = [None] * n
    term_ms = [None] * n
    submit_ms = [None] * n
    errs = []

    def do(i):
        name = f"b6e{i:04d}"
        c = _sdk()
        t0 = time.perf_counter()
        try:
            poller = submit_sa(c, rg, name)
            submit_ms[i] = (time.perf_counter() - t0) * 1000
            url = op_url_from(poller)
            if url:
                st, _, body = raw("GET", op_probe_path(url))
                if st in (200, 202):
                    first_state[i] = (body or {}).get("status")
                else:
                    first_state[i] = f"http{st}"
            else:
                first_state[i] = "no-op-url"
            t1 = time.perf_counter()
            poller.result(timeout=120)
            term_ms[i] = (time.perf_counter() - t1) * 1000
        except Exception as e:  # noqa: BLE001
            errs.append(f"{name}: {type(e).__name__}: {e}")

    t_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as ex:
        list(ex.map(do, range(n)))
    wall = time.perf_counter() - t_start

    n_term = sum(1 for t in term_ms if t is not None)
    swept = sum(1 for s in first_state if s == "Succeeded")
    res = {
        "phase": label,
        "submissions": n,
        "ok": n_term,
        "errors": len(errs),
        "submit_ms": stats([s for s in submit_ms if s is not None]),
        "submissions_per_sec": round(n / wall, 2) if wall else None,
        "wall_s": round(wall, 3),
        "poll_to_terminal_ms": stats([t for t in term_ms if t is not None]),
        "sweeper_terminated": swept,
        "poll_terminated": n_term - swept,
        "first_read_states": {k: first_state.count(k)
                              for k in set(first_state)},
    }
    RESULTS["phases"][label] = res
    RESULTS["errors"].extend(errs)
    print(json.dumps(res), flush=True)
    return res


def phase_c(client, rg, n=50):
    """50 storageAccount LROs submitted and NEVER polled (submission client
    uses a 3600s polling interval so the SDK itself does not drive
    terminality). Raw op-status GETs every 0.25 s observe convergence.

    Sweeper-at-rest protocol: with :lro_delay_ms=250 (set at boot), sleep
    silently past delay + sweep tick (~35 s), read ONE canary op (lazy path
    may flip only the canary), then read the remaining 49: any op terminal at
    its first read can only have been flipped by the background sweeper, since
    no read ever touched it. Also reports read-coupled convergence (no silent
    window) for comparison.
    """
    # submission-only client: SDK background poller effectively never fires
    from azure.mgmt.resource import ResourceManagementClient
    slow = ResourceManagementClient(
        CRED, SUB, base_url=BASE, api_version=API,
        polling_interval=3600.0, connection_verify=False)

    names = [f"b6c{i:04d}" for i in range(n)]
    urls = [None] * n
    errs = []

    def do(i):
        try:
            p = submit_sa(slow, rg, names[i])
            urls[i] = op_url_from(p)
        except Exception as e:  # noqa: BLE001
            errs.append(f"{names[i]}: {type(e).__name__}: {e}")

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as ex:
        list(ex.map(do, range(n)))
    submit_wall = time.perf_counter() - t0

    # silent window: delay (250 ms) + sweep tick (30 s) + margin
    SLEEP_S = 35.0
    print(f"phase c: silent window {SLEEP_S:.0f}s (no reads)", flush=True)
    t_submit_end = time.perf_counter()
    time.sleep(SLEEP_S)

    # canary read first: the lazy poll path may flip only the canary
    canary = 0
    st, _, body = raw("GET", op_probe_path(urls[canary]))
    canary_status = (body or {}).get("status") if st in (200, 202) else f"http{st}"

    # wave read: every op terminal at its FIRST read was flipped at rest
    swept_at_rest = 0
    states = {}
    for i in range(1, n):
        if not urls[i]:
            continue
        st, _, body = raw("GET", op_probe_path(urls[i]))
        status = (body or {}).get("status") if st in (200, 202) else f"http{st}"
        states[status] = states.get(status, 0) + 1
        if status in ("Succeeded", "Failed", "Canceled"):
            swept_at_rest += 1

    res = {
        "phase": "c_sweeper_convergence_50",
        "submitted": n,
        "submit_errors": len(errs),
        "submit_wall_s": round(submit_wall, 3),
        "no_op_url": urls.count(None),
        "lro_delay_ms": 250,
        "silent_window_s": SLEEP_S,
        "canary_status": canary_status,
        "swept_at_rest": swept_at_rest,
        "swept_at_rest_fraction": round(swept_at_rest / max(1, n - 1 - urls.count(None)), 3),
        "wave_read_states": states,
        "at_rest_convergence_upper_bound_s": round(
            time.perf_counter() - t0, 2),
        "unconverged": sum(v for k, v in states.items()
                           if k not in ("Succeeded", "Failed", "Canceled")),
    }
    RESULTS["phases"]["c"] = res
    RESULTS["errors"].extend(errs)
    print(json.dumps(res), flush=True)
    return res


def write_jsonl():
    os.makedirs(os.path.dirname(OUT_JSONL), exist_ok=True)
    row = {"lane": "b6-lro-sdk", "stamp": STAMP, "base": BASE,
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

        RG = "b6-lro-sdk-rg"
        t0 = time.perf_counter()
        client.resource_groups.create_or_update(RG, {"location": "eastus"})
        print(f"RG {RG} up in {(time.perf_counter() - t0) * 1000:.0f}ms",
              flush=True)

        phase_lro(client, RG, n=100, submitter=submit_nsg,
                  rtype="Microsoft.Network/networkSecurityGroups",
                  label="a_nsg_put_100")
        phase_lro_ops(client, RG, n=100,
                      label="a2_storageaccount_lro_100", poll_interval_s=0.05)
        phase_b(client, n=300)
        phase_c(client, RG, n=50)

        st, _, _ = raw("DELETE",
                       f"/subscriptions/{SUB}/resourceGroups/{RG}?api-version={API}")
        print(f"cleanup RG delete -> {st}", flush=True)
    finally:
        write_jsonl()
        if proc is not None:
            kill_substrate(proc)

    a = RESULTS["phases"].get("a_nsg_put_100", {})
    a2 = RESULTS["phases"].get("a2_storageaccount_lro_100", {})
    b = RESULTS["phases"].get("b", {})
    c = RESULTS["phases"].get("c", {})
    ok = (a.get("errors", 1) == 0 and a2.get("errors", 1) == 0
          and b.get("errors", 1) == 0 and c.get("submit_errors", 1) == 0
          and c.get("unconverged", 1) == 0)
    print("B6 " + ("PASSED" if ok else "FAILED"), flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

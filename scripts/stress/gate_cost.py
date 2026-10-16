#!/usr/bin/env python3
"""GraphLaw gate cost harness (stdlib-only, fail-closed).

Measures the cost of the GraphLaw admission gate end to end:

  Phase A (in-process, via scripts/stress/gate_cost_inner.exs):
    1. Per-type validate_resource latency: 38 admitted types x 500 valid +
       500 malformed payloads -> p50/p95 microseconds per type
       (DefaultShape vs multi-prop shapes), pure calls, no HTTP.
    2. Registry lookups: 100k calls each of shape_for / latest_version /
       admitted? -> ns/op.

  Phase B (wire): boots the substrate once, then N PUTs against one resource
  of a multi-prop shape (Microsoft.Network/virtualNetworks, VNetShape):
    * valid payload   -> 201/200 (gate passes, store write, response)
    * invalid payload -> 400 GraphLaw refusal (gate fails, no store write)
  Reports p50/p95 for both classes and the p50 delta (invalid - valid).

Budget (PRD): gate adds < 1ms p95 per request. Asserted as:
  * every per-type pure validate p95 < 1000 us, AND
  * wire valid-path p95 minus pure same-shape p95 < 1000 us
    (total request overhead attributable to gate + router stays under 1ms).

Receipt: tmp/gate-cost-receipt.json (schema smalt-gate-cost/v1).
Exit 0 only when all budgets hold.
"""
import json
import os
import signal
import socket
import statistics
import subprocess
import sys
import time

import _substrate

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOST = "127.0.0.1"
ARM_PORT = int(os.environ.get("SMALT_GATECOST_ARM_PORT", "39460"))
ARM_TLS_PORT = int(os.environ.get("SMALT_GATECOST_TLS_PORT", "39462"))
EGRESS_PORT = int(os.environ.get("SMALT_GATECOST_EGRESS_PORT", "39461"))
MCP_PORT = int(os.environ.get("SMALT_GATECOST_MCP_PORT", "39463"))
AMQP_PORT = int(os.environ.get("SMALT_GATECOST_AMQP_PORT", "39464"))
EVENTHUBS_PORT = int(os.environ.get("SMALT_GATECOST_EVENTHUBS_PORT", "39465"))
SUB_ID = "gatecost-sub"
RG = "rg-gatecost"
API_VERSION = "2021-04-01"

# multi-prop shape (location + addressPrefixes), non-LRO, dedicated registry entry
WIRE_TYPE_PATH = "Microsoft.Network/virtualNetworks"
WIRE_FULL_TYPE = "Microsoft.Network/virtualNetworks"

VALID_BODY = json.dumps({"location": "eastus", "properties": {"addressPrefixes": ["10.0.0.0/8"]}})
INVALID_BODY = json.dumps({"location": "eastus2"})  # missing required addressPrefixes (minCount)

N_WIRE = 500
WARMUP = 50
GATE_BUDGET_MS = 1.0

SCHEMA = "smalt-gate-cost/v1"
RECEIPT_PATH = os.path.join(REPO, "tmp", "gate-cost-receipt.json")
INPROC_PATH = os.path.join(REPO, "tmp", "gate-cost-inproc.json")
INNER = os.path.join(REPO, "scripts", "stress", "gate_cost_inner.exs")


def fail_closed(msg, code=1):
    print(f"[FAULT] {msg}", file=sys.stderr)
    sys.exit(code)


def pct(sorted_vals, p):
    k = int(round((p / 100.0) * (len(sorted_vals) - 1)))
    return sorted_vals[k]


def run_inproc():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    out_path = INPROC_PATH + ".out"
    with open(out_path, "w") as f:
        rc = subprocess.call(
            ["mix", "run", "--no-start", INNER],
            cwd=REPO,
            env=env,
            stdout=f,
            stderr=subprocess.DEVNULL,
        )
    if rc != 0:
        fail_closed(f"in-process benchmark exited rc={rc}")
    try:
        raw = open(out_path).read()
        i = raw.rfind('{"elixir"')
        if i < 0:
            fail_closed("in-process output contains no JSON")
        d = json.loads(raw[i:raw.rfind("}") + 1])
    except (OSError, ValueError) as e:
        fail_closed(f"cannot parse in-process output: {e}")
    finally:
        try:
            os.remove(out_path
                      )
        except OSError:
            pass
    if len(d.get("per_type", [])) != 38:
        fail_closed(f"expected 38 per-type rows, got {len(d.get('per_type', []))}")
    return d


def spawn_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    # Bind non-default ports so concurrent lanes on the shared checkout
    # (or a stale substrate) holding 9443/5672 cannot fail our boot.
    cmd = [
        "mix", "run", "--no-start", "--no-halt", "--eval",
        "Application.put_env(:smalt, :arm_port, %d); "
        "Application.put_env(:smalt, :arm_tls_port, %d); "
        "Application.put_env(:smalt, :mcp_port, %d); "
        "Application.put_env(:smalt, :egress_port, %d); "
        "Application.put_env(:smalt, :amqp_port, %d); "
        "Application.put_env(:smalt, :event_hubs_port, %d); "
        "Application.ensure_all_started(:smalt)" % (
            ARM_PORT, ARM_TLS_PORT, MCP_PORT, EGRESS_PORT, AMQP_PORT, EVENTHUBS_PORT,
        ),
    ]
    proc = subprocess.Popen(
        cmd,
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )
    return proc


def wait_for_port(port, proc, timeout_s=120.0):
    return _substrate.wait_for_port(port, proc=proc, timeout_s=timeout_s,
                                    fail=fail_closed, poll=0.25)


def mint_token():
    import http.client
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10)
    body = "grant_type=client_credentials&client_id=gatecost&client_secret=gatecost"
    conn.request("POST", "/oauth2/v2.0/token", body=body, headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Content-Length": str(len(body)),
    })
    resp = conn.getresponse()
    payload = resp.read()
    conn.close()
    if resp.status != 200 or b"access_token" not in payload:
        fail_closed(f"STS token fetch returned {resp.status}: {payload[:200]!r}")
    return json.loads(payload)["access_token"]


def wire_class(n, body, expect_statuses, token):
    """Run n sequential PUTs on one connection; return list of latencies (ms) and statuses."""
    import http.client

    lats = []
    statuses = []
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10)
    try:
        i = 0
        while i < n:
            path = (
                f"/subscriptions/{SUB_ID}/resourceGroups/{RG}/providers/"
                f"{WIRE_TYPE_PATH}/gatecost-vnet?api-version={API_VERSION}"
            )
            t0 = time.perf_counter()
            try:
                conn.request(
                    "PUT",
                    path,
                    body=body,
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/json",
                        "Content-Length": str(len(body)),
                    },
                )
                resp = conn.getresponse()
                payload = resp.read()
            except (http.client.HTTPException, OSError):
                # dropped keep-alive connection: reconnect and retry once;
                # the aborted attempt is not recorded as a sample
                conn.close()
                conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10)
                continue
            dt_ms = (time.perf_counter() - t0) * 1000.0
            i += 1
            if resp.status not in expect_statuses:
                fail_closed(
                    f"unexpected status {resp.status} (expected {expect_statuses}) on PUT #{i}: "
                    f"{payload[:200]!r}"
                )
            statuses.append(resp.status)
            lats.append(dt_ms)
    finally:
        conn.close()
    return lats, statuses


def main():
    print("== GraphLaw gate cost ==")
    inproc = run_inproc()

    max_p95 = max(r["valid_p95_us"] for r in inproc["per_type"])
    max_invalid_p95 = max(r["invalid_p95_us"] for r in inproc["per_type"])
    print(f"in-process: 38 types, max valid p95 = {max_p95:.3f} us, "
          f"max invalid p95 = {max_invalid_p95:.3f} us")
    reg = inproc["registry"]
    print(f"registry 100k: shape_for {reg['shape_for_ns_per_op']} ns/op, "
          f"latest_version {reg['latest_version_ns_per_op']} ns/op, "
          f"admitted? {reg['admitted_ns_per_op']} ns/op")

    proc = spawn_substrate()
    try:
        boot_s = wait_for_port(ARM_PORT, proc)
        print(f"substrate up in {boot_s:.1f}s")

        token = mint_token()

        # warmup both classes so ETS/plug-parsing effects settle
        wire_class(WARMUP, VALID_BODY, {200, 201}, token)
        wire_class(WARMUP, INVALID_BODY, {400}, token)

        valid_lats, valid_st = wire_class(N_WIRE, VALID_BODY, {200, 201}, token)
        invalid_lats, invalid_st = wire_class(N_WIRE, INVALID_BODY, {400}, token)
    finally:
        # SIGTERM the group, bounded wait, SIGKILL escalation; never
        # wrapper-only terminate (lens-5 cycle 2 orphaned-beam class).
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

    v_sorted = sorted(valid_lats)
    i_sorted = sorted(invalid_lats)
    v50, v95 = pct(v_sorted, 50), pct(v_sorted, 95)
    i50, i95 = pct(i_sorted, 50), pct(i_sorted, 95)
    delta50 = i50 - v50

    print(f"wire valid   PUT (201/200): n={len(valid_lats)} p50={v50:.3f}ms p95={v95:.3f}ms")
    print(f"wire invalid PUT (400 ref): n={len(invalid_lats)} p50={i50:.3f}ms p95={i95:.3f}ms")
    print(f"wire p50 delta (invalid - valid): {delta50:+.3f}ms")

    # -- budget assertion -------------------------------------------------------
    gate_pure_p95_ms = max_p95 / 1000.0
    wire_vnet_shape_pure_p95_ms = (
        next(r["valid_p95_us"] for r in inproc["per_type"] if r["type"] == WIRE_FULL_TYPE) / 1000.0
    )
    overhead_p95 = v95 - wire_vnet_shape_pure_p95_ms

    checks = {
        "pure_validate_p95_under_1ms": max_p95 < GATE_BUDGET_MS * 1000,
        "wire_overhead_p95_under_1ms": overhead_p95 < GATE_BUDGET_MS,
    }
    for name, ok in checks.items():
        print(f"{'PASS' if ok else 'FAIL'} {name}")

    receipt = {
        "schema": SCHEMA,
        "date": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "repo": REPO,
        "in_process": {
            "n_types": 38,
            "n_per_class": 500,
            "max_valid_p95_us": max_p95,
            "max_invalid_p95_us": max_invalid_p95,
            "per_type": inproc["per_type"],
            "registry_100k": reg,
            "elixir": inproc.get("elixir"),
            "otp": inproc.get("otp"),
        },
        "wire": {
            "type": WIRE_FULL_TYPE,
            "n": N_WIRE,
            "valid_p50_ms": v50,
            "valid_p95_ms": v95,
            "invalid_p50_ms": i50,
            "invalid_p95_ms": i95,
            "p50_delta_ms": delta50,
            "overhead_p95_ms": overhead_p95,
            "valid_statuses": sorted(set(valid_st)),
            "invalid_statuses": sorted(set(invalid_st)),
        },
        "budget": {
            "budget_ms": GATE_BUDGET_MS,
            "checks": {k: bool(v) for k, v in checks.items()},
        },
        "verdict": "PASS" if all(checks.values()) else "FAIL",
    }
    os.makedirs(os.path.dirname(RECEIPT_PATH), exist_ok=True)
    with open(RECEIPT_PATH, "w") as f:
        json.dump(receipt, f, indent=2)
    print(f"receipt: {RECEIPT_PATH} verdict={receipt['verdict']}")

    if not all(checks.values()):
        sys.exit(3)


if __name__ == "__main__":
    main()

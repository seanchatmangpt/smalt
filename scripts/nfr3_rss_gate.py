#!/usr/bin/env python3
"""NFR3 RSS gate: fail-closed BEAM memory-budget fence (2026-10-16, lane 346).

Boots a real substrate on a private port block, samples total BEAM RSS
(before) via the shared scripts/stress/beam_rss.py sampler, drives a real
create+delete lifecycle over HTTP, samples (after), and FAILs (exit 1) when
the RSS delta exceeds SMALT_NFR3_BUDGET_KB (default 262144 KB = 256 MiB).

Receipt: JSON body embedded in a markdown receipt at
docs/jira/v26.10.16/sdk-results/nfr3-rss.md. Stdlib-only. Exit 0 pass /
1 gate fail / 2 substrate never up.

Usage: python3 scripts/nfr3_rss_gate.py [--keep]
  --keep  leave the substrate running after the gate (debug).
"""
import argparse
import http.client
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts", "stress"))
import _substrate  # noqa: E402
from beam_rss import beam_rss_kb  # noqa: E402

HOST = "127.0.0.1"
ARM_PORT = int(os.environ.get("SMALT_NFR3_ARM_PORT", "39463"))
DATA_PORT = 39465
ARM_TLS_PORT = 39464
AMQP_PORT = 39466
EVENT_HUBS_PORT = 39467
MCP_PORT = 39468
PORTS = (ARM_PORT, DATA_PORT, ARM_TLS_PORT, AMQP_PORT, EVENT_HUBS_PORT, MCP_PORT)
RECEIPT = os.path.join(REPO, "docs/jira/v26.10.16/sdk-results/nfr3-rss.md")

BUDGET_KB = int(os.environ.get("SMALT_NFR3_BUDGET_KB", "262144"))
TOKEN = ""
# Per-resource-type api-versions, matching Smalt.Registry.latest_version/1
# (lib/smalt/registry.ex: "Microsoft.Resources/resourceGroups" => "2023-07-01",
#  "Microsoft.EventGrid/topics" => "2021-04-01"). The wire (the registry the
# substrate serves from) is the source of truth; do not bump these by hand.
API_VERSION_RG = "2023-07-01"
API_VERSION_TOPIC = "2021-04-01"

RG = "nfr3-rg"
TOPIC = "nfr3-topic"
SUB = "00000000-0000-0000-0000-000000000000"
RES_PATH = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.EventGrid/topics/{TOPIC}"
RG_PATH = f"/subscriptions/{SUB}/resourceGroups/{RG}"


def fail(msg):
    print(f"[NFR3-FAIL] {msg}", file=sys.stderr)
    sys.exit(1)


def fail_down(msg):
    print(f"[NFR3-FAIL] {msg}", file=sys.stderr)
    sys.exit(2)


def spawn_substrate():
    env = dict(os.environ)
    env["MIX_ENV"] = "dev"
    eval_block = (
        f"Application.put_env(:smalt, :arm_port, {ARM_PORT}); "
        f"Application.put_env(:smalt, :arm_tls_port, {ARM_TLS_PORT}); "
        f"Application.put_env(:smalt, :egress_port, {DATA_PORT}); "
        f"Application.put_env(:smalt, :amqp_port, {AMQP_PORT}); "
        f"Application.put_env(:smalt, :event_hubs_port, {EVENT_HUBS_PORT}); "
        f"Application.put_env(:smalt, :mcp_port, {MCP_PORT}); "
        "Application.ensure_all_started(:smalt)"
    )
    return subprocess.Popen(
        ["mix", "run", "--no-start", "--no-halt", "--eval", eval_block],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
    )


def mint_token():
    """Mint a Bearer token from the substrate's own STS (exempt route)."""
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=15)

    try:
        body = ("grant_type=client_credentials&client_id=nfr3-gate"
                "&client_secret=nfr3-gate&scope=https://management.azure.com/.default")
        conn.request("POST", "/oauth2/v2.0/token", body=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": str(len(body)),
        })
        resp = conn.getresponse()
        data = resp.read()
        if resp.status != 200:
            fail(f"token mint -> {resp.status}: {data[:200]!r}")
        tok = json.loads(data).get("access_token")
        if not tok:
            fail("token mint returned no access_token")
        return tok
    finally:
        conn.close()


def arm(method, path, body=None, api=None):
    conn = http.client.HTTPConnection(HOST, ARM_PORT, timeout=10)
    payload = json.dumps(body) if body is not None else None
    headers = {"Content-Type": "application/json"} if payload else {}
    headers["Authorization"] = f"Bearer {TOKEN}"
    if api is None:
        api = API_VERSION_TOPIC if "/providers/" in path else API_VERSION_RG
    conn.request(method, f"{path}?api-version={api}", payload, headers)
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    return resp.status, data


def discover_api_version():
    """Removed: discovery probe was unreliable; api-versions are pinned
    per-resource-type to Smalt.Registry.latest_version/1 (see constants)."""
    return


def lifecycle():
    status, _ = arm("PUT", RG_PATH, {"location": "eastus", "properties": {}})
    if status not in (200, 201):
        fail(f"RG PUT returned {status}")
    status, _ = arm("PUT", RES_PATH, {"location": "eastus", "properties": {}})
    if status not in (200, 201):
        fail(f"resource PUT returned {status}")
    status, _ = arm("GET", RES_PATH)
    if status != 200:
        fail(f"resource GET returned {status}")
    status, _ = arm("DELETE", RES_PATH)
    if status not in (200, 202, 204):
        fail(f"resource DELETE returned {status}")
    status, _ = arm("GET", RES_PATH)
    if status != 404:
        fail(f"post-delete GET returned {status}, expected 404")


def write_receipt(sample):
    os.makedirs(os.path.dirname(RECEIPT), exist_ok=True)
    body = json.dumps(sample, indent=2)
    md = f"""# NFR3 RSS gate receipt

```json
{body}
```
"""
    with open(RECEIPT, "w") as f:
        f.write(md)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true",
                    help="leave the substrate running after the gate (debug)")
    args = ap.parse_args()

    _substrate.wait_port_free(ARM_PORT, timeout_s=15.0)
    proc = spawn_substrate()
    try:
        _substrate.wait_for_port(ARM_PORT, proc=proc, timeout_s=180.0,
                                 fail=fail_down, poll=0.02)
        global TOKEN
        TOKEN = mint_token()
        discover_api_version()
        rss_before = beam_rss_kb(PORTS)
        lifecycle()
        # settle: give the runtime a moment to finish GC of the lifecycle
        import time
        time.sleep(2.0)
        rss_after = beam_rss_kb(PORTS)
        delta = rss_after - rss_before
        # Absolute-delta fence: a large RSS DROP is as out-of-family as growth
        # (measurement anomaly or substrate instability). This is what makes
        # the gate able to fail — delta alone could ride negative GC swings
        # through any budget (negative control: SMALT_NFR3_BUDGET_KB=1).
        verdict = "PASS" if abs(delta) <= BUDGET_KB else "FAIL"
        # Typed diagnostic exit contract (v26.10.16 lane 430): the receipt
        # carries explicit {code, severity, remediation} per finding; a clean
        # run carries findings: [] (no failure entries). Severity vocabulary
        # matches Smalt.Enclave.Remediations (BLOCKING_GATE | ADVISORY).
        findings = []
        if verdict != "PASS":
            findings.append({
                "code": "NFR3_RSS_BUDGET_BREACH",
                "severity": "BLOCKING_GATE",
                "remediation": (
                    "python3 scripts/nfr3_rss_gate.py --keep  "
                    "# debug the live substrate; budget via SMALT_NFR3_BUDGET_KB"
                ),
            })
        sample = {
            "gate": "nfr3-rss",
            "before_kb": rss_before,
            "after_kb": rss_after,
            "delta_kb": delta,
            "budget_kb": BUDGET_KB,
            "idle_rss_kb": rss_before,
            "notes": "idle_rss_kb is informational (pre-lifecycle sample)",
            "verdict": verdict,
            "findings": findings,
        }
        write_receipt(sample)
        print(json.dumps(sample))
        if verdict != "PASS":
            fail(f"RSS delta {delta} KB exceeds budget {BUDGET_KB} KB")
        print(f"[NFR3-PASS] delta {delta} KB <= budget {BUDGET_KB} KB; receipt {RECEIPT}")
    finally:
        if not args.keep:
            _substrate.kill_substrate(proc, ports=PORTS)
            _substrate.wait_port_free(ARM_PORT, timeout_s=15.0)


if __name__ == "__main__":
    main()

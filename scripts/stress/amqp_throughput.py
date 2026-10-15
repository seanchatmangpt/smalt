#!/usr/bin/env python3
"""AMQP max-throughput benchmark harness.

Boots the smalt AMQP substrate on free ports, then drives it with the raw
FrameCodec Elixir driver (scripts/stress/amqp_tput_driver.exs).

  Phase A: 1 connection, 1 sender + 1 receiver, credit window 100, 1KB
           payloads, 60s sustained send->receive->complete round trip.
  Phase B: 4 parallel sender/receiver pairs on 4 queues (4 connections).

Compares against the census latency budget (docs/BENCHMARKS.md: AMQP
first-frame p95 < 100 ms). Receipt written to tmp/amqp-tput-receipt.json.
"""

import base64
import json
import os
import socket
import subprocess
import time

REPO = os.environ.get("SMALT_REPO", os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
DRIVER = os.path.join(REPO, "scripts", "stress", "amqp_tput_driver.exs")
RECEIPT = os.path.join(REPO, "tmp", "amqp-tput-receipt.json")
BUDGET_P95_MS = 100.0  # census budget: AMQP first-frame latency p95 < 100 ms

DURATION = int(os.environ.get("SMALT_TPUT_DURATION", "60"))
PAYLOAD = int(os.environ.get("SMALT_TPUT_PAYLOAD", "1024"))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_port(port, timeout=60.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def boot_substrate(ports, shared_key, log_path):
    env = dict(os.environ)
    env["MIX_ENV"] = "test"
    # MIX_ENV=test resolves listener ports at config time from SMALT_TEST_*_PORT
    # (docs/TEST_ISOLATION.md §2); put_env at `mix run -e` time is too late.
    env.update({
        "SMALT_TEST_AMQP_PORT": str(ports["amqp"]),
        "SMALT_TEST_ARM_PORT": str(ports["arm"]),
        "SMALT_TEST_EGRESS_PORT": str(ports["egress"]),
        "SMALT_TEST_EVENT_HUBS_PORT": str(ports["event_hubs"]),
    })
    expr = '; '.join([
        'Application.put_env(:smalt, :sb_shared_key, "%s")' % shared_key,
    ])
    cmd = ["mix", "run", "--no-halt", "-e", expr]
    with open(log_path, "w") as logf:
        proc = subprocess.Popen(
            cmd, env=env, cwd=REPO,
            stdout=logf, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    if not wait_port(ports["amqp"], 90):
        proc.kill()
        raise SystemExit("substrate never opened the AMQP port; see %s" % log_path)
    return proc


def run_driver(port, key, label, pairs, log_path):
    env = dict(os.environ)
    env.update({
        "MIX_ENV": "test",
        "SMALT_AMQP_PORT": str(port),
        "SMALT_SB_SHARED_KEY": key,
        "SMALT_TPUT_DURATION": str(DURATION),
        "SMALT_TPUT_PAYLOAD": str(PAYLOAD),
        "SMALT_TPUT_PAIRS": str(pairs),
        "SMALT_TPUT_LABEL": label,
    })
    cmd = ["mix", "run", DRIVER]
    with open(log_path, "w") as logf:
        rc = subprocess.run(
            cmd, env=env, cwd=REPO,
            stdout=logf, stderr=subprocess.STDOUT,
            timeout=DURATION * 4 + 300,
        ).returncode
    if rc != 0:
        raise SystemExit("driver failed (exit %d); see %s" % (rc, log_path))
    return parse_tput_json(log_path)


def parse_tput_json(path):
    line = None
    with open(path) as f:
        for raw in f:
            if raw.startswith("TPUT_JSON "):
                line = raw[len("TPUT_JSON "):].strip()
    if line is None:
        raise SystemExit("no TPUT_JSON line in %s" % path)
    return json.loads(line)


def main():
    ports = {k: free_port() for k in ("amqp", "arm", "egress", "event_hubs")}
    key = base64.b64encode(os.urandom(48)).decode()
    slog = os.path.join(REPO, "tmp", "amqp-tput-substrate.log")
    dlog = os.path.join(REPO, "tmp", "amqp-tput-driver.log")

    substrate = boot_substrate(ports, key, slog)
    try:
        print("phase A: single pair, credit window 100, %ds ..." % DURATION)
        solo = run_driver(ports["amqp"], key, "solo", 1, dlog)
        print(json.dumps(solo, indent=2))

        print("phase B: 4 parallel pairs on 4 queues, %ds ..." % DURATION)
        quad = run_driver(ports["amqp"], key, "quad", 4, dlog)
        print(json.dumps(quad, indent=2))
    finally:
        substrate.kill()
        try:
            substrate.wait(10)
        except subprocess.TimeoutExpired:
            substrate.kill()

    receipt = {
        "schema": "smalt-amqp-tput/v1",
        "date": time.strftime("%Y-%m-%d"),
        "subject": {"repo": REPO, "mix_env": "test", "driver": DRIVER, "payload_bytes": PAYLOAD, "duration_s": DURATION},
        "solo": solo,
        "quad": quad,
        "census_budget": {"amqp_first_frame_p95_ms": BUDGET_P95_MS},
        "verdict": {
            "solo_roundtrip_mps": solo.get("roundtrip_rate_mps"),
            "quad_roundtrip_mps": quad.get("roundtrip_rate_mps"),
            "solo_latency_p99_ms": solo.get("latency_ms", {}).get("p99"),
            "receive_path": quad.get("receive_path"),
        },
    }
    os.makedirs(os.path.dirname(RECEIPT), exist_ok=True)
    with open(RECEIPT, "w") as f:
        json.dump(receipt, f, indent=2)
    print("receipt: %s" % RECEIPT)


if __name__ == "__main__":
    main()

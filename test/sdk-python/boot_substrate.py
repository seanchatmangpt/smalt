"""Boot a lane-private smalt substrate with real readiness + teardown.

Replaces the old bare `subprocess.run` (blocked on the child forever,
Ctrl-C-only termination). Now: Popen + TCP readiness poll (deadline-bounded,
no fixed sleep) + guaranteed finally teardown. Exit codes: 0 substrate up and
cleanly torn down after the run body / 2 substrate never became ready.
"""

import os
import pathlib
import socket
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]

PORTS = (19443, 18443, 25672, 25673)

ARGV = [
    "/opt/homebrew/bin/mix", "run", "--no-start", "--no-halt", "-e",
    'Application.put_env(:smalt, :sts_signing_secret, "py-lane6-known-secret-0123456789abcdef");'
    'Application.put_env(:smalt, :auth_mode, :enforce);'
    ''
    'Application.put_env(:smalt, :arm_port, 19443);'
    'Application.put_env(:smalt, :egress_port, 18443);'
    'Application.put_env(:smalt, :arm_tls_port, 19444);'
    'Application.put_env(:smalt, :mcp_port, 19545);'
    'Application.put_env(:smalt, :amqp_port, 25672);'
    'Application.put_env(:smalt, :event_hubs_port, 25673);'
    '{:ok, _} = Application.ensure_all_started(:smalt)',
]


def _up(port, deadline_s=60.0):
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        if proc.poll() is not None:
            raise RuntimeError(
                f"SUBSTRATE_DIED rc={proc.returncode} pre-ready (port {port})")
        with socket.socket() as s:
            s.settimeout(0.5)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.2)
    return False


env = dict(os.environ)
proc = subprocess.Popen(ARGV, cwd=str(REPO), env=env)
try:
    if not all(_up(p) for p in PORTS):
        print(
            f"SUBSTRATE_TIMEOUT — ports {PORTS} not open within 60s each "
            f"(pid {proc.pid})", file=sys.stderr)
        sys.exit(2)
    print(f"[boot_substrate] substrate up on {PORTS} (pid {proc.pid})")

    # Run body: whatever this script fronts goes here. Today it fronts
    # nothing — it exists to prove readiness and hand off/tear down.
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

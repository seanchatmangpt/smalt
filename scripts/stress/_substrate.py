#!/usr/bin/env python3
"""Canonical substrate lifecycle helpers for the stress harnesses.

Deduces the copy-pasted wait/kill/port-free triplet that was repeated across
arm_scale, blob_scale, cosmos_bulk, chaos_kill, spike, ycsb_lite, gate_cost
(and bench.py). Spawn stays per-script: each harness injects its own private
ports via `mix run --no-start --no-halt --eval "Application.put_env(...)"`.

Fail-closed law: lifecycle helpers take `fail` — the harness's fail_closed
(print FAULT + exit nonzero). Passing fail=None is a programming error for
wait_for_port and raises instead of ever silently succeeding.

These are the same semantics as the deleted per-script copies; per-harness
differences (timeout, poll interval, swept ports, signal) are parameters.
"""
import os
import signal
import socket
import subprocess
import sys
import time

HOST = "127.0.0.1"


def port_open(port, timeout=0.25):
    try:
        with socket.create_connection((HOST, port), timeout=timeout):
            return True
    except OSError:
        return False


def install_sigterm_handler():
    """SIGTERM -> SystemExit(128+signum) so a caller's finally-block teardown
    runs instead of orphaning the substrate (lens-5 cycle 5; the same guard
    gates/common.run_gate has carried since lens-4 cycle 6, mutation-verified
    load-bearing there — sigterm_court 2/2 ORPHAN when removed). Restores the
    previous handler is the caller's job (harnesses install once at main).
    """
    def _on_sigterm(signum, frame):
        raise SystemExit(128 + signum)
    return signal.signal(signal.SIGTERM, _on_sigterm)


def wait_for_port(port, proc=None, timeout_s=120.0, fail=None, poll=0.01,
                  conn_timeout=0.25):
    """Poll TCP connect until `port` accepts; return elapsed seconds.

    Fails closed via `fail(message)` if `proc` dies before binding or the
    deadline passes.
    """
    if fail is None:
        def fail(message):  # noqa: F811 — fail-closed default, never silent
            raise RuntimeError(message)

    t0 = time.monotonic()
    deadline = t0 + timeout_s
    while time.monotonic() < deadline:
        if proc is not None and proc.poll() is not None:
            fail(f"substrate exited rc={proc.poll()} before binding :{port}")
        if port_open(port, conn_timeout):
            return time.monotonic() - t0
        time.sleep(poll)
    fail(f"substrate never bound :{port} within {timeout_s}s")


def kill_substrate(proc=None, ports=(), sig=signal.SIGKILL):
    """SIGKILL the process group, reap, then sweep surviving port holders.

    Never raises. `ports` are swept via lsof for BEAM children that outlive
    the mix wrapper's process group.
    """
    if proc is not None:
        try:
            os.killpg(os.getpgid(proc.pid), sig)
        except (ProcessLookupError, PermissionError):
            try:
                proc.kill()
            except Exception:
                pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
    for port in ports:
        try:
            out = subprocess.run(["lsof", "-ti", f"tcp:{port}"],
                                 capture_output=True, text=True, timeout=10).stdout
        except Exception:
            out = ""
        for pid in out.split():
            try:
                os.kill(int(pid), sig)
            except (ValueError, ProcessLookupError, PermissionError):
                pass


def wait_port_free(port, timeout_s=15.0, poll=0.05):
    """True when `port` refuses connections within timeout_s, else False."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        if not port_open(port, timeout=0.2):
            return True
        time.sleep(poll)
    return False

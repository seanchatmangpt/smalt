#!/usr/bin/env python3
"""Shared BEAM RSS sampler (extracted from arm_scale.py, 2026-10-16, lane 346).

Total RSS (KB) of every process holding/listening on the substrate ports.
Importable by any stress/gate harness:

    from beam_rss import beam_rss_kb, SUBSTRATE_PORTS

Port defaults mirror arm_scale.py's private block (env-overridable, per
docs/how-to/dev-loop.md "Private port allocation").
"""
import os
import subprocess

HOST = "127.0.0.1"

# Private block per docs/how-to/dev-loop.md "Private port allocation" (2026-10-15).
# Env-overridable, same env names as arm_scale.py so a harness pointed at a
# specific lane substrate samples the right processes.
ARM_PORT = int(os.environ.get("SMALT_ARMSCALE_ARM_PORT", "39453"))
DATA_PORT = int(os.environ.get("SMALT_ARMSCALE_EGRESS_PORT", "39455"))
ARM_TLS_PORT = int(os.environ.get("SMALT_ARMSCALE_TLS_PORT", "39454"))
AMQP_PORT = int(os.environ.get("SMALT_ARMSCALE_AMQP_PORT", "39456"))
EVENT_HUBS_PORT = int(os.environ.get("SMALT_ARMSCALE_EVENT_HUBS_PORT", "39457"))
MCP_PORT = int(os.environ.get("SMALT_ARMSCALE_MCP_PORT", "39458"))

SUBSTRATE_PORTS = (ARM_PORT, DATA_PORT, ARM_TLS_PORT, AMQP_PORT,
                   EVENT_HUBS_PORT, MCP_PORT)


def beam_rss_kb(ports=SUBSTRATE_PORTS):
    """Total RSS (KB) of every process holding/listening on the given ports."""
    pids = set()
    for port in ports:
        try:
            out = subprocess.run(["lsof", "-ti", f"tcp:{port}"],
                                 capture_output=True, text=True, timeout=10).stdout
        except Exception:
            out = ""
        pids.update(int(p) for p in out.split() if p.isdigit())
    total = 0
    for pid in pids:
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=10).stdout
            total += int(out.strip() or 0)
        except Exception:
            pass
    return total

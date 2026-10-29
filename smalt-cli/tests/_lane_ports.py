"""Lane-private port blocks for the smalt-cli conftest substrates (BK-CONF).

BK-149C follow-up: under load, concurrent cli suites shared the fixed
39643/38654 blocks and the identity guards mutually swept each other's live
substrates mid-run. Law (same-checkout fan-out port law, scripts/bench/lib.sh):
test lanes must not share port blocks.

Derivation (deterministic, env-overridable):
  lane name  = $SMALT_CLI_LANE if set (both profiles get "<lane>-<profile>"),
               else "cli-<profile>-<venv basename>" (e.g. cli-anonymous-venv-cli)
  slot       = sha256(lane name) mod N_SLOTS
  base       = BAND_START + slot * 10          (10-wide block per the bN law)
  ports      = base+0 arm, base+1 egress, base+2 amqp, base+3 event_hubs,
               base+4 arm_tls

Band 39500..39990 avoids the bench b1..b12 blocks (39010..39125) and the
legacy fixed cli blocks (39643/38654-family) so old harnesses keep running
through the transition. If the hashed slot is occupied by a foreign listener
(no valid lane marker), the scan walks slots in (hash + k) mod N_SLOTS order
to the first block whose 5 ports are all free — a concurrent lane can never
be swept, only re-slotted. Sequential runs reuse via per-(lane, base) markers.

Env overrides:
  SMALT_CLI_LANE       lane name (per pytest invocation)
  SMALT_CLI_PORT_BASE  pin the anonymous-profile base port directly
"""
import hashlib
import os
import sys

BAND_START = 39500
SLOT_WIDTH = 10
N_SLOTS = 50  # 39500..39990, each block base..base+4 used

PORT_ROLES = ("arm", "egress", "amqp", "eh", "atls")


def _venv_basename():
    return os.path.basename(sys.prefix.rstrip("/")) or "cli"


def lane_name(profile):
    override = os.environ.get("SMALT_CLI_LANE")
    if override:
        return f"{override}-{profile}"
    return f"cli-{profile}-{_venv_basename()}"


def block_ports(base):
    return tuple(base + i for i in range(len(PORT_ROLES)))


def _occupied(port):
    """True if something LISTENs on 127.0.0.1:<port> (connect probe)."""
    import socket

    with socket.socket() as s:
        s.settimeout(0.25)
        return s.connect_ex(("127.0.0.1", port)) == 0


def resolve_lane_ports(profile, owns_block=None):
    """Resolve this lane's private port block.

    owns_block(base) -> bool: optional callback, True when the block at `base`
    is already ours (valid per-(lane, base) identity marker + live listener).
    Slot order: sha256(lane) first, then (hash + k) mod N_SLOTS — deterministic
    for the lane name, collision-relocating when the hashed block is held by a
    foreign listener (occupied blocks are never swept from here).
    """
    lane = lane_name(profile)
    digest = int(hashlib.sha256(lane.encode()).hexdigest(), 16)
    for k in range(N_SLOTS):
        base = BAND_START + ((digest + k) % N_SLOTS) * SLOT_WIDTH
        if owns_block is not None and owns_block(base):
            return {"lane": lane, "base": base, "ports": block_ports(base)}
        if all(not _occupied(base + i) for i in range(len(PORT_ROLES))):
            return {"lane": lane, "base": base, "ports": block_ports(base)}
    raise RuntimeError(
        f"lane-ports[{lane}]: no free private block in "
        f"{BAND_START}..{BAND_START + N_SLOTS * SLOT_WIDTH} "
        f"(SMALT_CLI_LANE={os.environ.get('SMALT_CLI_LANE', '<unset>')})"
    )

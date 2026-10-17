#!/usr/bin/env python3
"""Witness for the lock-clamp shim court (lane M5, v26.10.16).

Drives the REAL verdict function of gates/lock_clamp_gate.py in-process (no
substrate boot: the subject under court is the verdict logic, not the live
capture). Chicago-style: the collaborator is the actual gate module.

Usage: lock_clamp_witness.py refused|admitted [gate_path]
  refused  exit 0 iff verdict() REFUSES an unclamped-high delta (3600000ms)
           while still ADMITTING the fully-clamped observation.
  admitted exit 0 iff verdict() ADMITS that same unclamped-high delta
           (the shim neutered the clamp-window check).
"""
import importlib.util
import sys

GATE = sys.argv[2] if len(sys.argv) > 2 else "gates/lock_clamp_gate.py"
mode = sys.argv[1] if len(sys.argv) > 1 else ""

spec = importlib.util.spec_from_file_location("lock_clamp_gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

CLAMPED = {
    "requested": {"30000": 3_600_000, "100": 0, "5000": 5_000},
    "observed_delta": {
        "30000": {"delta": 30_000, "delivery_count": 1},
        "100": {"delta": 100, "delivery_count": 1},
        "5000": {"delta": 5_000, "delivery_count": 1},
    },
}
UNCLAMPED_HIGH = {
    "requested": {"30000": 3_600_000, "100": 0, "5000": 5_000},
    "observed_delta": {
        # raw 1-hour lock leaked past the 30s clamp — the gate must catch this
        "30000": {"delta": 3_600_000, "delivery_count": 1},
        "100": {"delta": 100, "delivery_count": 1},
        "5000": {"delta": 5_000, "delivery_count": 1},
    },
}

ok_c, details_c = gate.verdict(dict(CLAMPED))
ok_u, details_u = gate.verdict(dict(UNCLAMPED_HIGH))
print("[witness] clamped obs verdict ok=%s" % ok_c)
print("[witness] unclamped-high obs verdict ok=%s :: %s"
      % (ok_u, [d for d in details_u if d.startswith("FAIL")] or "no FAIL"))

if mode == "refused":
    # BEFORE: pristine gate refuses the unclamped delta, admits the clamped one.
    sys.exit(0 if (not ok_u and ok_c) else 1)
elif mode == "admitted":
    # AFTER: shimmed gate admits the unclamped delta (flip = non-vacuity proof).
    sys.exit(0 if ok_u else 1)
else:
    print("usage: lock_clamp_witness.py refused|admitted [gate_path]")
    sys.exit(2)

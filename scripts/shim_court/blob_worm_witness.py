#!/usr/bin/env python3
"""Witness for blob_worm_court.sh (lane M2, v26.10.16).

Imports the blob-worm gate by path (no substrate, no HTTP — pure verdict
logic over a constructed observation) and asserts on real verdict state:

  mode=refuse  every mutated WORM observation produced by the gate's own
               mutate_fixtures() must be REFUSED (verdict ok=False). This is
               the old signature: the gate detects corruption.
  mode=admit   the overwrite-accepted mutation (a mutated write against a
               WORM-locked container observation) must be ADMITTED
               (verdict ok=True). Only holds when the gate's overwrite
               refusal check has been shimmed away — this is the flip.

Usage: blob_worm_witness.py <mode> <path/to/blob_worm_gate.py>
Exit:  0 assert holds; 1 assert fails (typed message on stderr).
"""
import importlib.util
import sys


def load_gate(path):
    spec = importlib.util.spec_from_file_location("blob_worm_gate", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def base_obs():
    """A fully-compliant WORM observation (every check in verdict() passes)."""
    return {
        "container_create": 201,
        "blob_put": 201,
        "legal_hold": 200,
        "overwrite_locked_status": 409,
        "overwrite_locked_code": "ContainerLocked",
        "delete_locked_status": 409,
        "delete_locked_code": "ContainerLocked",
        "hold_release": 200,
        "delete_after_release": 202,
    }


def main():
    if len(sys.argv) != 3:
        print("usage: blob_worm_witness.py <refuse|admit> <gate.py>", file=sys.stderr)
        return 1
    mode, gate_path = sys.argv[1], sys.argv[2]
    gate = load_gate(gate_path)
    obs = base_obs()
    ok, details = gate.verdict(obs)
    if not ok:
        print("[witness] healthy observation refused?!", file=sys.stderr)
        for d in details:
            print("  " + d, file=sys.stderr)
        return 1

    # The mutated write attempt against the WORM-locked container: the gate's
    # own negative fixture "overwrite-accepted" (409 -> 200, code stripped).
    mutated = None
    for name, m in gate.mutate_fixtures(obs):
        if name == "overwrite-accepted":
            mutated = m
            break
    if mutated is None:
        print('[witness] FATAL: gate exposes no "overwrite-accepted" fixture', file=sys.stderr)
        return 1

    ok, details = gate.verdict(mutated)
    if mode == "refuse":
        if ok:
            print("[witness] REFUSE leg FAILED: mutated WORM write ADMITTED by gate:", file=sys.stderr)
            for d in details:
                print("  " + d, file=sys.stderr)
            return 1
        print("[witness] refuse leg: mutated write against WORM-locked container REFUSED (409/ContainerLocked enforced)")
        failed = [d for d in details if d.startswith("FAIL")]
        print("[witness] refusal checks fired: " + "; ".join(failed))
        return 0
    if mode == "admit":
        if not ok:
            print("[witness] ADMIT leg FAILED: gate still refuses the mutated write:", file=sys.stderr)
            for d in details:
                print("  " + d, file=sys.stderr)
            return 1
        print("[witness] admit leg: gate ADMITS the mutated write (refusal check absent) — flip observed")
        return 0
    print(f"[witness] unknown mode {mode}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())

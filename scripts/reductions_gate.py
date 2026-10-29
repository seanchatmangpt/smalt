#!/usr/bin/env python3
"""reductions_gate.py — IMPL-24 reductions ceiling fence (v26.10.21).

Fail-closed gate: re-measures per-stage reductions for one settlement
orchestration (HTN -> FOND -> POWL -> OCEL -> seal, 8 tasks) via the SAME
method as the PB-2 baseline — scripts/bench/pb2_reductions_step.exs
(:erlang.statistics(:reductions) delta over iters repeats of each real stage
body, plus tprof :call_memory for the words column) — and refuses if ANY stage
exceeds 2x its PB-2 baseline stage reductions.

Baseline: tmp/bench/pb2-reductions-step.jsonl (PB-2's landed artifact).
Ceiling derivation (documented law): ceiling = 2.0x baseline (100% headroom).
Per-stage reductions on the BEAM are stable run-to-run (deterministic opcode
streams after warm-up — the seeded fixture reproduced stage counts identically
across three runs this session), so 2x absorbs toolchain-level churn (OTP minor
bumps, DETS internals) while still catching the order-of-magnitude /
whole-new-work regressions the fence exists for — a rogue 2x regression trips
exactly at the fence; a new call path trips far earlier. The fence is
per-stage, not summed: a stage that grows 3x while another shrinks is still a
breach (summing would mask it).

Exit codes: 0 pass / 1 CEILING BREACH (or stage-surface mismatch) / 2
environment error (mix failed, unparseable output) / 3 SKIP (PB-2 baseline
absent — loud, never a fake pass).
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "bench" / "pb2_reductions_step.exs"
BASELINE = ROOT / "tmp" / "bench" / "pb2-reductions-step.jsonl"
# Court/scratch override: point the gate at a non-PB-2 baseline fixture.
BASELINE = Path(os.environ.get("REDUCTIONS_GATE_BASELINE", BASELINE))

# Ceiling multiplier over the PB-2 per-stage baseline.
CEILING_FACTOR = 2.0  # SHIM-COURT-ANCHOR: court mutates this line

REDS_LINE = re.compile(r"^([a-z_0-9]+): (\d+) reductions/txn", re.M)


def run_profile():
    # PB-2's script rewrites its own jsonl at the end; never let a gate
    # measurement clobber the landed baseline — snapshot and byte-restore.
    snapshot = BASELINE.read_bytes() if BASELINE.exists() else None
    try:
        return _run_profile_inner()
    finally:
        if snapshot is not None:
            BASELINE.write_bytes(snapshot)


def _run_profile_inner():
    env = {"MIX_BUILD_ROOT": _build_root(), "MIX_ENV": "test"}
    env.update({k: v for k, v in os.environ.items()
                if k in ("PATH", "HOME", "LANG", "LC_ALL")})
    # asdf elixir shim does not put its own OTP ahead of a stray `erl` on PATH
    # (~/.erlmcp/otp-28 wins); repo pin is erlang 29.1.2 — force it first.
    asdf_bin = Path.home() / ".asdf/installs/erlang/29.1.2/bin"
    asdf_elixir = Path.home() / ".asdf/installs/elixir/1.20.4-otp-29/bin"
    prepend = [str(p) for p in (asdf_elixir, asdf_bin) if p.exists()]
    if prepend:
        env["PATH"] = ":".join(prepend + [env.get("PATH", "")])
    proc = subprocess.run(
        ["mix", "run", "--no-start", str(SCRIPT.relative_to(ROOT))],
        cwd=str(ROOT), env=env, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(proc.stdout[-3000:] + proc.stderr[-3000:], file=sys.stderr)
        sys.exit(2)
    stages = {m.group(1): int(m.group(2))
              for m in REDS_LINE.finditer(proc.stdout)}
    if not stages:
        print("no 'reductions/txn' lines in profiler output", file=sys.stderr)
        sys.exit(2)
    return stages


def _build_root():
    return "_build-impl24"


def load_baseline():
    if not BASELINE.exists() or BASELINE.stat().st_size == 0:
        print(f"[SKIP] reductions-gate: PB-2 baseline absent: {BASELINE}", file=sys.stderr)
        sys.exit(3)
    stages = {}
    for line in BASELINE.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        stage = row.get("stage")
        reds = row.get("reductions")
        if stage and reds is not None:
            stages[stage] = reds
    if not stages:
        print(f"[SKIP] reductions-gate: baseline has no stage/reductions rows: {BASELINE}",
              file=sys.stderr)
        sys.exit(3)
    return stages


def seed():
    """--seed: run the real profiler once and write stage rows to
    $REDUCTIONS_GATE_BASELINE (court-owned fixture path; the PB-2 file is
    never written by this gate)."""
    path = os.environ["REDUCTIONS_GATE_BASELINE"]
    stages = run_profile()
    with open(path, "w") as fh:
        for stage, reds in sorted(stages.items()):
            fh.write(json.dumps({
                "lane": "impl24-seed",
                "stage": stage,
                "reductions": reds,
                "provenance": "reductions_gate --seed (real PB-2-method measurement)",
            }) + "\n")
    print(f"[seed] wrote {len(stages)} stage rows to {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", action="store_true",
                    help="measure and write stage rows to $REDUCTIONS_GATE_BASELINE "
                         "(court fixture path; never the PB-2 file)")
    args = ap.parse_args()

    if args.seed:
        seed()
        return

    baseline = load_baseline()
    stages = run_profile()

    missing = sorted(set(baseline) - set(stages))
    if missing:
        print(f"[FAIL:CEILING] reductions-gate: stages absent from "
              f"re-measurement: {missing}", file=sys.stderr)
        sys.exit(1)

    breaches = [(s, stages[s], baseline[s]) for s in sorted(baseline)
                if stages[s] > baseline[s] * CEILING_FACTOR]

    if not breaches:
        detail = ", ".join(f"{s}={stages[s]}/{baseline[s]}" for s in sorted(baseline))
        print(f"[PASS] reductions-gate: all {len(baseline)} stages <= "
              f"{CEILING_FACTOR}x PB-2 baseline ({detail})")
        return

    for s, measured, base in breaches:
        print(f"[FAIL:CEILING] reductions-gate: stage {s} {measured} reds > "
              f"{CEILING_FACTOR}x baseline {base} reds ({measured / base:.2f}x)")
    sys.exit(1)


if __name__ == "__main__":
    main()

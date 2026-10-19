#!/usr/bin/env python3
"""Telemetry overhead A/B stress runner (see docs/STRESS/TELEMETRY.md).

Runs scripts/stress/telemetry_driver.exs three times via `mix run`:
  a — telemetry attached (prod wiring)
  b — attach disabled (:telemetry.detach before the timed loop)
  c — attach + 64-lane emitter load + dump-under-load + ETS contention court

Computes overhead % (b vs a) and counter-contention cost (c vs a), asserts
overhead < 5%, prints a receipt. Real runs only; exits nonzero on failure.

Usage: python3 scripts/stress/telemetry_overhead.py [--puts 5000] [--repo REPO]
"""

import argparse
import json
import re
import subprocess
import sys
import time

RESULT_RE = re.compile(r"^RESULT_JSON: (.*)$", re.M)


def run_mode(repo: str, mode: str, puts: int, env_extra: dict) -> dict:
    # PATH: prefer the pinned erlmcp OTP if present, else the ambient PATH
    # (checkout-relative, no hardcoded user paths).
    erlmcp_bin = os.path.join(os.path.expanduser("~"), ".erlmcp", "otp-28.3.1/bin")
    path = (f"{erlmcp_bin}:{os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin')}"
            if os.path.isdir(erlmcp_bin)
            else os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"))
    env = {"PATH": path, "HOME": __import__("os").environ.get("HOME", ""), "MIX_ENV": "dev", **env_extra}
    env.update({k: v for k, v in __import__("os").environ.items() if k in ("MIX_BUILD_ROOT",)})

    cmd = ["mix", "run", "--no-start", "scripts/stress/telemetry_driver.exs"]
    t0 = time.time()
    proc = subprocess.run(
        cmd, cwd=repo, env=env, capture_output=True, text=True, timeout=1800, errors="replace"
    )
    wall = time.time() - t0

    m = RESULT_RE.search(proc.stdout)
    if not m:
        print(f"FAIL: mode {mode} produced no RESULT_JSON (exit {proc.returncode})", file=sys.stderr)
        print("stdout tail:\n" + proc.stdout[-3000:], file=sys.stderr)
        print("stderr tail:\n" + proc.stderr[-3000:], file=sys.stderr)
        sys.exit(2)

    result = json.loads(m.group(1))
    result["exit_code"] = proc.returncode
    result["wall_s"] = round(wall, 1)
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--puts", type=int, default=5000)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument(
    "--repo",
    default=os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))),
)
    ap.add_argument("--json-out", default="")
    args = ap.parse_args()

    results = {}
    reps = args.reps

    # Interleave a/b to cancel run-order drift (first-run compile/cache warmup),
    # then take per-mode medians. c runs once (load court, not the A/B pair).
    order = ["a", "b"] * reps + ["c"]
    for mode in order:
        r = run_mode(args.repo, mode, args.puts, {"SMALT_STRESS_MODE": mode, "SMALT_STRESS_PUTS": str(args.puts)})
        results.setdefault(mode, []).append(r)
        print(
            f"[mode {mode}] {r['puts']} PUTs in {r['elapsed_ms']} ms "
            f"({r['per_put_ms']} ms/PUT, wall {r['wall_s']}s, exit {r['exit_code']})"
        )

    def median(samples):
        xs = sorted(s["elapsed_ms"] for s in samples)
        return xs[len(xs) // 2]

    a_ms, b_ms = median(results["a"]), median(results["b"])
    c = results["c"][-1]

    # Overhead of instrumentation (a) relative to detached (b):
    # overhead% = (t_a - t_b) / t_b * 100
    overhead_pct = (a_ms - b_ms) / b_ms * 100.0
    contention_pct = (c["elapsed_ms"] - a_ms) / a_ms * 100.0

    receipt = {
        "subject": {"repo": args.repo, "driver": "scripts/stress/telemetry_driver.exs", "runner": "scripts/stress/telemetry_overhead.py"},
        "reps": reps,
        "median_elapsed_ms": {"a": a_ms, "b": b_ms, "c": c["elapsed_ms"]},
        "runs": results,
        "overhead_pct_attached_vs_detached": round(overhead_pct, 2),
        "contention_pct_64lanes_vs_a": round(contention_pct, 2),
        "ets_court": c["ets_court"],
        "dump_under_load": c["dump"],
        "assertion": {"claim": "attached overhead < 5%", "threshold_pct": 5.0, "measured_pct": round(overhead_pct, 2)},
    }

    print(json.dumps(receipt, indent=2))

    ok = overhead_pct < 5.0
    if not ok:
        print(f"FINDING: attached overhead {overhead_pct:.2f}% >= 5% threshold — profile handle_event/RollingCounters.bump", file=sys.stderr)

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(receipt, f, indent=2)

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""tprof_memory_gate.py — AR-OBS-03 CI memory-ceiling fence (v26.10.21).

Fail-closed gate: profiles one real cosmos put_doc transaction via tprof
call_memory (see scripts/tprof_memory_profile.exs) and refuses if the summed
allocated words across the call tree exceed the ceiling.

Ceiling derivation (VAL-OBS receipt docs/jira/v26.10.21/receipts/val-ar-obs.md):
measured baseline 134 words/txn on OTP 28.3.1 (Apple M3 Max, 288-byte payload).
Ceiling = 200 words => 49% headroom ((200-134)/134 = 0.4925). Headroom absorbs
toolchain-level churn (OTP minor bumps, Jason internals) while still catching
the order-of-magnitude leaks the fence exists for (a rogue 2x regression at
268 words trips it; a whole-new-encode-path regression trips it far earlier).

Exit codes: 0 pass / 1 CEILING BREACH / 2 environment error (tprof absent,
mix failed) — a breach is never reported as pass, env problems never count as
either.

--seed: re-baseline. Runs the profile and rewrites the CEILING_WORDS constant
in this file to round(measured * 1.5), keeping the 49%-headroom law.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "tprof_memory_profile.exs"

# Ceiling in allocated words per cosmos put_doc transaction.
# Derived from VAL-OBS 134-word baseline with 49% headroom ((200-134)/134).
CEILING_WORDS = 200  # SHIM-COURT-ANCHOR: court mutates this line


def run_profile():
    env = {"MIX_BUILD_ROOT": "_build-obsfence", "MIX_ENV": "test"}
    env.update({k: v for k, v in __import__("os").environ.items()
                if k in ("PATH", "HOME", "LANG", "LC_ALL")})
    proc = subprocess.run(
        ["mix", "run", str(SCRIPT.relative_to(ROOT))],
        cwd=str(ROOT), env=env, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(proc.stdout[-3000:] + proc.stderr[-3000:], file=sys.stderr)
        sys.exit(2)
    for line in proc.stdout.splitlines():
        if line.startswith("OBS03 "):
            return json.loads(line[len("OBS03 "):])
    print("no OBS03 line in profiler output", file=sys.stderr)
    sys.exit(2)


def seed(measured):
    ceiling = round(measured * 1.5)
    text = SCRIPT.with_name("tprof_memory_gate.py").read_text()
    new = re.sub(r"(?m)^CEILING_WORDS = \d+", f"CEILING_WORDS = {ceiling}", text)
    SCRIPT.with_name("tprof_memory_gate.py").write_text(new)
    print(f"[seed] measured {measured} words -> ceiling {ceiling} "
          f"(~49% headroom); CEILING_WORDS updated")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", action="store_true",
                    help="re-baseline: measure and rewrite CEILING_WORDS")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    data = run_profile()
    words = data["alloc_words"]

    if args.seed:
        seed(words)
        return

    if words <= CEILING_WORDS:
        if not args.quiet:
            print(f"[PASS] tprof-memory-gate: {words} words/txn <= ceiling "
                  f"{CEILING_WORDS} (otp {data['otp']}, {data['rows']} rows)")
        return
    print(f"[FAIL:CEILING] tprof-memory-gate: {words} words/txn > ceiling "
          f"{CEILING_WORDS} (otp {data['otp']}, top: "
          f"{json.dumps(data['top'][:3])})")
    sys.exit(1)


if __name__ == "__main__":
    main()

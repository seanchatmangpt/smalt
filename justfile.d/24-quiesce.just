# 24-quiesce — court precondition court (v26.10.17 lesson, receipts r240):
# both court-x2 attempts failed their COLD run 1 on load faces and passed the
# warm run 2. Encode the quiesce + warm-up discipline mechanically.

# Verify the machine is quiet enough for a court run: no stray beams, court
# ports free, no concurrent suites/courts. Exits 1 loudly on any violation.
@quiet-check:
    python3 scripts/quiet_check.py

# Full quiesce before a court: quiet-check + a warm-up full offline suite that
# absorbs cold-compile/profile noise, then quiet-check again. Run before
# `just court-x2` when the machine has been busy.
@quiesce: && quiesce-warm
    just quiet-check

@quiesce-warm:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "[QUIESCE] warm-up: full offline suite pass (absorbs cold run-1 load faces)"
    MIX_BUILD_ROOT=_build-warmup mix test 2>&1 | tail -2
    rm -rf _build-warmup
    just quiet-check
    echo "[QUIESCE] machine settled — clear for court-x2"

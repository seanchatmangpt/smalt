# 42-popcorn-bench.just — popcorn_demo bench lanes (W3-12, v26.10.20)
#
# Wraps popcorn_demo/scripts/bench_legs.sh (lane "legs") and bench_cook.sh
# (lane "cook"). House law: prefixed vars, shebang recipes, set -euo pipefail;
# this module owns only these recipes — the root justfile gains one import line.

POPCORN_BENCH_ROOT := justfile_directory()
POPCORN_BENCH_DIR := POPCORN_BENCH_ROOT / "popcorn_demo"

# Lane "legs": host-leg latency bench (Live / LiveMatrix / LiveBlob, N=5 via
# RUNS env). Appends to popcorn_demo/bench/legs.jsonl; the script fences
# row-to-row (regression = median_ms > 2x the previous row for the same leg).
@popcorn-bench-legs:
    #!/usr/bin/env bash
    set -euo pipefail
    test -x "{{POPCORN_BENCH_DIR}}/scripts/bench_legs.sh" \
        || { echo "[POPCORN-BENCH] MISSING {{POPCORN_BENCH_DIR}}/scripts/bench_legs.sh"; exit 1; }
    cd "{{POPCORN_BENCH_ROOT}}"
    exec bash popcorn_demo/scripts/bench_legs.sh

# Lane "cook": cook + browser-boot budget bench. bench_cook.sh may land
# concurrently (W2-11); absent file = typed loud [SKIP], exit 0 — never a fake
# pass, never a silent skip.
@popcorn-bench-cook:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{POPCORN_BENCH_DIR}}/scripts/bench_cook.sh" ]; then
        echo "[SKIP] popcorn-bench-cook: popcorn_demo/scripts/bench_cook.sh not present yet (concurrent lane W2-11)"
        exit 0
    fi
    cd "{{POPCORN_BENCH_ROOT}}"
    exec bash popcorn_demo/scripts/bench_cook.sh

# Lane "scvd" (W3-11 / S2): SCVD bench. bench_scvd.sh may land concurrently
# (S2's lane); absent file = typed loud [SKIP], exit 0 — never a fake pass,
# never a silent skip; present = propagate its exit unchanged, fail-closed.
@popcorn-bench-scvd:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{POPCORN_BENCH_DIR}}/scripts/bench_scvd.sh" ]; then
        echo "[SKIP] popcorn-bench-scvd: popcorn_demo/scripts/bench_scvd.sh not present yet (concurrent lane S2)"
        exit 0
    fi
    cd "{{POPCORN_BENCH_ROOT}}"
    exec bash popcorn_demo/scripts/bench_scvd.sh

# Fence check: re-run lane "legs"; the script itself enforces the relative
# ratio fence (median_ms > 2x previous row = exit nonzero) — this recipe
# surfaces its exit code unchanged, fail-closed.
@popcorn-bench-fence-check: popcorn-bench-legs

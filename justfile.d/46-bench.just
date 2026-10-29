# 46-bench.just — BENCH-8 escript court runner (v26.10.21).
#
# Wraps bin/court-bench: compiles bench/*.erl via erlc (OTP-29 toolchain)
# into the lane-private build root _bench-escript/ebin and runs the bench
# court. Exit contract: 0 = PASS, 1 = FAIL (fail-closed; compile errors,
# malformed receipts, or court exceptions all exit 1). This module owns only
# this recipe — the root justfile gains one import line.

BENCH8_ROOT := justfile_directory()
BENCH8_ERL29 := "/opt/homebrew/opt/erlang@29/bin"

# `just court-bench` — pure-Erlang bench court (no Mix, no substrate).
# Honors COURT_BENCH_DIR (default <root>/bench) for alternate bench dirs.
@court-bench:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="{{BENCH8_ERL29}}:$PATH"
    test -x "{{BENCH8_ROOT}}/bin/court-bench" \
        || { echo "[court-bench] MISSING {{BENCH8_ROOT}}/bin/court-bench"; exit 1; }
    cd "{{BENCH8_ROOT}}"
    exec ./bin/court-bench "${COURT_BENCH_DIR:-bench}"

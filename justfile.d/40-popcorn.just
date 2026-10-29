# 40-popcorn.just — popcorn_demo testbed recipes (LANE L6, v26.10.20)
#
# popcorn_demo is smalt's Chicago testbed: the pure-decision slice compiled to
# BEAM bytecode and run in-browser on the Popcorn WASM BEAM, against the live
# loopback substrate (receipt fragments live=, matrix=, blob=). Chain:
# popcorn-testbed-up → popcorn-cook → popcorn-smoke → live-gate court →
# host-side mix test. Per same-checkout-fanout law: shebang recipes use
# ROOT/POPCORN prefixed vars + {{POPCORN_ROOT}} interpolation; the module
# owns only these recipes — the root justfile gains one import line.

# justfile_directory() inside an imported module resolves to the ROOT justfile's
# dir (verified: parent_directory() overshot above the checkout) — house style per
# justfile.d/31-have.just.
POPCORN_ROOT := justfile_directory()
POPCORN_DIR := POPCORN_ROOT / "popcorn_demo"

# Pinned toolchain (packager exact-match enforced; see popcorn_demo/README.md)
# is exported inline in popcorn-cook. The asdf OTP bin dir goes FIRST — beware
# ~/.erlmcp/otp-28.3.1/bin shadowing erl on PATH.

# Substrate preflight: print status; if DOWN, bring it up (lock fd closed so
# beams do not inherit the flock — same-checkout-fanout law 4).
@popcorn-testbed-up:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{POPCORN_ROOT}}"
    echo "[POPCORN] substrate preflight"
    just substrate-status
    if just substrate-status 2>&1 | grep -qi "DOWN\|not running\|stopped"; then
        echo "[POPCORN] substrate DOWN — running substrate-up (lock fd closed)"
        9>&- just substrate-up
    else
        echo "[POPCORN] substrate already UP — no restart"
    fi

# Cook the pure-decision slice with the pinned toolchain: deps → compile →
# mix popcorn.cook --out-dir public/out.
@popcorn-cook:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
    cd "{{POPCORN_DIR}}"
    mix deps.get
    mix compile
    mix popcorn.cook --out-dir public/out

# In-browser ALIVE witness: headless Chromium against the live substrate.
# Exit contract: 0 = receipt with live=OK · 1 = live=FAIL/missing ·
# 3 = live=SKIP(substrate-down). Propagated unchanged.
@popcorn-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{POPCORN_DIR}}"
    exec node scripts/browser_smoke.mjs

# Full popcorn court: substrate preflight → cook → in-browser smoke →
# live-gate anti-vacuity court → host-side mix test (isolated build root).
# Any failing step fails the recipe.
@popcorn-court:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{POPCORN_ROOT}}"
    just popcorn-testbed-up
    just popcorn-cook
    just popcorn-smoke
    echo "[POPCORN-COURT] live-gate anti-vacuity court"
    bash scripts/live_gate_court.sh
    echo "[POPCORN-COURT] host-side mix test (MIX_BUILD_ROOT=_build-court)"
    cd popcorn_demo
    export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
    MIX_BUILD_ROOT=_build-court mix test

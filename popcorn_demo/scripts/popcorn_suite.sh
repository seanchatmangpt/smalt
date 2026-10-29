#!/usr/bin/env bash
# W2-13 — one-command popcorn suite (popcorn_demo/scripts/popcorn_suite.sh).
# Steps, each loud, continue-on-fail with a FAIL ledger; exit 0 iff all green:
#   1. substrate probe (http://127.0.0.1:9443/metadata/endpoints);
#      if down -> 9>&- just substrate-up from repo root, re-probe bounded.
#   2. compile popcorn_demo under MIX_BUILD_ROOT=_build-w213, pinned toolchain
#      (asdf elixir 1.20.3-otp-28 + OTP 28 bin first on PATH).
#   3. mix test (full popcorn_demo suite; substrate-dependent tests skip loudly).
#   4. browser witness node scripts/browser_smoke.mjs (SKIP if public/out not cooked).
#   5. bash scripts/live_gate_court.sh (repo-root scripts/).
# Final: PASS/FAIL table; suite exit = 0 iff every step green.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="${REPO_ROOT}/popcorn_demo"
SUBSTRATE_URL="http://127.0.0.1:9443/metadata/endpoints"

# Pinned toolchain: elixir 1.20.3-otp-28; OTP bin dir FIRST (erlmcp erl shadow hazard).
ELIXIR_DIR="$HOME/.asdf/installs/elixir/1.20.3-otp-28"
OTP28_DIR="$(ls -d "$HOME"/.asdf/installs/erlang/28* 2>/dev/null | sort -V | tail -1)"
export PATH="${OTP28_DIR}/bin:${ELIXIR_DIR}/bin:${PATH}"

# browser_smoke.mjs honors CHROMIUM_PATH; playwright cache may be incomplete.
if [ -z "${CHROMIUM_PATH:-}" ]; then
  CHROMIUM="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [ -x "$CHROMIUM" ] && export CHROMIUM_PATH="$CHROMIUM"
fi

declare -a STEPS=() RESULTS=() DETAILS=()
record() { # record <name> <PASS|FAIL|SKIP> <detail>
  STEPS+=("$1"); RESULTS+=("$2"); DETAILS+=("$3")
  printf '== [%s] %s: %s\n' "$1" "$2" "$3"
}
ledger=0
mark_fail() { ledger=$((ledger+1)); }

echo "######## POPCORN SUITE (W2-13) $(date -u +%FT%TZ) ########"

# ---- Step 1: substrate probe -------------------------------------------------
up=0
if curl -sf -m 3 "${SUBSTRATE_URL}" >/dev/null 2>&1; then
  up=1; record substrate PASS "probe 200 at ${SUBSTRATE_URL} (already up)"
else
  echo "== [substrate] down -> 9>&- just substrate-up (repo root)"
  (cd "${REPO_ROOT}" && 9>&- just substrate-up) > /tmp/popcorn-suite-substrate-up.log 2>&1 \
    || echo "   (substrate-up exited nonzero — see /tmp/popcorn-suite-substrate-up.log)"
  deadline=$((SECONDS+60))
  while [ $SECONDS -lt $deadline ]; do
    curl -sf -m 3 "${SUBSTRATE_URL}" >/dev/null 2>&1 && { up=1; break; }
    sleep 2  # SLEEP-CLASS: POLL-STEP (bounded poll on live observable)
  done
  if [ $up -eq 1 ]; then
    record substrate PASS "probe 200 after substrate-up (log: /tmp/popcorn-suite-substrate-up.log)"
  else
    record substrate FAIL "still down after substrate-up + 60s bounded poll"
    mark_fail
  fi
fi

# ---- Step 2: compile (MIX_BUILD_ROOT=_build-w213) ----------------------------
cd "${DEMO_DIR}"
if MIX_BUILD_ROOT=_build-w213 mix compile 2>&1 | tee /tmp/popcorn-suite-compile.log; then
  record compile PASS "mix compile OK (_build-w213, toolchain $(elixir -v 2>/dev/null | sed -n 2p))"
else
  record compile FAIL "mix compile failed — /tmp/popcorn-suite-compile.log"
  mark_fail
fi

# ---- Step 3: mix test (full suite) -------------------------------------------
if MIX_BUILD_ROOT=_build-w213 mix test 2>&1 | tee /tmp/popcorn-suite-test.log; then
  record test PASS "$(grep -E '[0-9]+ (tests|doctests)' /tmp/popcorn-suite-test.log | tail -1 | sed 's/^ *//')"
else
  record test FAIL "mix test failed — /tmp/popcorn-suite-test.log"
  mark_fail
fi

# ---- Step 4: browser witness (SKIP if public/out not cooked) ------------------
if [ -f public/out/index.mjs ] && [ -f public/out/beam.wasm ]; then
  if node scripts/browser_smoke.mjs 2>&1 | tee /tmp/popcorn-suite-smoke.log; then
    record browser_witness PASS "browser_smoke.mjs live=OK (see log tail)"
  else
    record browser_witness FAIL "browser_smoke.mjs failed — /tmp/popcorn-suite-smoke.log"
    mark_fail
  fi
else
  record browser_witness SKIP "public/out not cooked (no index.mjs/beam.wasm) — loud skip, run popcorn-cook"
fi

# ---- Step 5: live-gate court ---------------------------------------------------
if bash "${REPO_ROOT}/scripts/live_gate_court.sh" 2>&1 | tee /tmp/popcorn-suite-court.log; then
  record live_gate_court PASS "$(grep -E '^(PASS|SHIM\+AFTER|RESTORE)' /tmp/popcorn-suite-court.log | tail -1)"
else
  record live_gate_court FAIL "live_gate_court.sh failed — /tmp/popcorn-suite-court.log"
  mark_fail
fi

# ---- Final table ---------------------------------------------------------------
echo
echo "======== POPCORN SUITE RESULTS ========"
printf '%-18s %-6s %s\n' STEP RESULT DETAIL
rc=0
for i in "${!STEPS[@]}"; do
  printf '%-18s %-6s %s\n' "${STEPS[$i]}" "${RESULTS[$i]}" "${DETAILS[$i]}"
  [ "${RESULTS[$i]}" = "PASS" ] || rc=1
done
echo "======================================= (failed steps: ${ledger})"
exit $(( rc == 0 ? 0 : 1 ))

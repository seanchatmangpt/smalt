#!/usr/bin/env bash
# BK-42 — popcorn ratio-fence non-vacuity court.
# Falsifier: inject a SHIM-COURT mutation that breaks the paired-baseline
# wiring in popcorn_demo/test/empirical_kv_latency_test.exs (baseline_p99
# returns a bogus constant 1us) — the ratio fence MUST refuse (test exits
# nonzero). A fence that accepts the broken injection is VACUOUS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$ROOT/popcorn_demo/test/empirical_kv_latency_test.exs"
SNAP="/tmp/bk42-kv-latency.$$.exs"
BUILD="_build-bk42"

# toolchain: asdf-pinned elixir 1.20.4-otp-29 (mix.exs requires ~> 1.20)
export PATH="$(dirname "$(asdf which mix)"):$PATH"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
restore_fail() {
  cp "$SNAP" "$TARGET"
  [ "$(sha "$TARGET")" = "$(sha "$SNAP")" ] || { echo "RESTORE-FAIL"; exit 1; }
  echo "[RESTORE] sha256 $(sha "$TARGET") (byte-exact)"
}
trap restore_fail EXIT

echo "=== BASELINE ==="
SHA_BEFORE="$(sha "$TARGET")"
cp "$TARGET" "$SNAP"
echo "kv test sha256: $SHA_BEFORE"

echo "=== BEFORE (unshimmed fence must be green) ==="
cd "$ROOT/popcorn_demo"
BEFORE_RC=1
for ATTEMPT in 1 2 3 4 5 6 7 8 9 10; do
  set +e
  MIX_BUILD_ROOT=$BUILD mix test test/empirical_flag_latency_test.exs test/empirical_kv_latency_test.exs > "$ROOT/tmp/bk42-before.log" 2>&1
  BEFORE_RC=$?
  set -e
  tail -3 "$ROOT/tmp/bk42-before.log"
  echo "BEFORE attempt $ATTEMPT exit: $BEFORE_RC"
  [ "$BEFORE_RC" -eq 0 ] && break
  if [ "$ATTEMPT" -lt 10 ]; then
    echo "[RETRY] load-face flake class (BK-23/r240 warm-run-2 discipline) — attempt $((ATTEMPT+1)) in 60s"
    sleep 60
  fi
done
[ "$BEFORE_RC" -eq 0 ] || { echo "COURT-SKIP: BEFORE not green after 10 attempts — loud skip, not a fake pass"; exit 3; }

echo "=== SHIM (SHIM-COURT: break paired-baseline wiring) ==="
python3 - "$TARGET" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  defp baseline_p99 do\n"
assert s.count(old) == 1, "anchor not unique"
new = (
    "  # SHIM-COURT BK-42: broken baseline wiring — constant 1us baseline\n"
    "  defp baseline_p99 do 1 end\n"
    "  defp baseline_p99_shimmed_original do\n"
)
s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
grep -c "SHIM-COURT" "$TARGET"
SHA_SHIM="$(sha "$TARGET")"
echo "shimmed kv test sha256: $SHA_SHIM"

echo "=== AFTER (shimmed fence must REFUSE: exit nonzero) ==="
set +e
MIX_BUILD_ROOT=$BUILD mix test test/empirical_kv_latency_test.exs > "$ROOT/tmp/bk42-after.log" 2>&1
AFTER_RC=$?
tail -25 "$ROOT/tmp/bk42-after.log"
set -e
echo "AFTER exit: $AFTER_RC"

echo "=== RESTORE ==="
cp "$SNAP" "$TARGET"
[ "$(sha "$TARGET")" = "$SHA_BEFORE" ] || { echo "RESTORE-FAIL: sha mismatch"; exit 1; }
echo "[RESTORE] sha256 $(sha "$TARGET") (byte-exact)"

if [ "$AFTER_RC" -eq 0 ]; then
  echo "VACUOUS GATE: shimmed fence still passed — exit 1"
  exit 1
fi
echo "COURT PASS: fence REFUSED the mutation (exit $AFTER_RC), restore byte-exact"

#!/usr/bin/env bash
# publish_dry.sh — publish dry-run gate (DoD lane 08, v26.10.14).
# Productizes lane 11's packaging fix (receipts/11-publish-blockers.md):
# builds the hex tarball and gates it before any publish.
#
# Gates:
#   1. hex tarball builds (mix hex.build -o <out>, same as lane 11)
#   2. inner-tar grep: no signing.key / verifying.key / .ggen / keys/ in package
#      (tar -xzOf <tar> contents.tar.gz | tar -tz | grep -cE ... MUST be 0)
#   3. leak grep over the packaged set: athena / /Users/sac absolute paths
#      (docs/PUBLISH_CHECK.md section 2 / scripts/naming_sweep.sh pattern class)
#   4. docs/ERROR_CODES.md regen identity (gen_error_codes.py --check)
#
# Exit 0 only if all automatable gates pass. Signing-key ROTATION was
# EXECUTED 2026-10-15 (docs/jira/v26.10.14/receipts/rotate-signing-key.md);
# publication remains gated on final court-x2.
#
# Usage: scripts/publish_dry.sh [output.tar]   (default /tmp/hex-publish-dry/smalt.tar)

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

OUT="${1:-/tmp/hex-publish-dry/smalt.tar}"
mkdir -p "$(dirname "$OUT")"

INNER_KEY_PAT='signing.key|verifying.key|\.ggen|keys/'
LEAK_PAT='athena|/Users/sac'

FAIL=0

echo "== publish dry-run gate: $REPO =="
echo

# Gate 1+2: build + inner-tar key gate
echo "-- gate 1: mix hex.build -o $OUT"
if MIX_ENV=test mix hex.build -o "$OUT" >"$OUT.build.log" 2>&1; then
  echo "   PASS (tarball: $(wc -c <"$OUT" | tr -d ' ') bytes; log: $OUT.build.log)"
else
  echo "   FAIL — mix hex.build exited non-zero; tail of log:"
  tail -20 "$OUT.build.log" | sed 's/^/     /'
  FAIL=1
fi

echo
echo "-- gate 2: inner-tar key grep (pattern: $INNER_KEY_PAT)"
if [ -f "$OUT" ]; then
  INNER_HITS="$(tar -xzOf "$OUT" contents.tar.gz 2>/dev/null | tar -tz 2>/dev/null \
    | grep -E "$INNER_KEY_PAT")"
  INNER_COUNT="$(printf '%s' "$INNER_HITS" | grep -c . || true)"
  if [ "$INNER_COUNT" -eq 0 ]; then
    echo "   PASS (0 matches in contents.tar.gz listing)"
  else
    echo "   FAIL ($INNER_COUNT offending paths):"
    printf '%s\n' "$INNER_HITS" | sed 's/^/     /'
    FAIL=1
  fi
else
  echo "   SKIP (no tarball to inspect)"
  FAIL=1
fi

# Gate 3: leak grep over the packaged set (PUBLISH_CHECK 3a pattern class).
echo
echo "-- gate 3: packaged-set leak grep (pattern: $LEAK_PAT)"
if [ -f "$OUT" ]; then
  UNPACK="$OUT.unpacked"
  rm -rf "$UNPACK"
  mkdir -p "$UNPACK"
  tar -xzf "$OUT" -C "$UNPACK"
  tar -xzf "$UNPACK/contents.tar.gz" -C "$UNPACK"
  LEAK_HITS="$(grep -rnE "$LEAK_PAT" "$UNPACK" 2>/dev/null)"
  if [ -z "$LEAK_HITS" ]; then
    echo "   PASS (0 hits in packaged set at $UNPACK)"
  else
    echo "   FAIL — offending lines:"
    printf '%s\n' "$LEAK_HITS" | sed 's/^/     /'
    FAIL=1
  fi
else
  echo "   SKIP (no tarball to inspect)"
  FAIL=1
fi

# Gate 4: ERROR_CODES.md regen identity
echo
echo "-- gate 4: python3 scripts/gen_error_codes.py --check"
if CHECK_OUT="$(python3 scripts/gen_error_codes.py --check 2>&1)"; then
  echo "   PASS ($CHECK_OUT)"
else
  echo "   FAIL: $CHECK_OUT"
  FAIL=1
fi

# Summary
echo
echo "== summary =="
G1="[gate1 hex.build]"; G2="[gate2 inner-tar keys]"; G3="[gate3 leak grep]"; G4="[gate4 error-codes]"
if [ "$FAIL" -eq 0 ]; then
  echo "PASS $G1  PASS $G2  PASS $G3  PASS $G4"
else
  # Re-derive per-gate status is embedded above; summary marks the run FAIL.
  echo "FAIL (see per-gate lines above)"
fi
echo "publish released pending final court-x2 (rotation EXECUTED 2026-10-15)"

exit "$FAIL"

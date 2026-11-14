#!/usr/bin/env bash
# sigv4_court.sh — shim court: AWS SigV4 verify and the s3 scope claim are non-vacuous.
# Leg 1 shims Smalt.AWS.SigV4.verify/3 to always {:ok, akid}; leg 2 shims the s3 router
# to claim every SigV4 scope. BEFORE: test/aws green. AFTER: must go RED with real
# assertion failures (not a compile error). Green under shim => VACUOUS => FAIL.
# RESTORE is sha256 byte-exact (lib.sh); the self-check corrupts a restore on a real
# temp copy and proves detection. No mix toolchain => loud SKIP.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not installed"
export ROOT
export TESTS="test/aws"

BEFORE_CMD='cd "$ROOT" && MIX_ENV=test mix test $TESTS'
AFTER_CMD='cd "$ROOT"
if out=$(MIX_ENV=test mix test $TESTS 2>&1); then echo "VACUOUS: tests stayed green under shim"; exit 1; fi
echo "$out" | tail -25
if echo "$out" | grep -Eq "Compilation error|CompileError"; then echo "shim broke compile, not behavior"; exit 1; fi
echo "$out" | grep -Eq "[1-9][0-9]* failures?"'

shim_court_self_check

apply_shim() {
    SUBJECT_PATH="$SHIM_FILE" python3 - <<'PY'
import os, sys
p = os.environ["SUBJECT_PATH"]
s = open(p).read()
old = "if const_eq(expected, p.signature), do: {:ok, p.akid}, else: {:error, :mismatch}"
new = s.replace(old, "_ = const_eq(expected, p.signature)\n      {:ok, p.akid}  # SHIM-COURT: verify always :ok")
if new == s:
    sys.exit("shim anchor not found: sigv4.ex drifted")
open(p, "w").write(new)
PY
}
with_shim "$ROOT/lib/smalt/aws/sigv4.ex" "$BEFORE_CMD" "$AFTER_CMD"

apply_shim() {
    SUBJECT_PATH="$SHIM_FILE" python3 - <<'PY'
import os, sys
p = os.environ["SUBJECT_PATH"]
s = open(p).read()
old = '{:ok, %{service: "s3"}} -> conn |> serve(opts) |> halt()'
new = s.replace(old, '{:ok, _} -> conn |> serve(opts) |> halt()  # SHIM-COURT: scope claim widened', 1)
if new == s:
    sys.exit("shim anchor not found: s3_router.ex drifted")
open(p, "w").write(new)
PY
}
with_shim "$ROOT/lib/smalt/aws/s3_router.ex" "$BEFORE_CMD" "$AFTER_CMD"

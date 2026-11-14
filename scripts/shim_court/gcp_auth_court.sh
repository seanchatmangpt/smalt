#!/usr/bin/env bash
# gcp_auth_court.sh — shim court: GCP ya29 token signature verification is non-vacuous.
# Shim: Smalt.GCP.Identity.verify/1 trusts any parseable JWT (signature check skipped).
# BEFORE: test/gcp green. AFTER: must go RED with real failures (forged token refused
# assertions), not a compile error. Green under shim => VACUOUS => FAIL.
# RESTORE sha256 byte-exact; self-check proves restore detection. No mix => loud SKIP.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not installed"
export ROOT
export TESTS="test/gcp"

apply_shim() {
    SUBJECT_PATH="$SHIM_FILE" python3 - <<'PY'
import os, sys
p = os.environ["SUBJECT_PATH"]
s = open(p).read()
old = "{true, %JOSE.JWT{fields: f}, _} <- safe_verify(key(), jws),"
new = s.replace(old, "{_, %JOSE.JWT{fields: f}} <- {true, JOSE.JWT.peek_payload(jws)},  # SHIM-COURT: signature skipped")
if new == s:
    sys.exit("shim anchor not found: identity.ex drifted")
open(p, "w").write(new)
PY
}

BEFORE_CMD='cd "$ROOT" && MIX_ENV=test mix test $TESTS'
AFTER_CMD='cd "$ROOT"
if out=$(MIX_ENV=test mix test $TESTS 2>&1); then echo "VACUOUS: tests stayed green under shim"; exit 1; fi
echo "$out" | tail -25
if echo "$out" | grep -Eq "Compilation error|CompileError"; then echo "shim broke compile, not behavior"; exit 1; fi
echo "$out" | grep -Eq "[1-9][0-9]* failures?"'

shim_court_self_check
with_shim "$ROOT/lib/smalt/gcp/identity.ex" "$BEFORE_CMD" "$AFTER_CMD"

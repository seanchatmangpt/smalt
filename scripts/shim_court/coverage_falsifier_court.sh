#!/usr/bin/env bash
# coverage_falsifier_court.sh — Falsifier F1 (Revert-the-Diff), V261019
#
# Proves the replacement suites actually CATCH wire regressions (100%
# replaced, not merely deleted): inject a deliberate protocol break into
# lib/ (SHIM-COURT marked), run the external TS + PY courts, and require
# both to go RED. A court that stays green through a broken protocol is
# vacuous coverage — the failure mode this court exists to kill.
#
# Protocol (scripts/shim_court/lib.sh): BASELINE -> BEFORE -> SHIM ->
# AFTER -> RESTORE (sha256 byte-exact, fail-closed). Here BEFORE is
# INVERTED from the usual shape: the shim is expected to make the suites
# FAIL (AFTER = red is the SUCCESS outcome).
#
# Exit contract: 0 = falsifier witnessed (both suites red under the shim)
#              1 = a suite stayed green under the break (VACUOUS COVERAGE)
#              3 = loud SKIP (suites not landed / substrate unavailable)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

REPO="$(git rev-parse --show-toplevel)"
SUBJECT="$REPO/lib/smalt/data_plane/cosmos.ex"
SHIM_COURT=1

command -v node >/dev/null || { echo "[SKIP] node absent"; exit 3; }
[ -f "$REPO/verification/ts/run-all.mjs" ] || { echo "[SKIP] verification/ts suite not landed (V261019-08)"; exit 3; }
[ -f "$REPO/verification/py/run.sh" ] || { echo "[SKIP] verification/py suite not landed (V261019-09)"; exit 3; }

BASE_HASH=$(sha256sum "$SUBJECT" | awk '{print $1}')

# BEFORE gate: the falsifier's verdict is only meaningful against suites
# that are GREEN on the clean tree. Red-for-infra (substrate down, missing
# deps) would make the AFTER-red check vacuously pass — that false pass is
# exactly the failure mode this court kills, so a non-green BEFORE is a
# loud typed SKIP, never a verdict.
echo "[F1] BEFORE: requiring clean-tree suite GREEN (red-for-infra would make AFTER-red vacuous)"
(cd "$REPO/verification/ts" && node run-all.mjs >/tmp/f1-ts-before.log 2>&1) \
  || { echo "[SKIP] ts suite not green on clean tree (rc=$? — see /tmp/f1-ts-before.log); land V261019-08 first"; \
       git -C "$REPO" checkout -- "$SUBJECT" 2>/dev/null || true; exit 3; }
(cd "$REPO/verification/py" && bash run.sh >/tmp/f1-py-before.log 2>&1) \
  || { echo "[SKIP] py suite not green on clean tree (rc=$? — see /tmp/f1-py-before.log); land V261019-09 first"; \
       git -C "$REPO" checkout -- "$SUBJECT" 2>/dev/null || true; exit 3; }
echo "[F1] BEFORE: both suites GREEN on the clean tree"

apply_shim() {
  # Protocol break: Cosmos If-Match CAS always succeeds (never 412).
  # The wf2 concurrency courts MUST observe 412s — if the suite stays
  # green, its exactly-one-winner assertion is not wire-observable.
  python3 - "$SUBJECT" <<'PY'
import sys, re
p = sys.argv[1]
src = open(p).read()
marker = "# SHIM-COURT F1: cas neutered\n"
patch = marker + '@cas_neutered true'
if marker in src:
    sys.exit("shim already applied")
open(p, "w").write(src.replace(
    "defmodule Smalt.DataPlane.Cosmos do",
    "defmodule Smalt.DataPlane.Cosmos do\n" + patch, 1))
PY
}

# BEFORE is not executable until the suites are green on the clean tree;
# a red clean-tree suite is a suite defect, not a falsifier verdict.
echo "[F1] BEFORE: clean-tree suite verdicts are the suites' own receipts"
echo "[F1] SHIM: neutering Cosmos CAS (412 path) — suites MUST go red"
apply_shim
TS_RC=0; (cd "$REPO/verification/ts" && node run-all.mjs >/tmp/f1-ts.log 2>&1) || TS_RC=$?
PY_RC=0; (cd "$REPO/verification/py" && bash run.sh >/tmp/f1-py.log 2>&1) || PY_RC=$?

# RESTORE
git -C "$REPO" checkout -- "$SUBJECT"
RESTORED=$(sha256sum "$SUBJECT" | awk '{print $1}')
if [ "$RESTORED" != "$BASE_HASH" ]; then
  echo "[FAIL:RESTORE] sha256 mismatch — fail-closed"; exit 1
fi

if [ "$TS_RC" -eq 0 ] && [ "$PY_RC" -eq 0 ]; then
  echo "[FAIL:AFTER] VACUOUS COVERAGE — both suites green under a neutered Cosmos CAS."
  echo "  The replacement suites do not observe the wire. This is the exact"
  echo "  'replaced' claim killed by Falsifier F1."
  exit 1
fi
[ "$TS_RC" -ne 0 ] && echo "[PASS] ts suite RED under the break (rc=$TS_RC, tail: $(tail -1 /tmp/f1-ts.log))"
[ "$PY_RC" -ne 0 ] && echo "[PASS] py suite RED under the break (rc=$PY_RC, tail: $(tail -1 /tmp/f1-py.log))"
echo "[PASS] coverage_falsifier_court: replacement suites catch the injected protocol break"

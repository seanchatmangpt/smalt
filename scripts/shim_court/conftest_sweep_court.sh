#!/usr/bin/env bash
# conftest_sweep_court.sh — decoy-survival court for the py-conftest
# substrate-ctl delegation migration (HR-I lane, v26.11.6).
#
# Law under test: an incumbent substrate booted under a DIFFERENT operator
# env (marker env_pin mismatch) is a FOREIGN incumbent — the leasing lane
# must refuse (typed exit 3) and must NEVER sweep the incumbent. The
# pre-migration conftest's raw _sweep killed such a beam.
#
# BEFORE: the frozen pre-migration conftest (snapshotted at
# /tmp/hr-i/conftest_old.py) is imported directly and its _ensure_boot boots
# OVER a foreign-env beam on block v5 (kills it).
# AFTER: the migrated stack refuses rc=3 and the decoy beam SURVIVES.
# RESTORE: sha256 byte-exact on conftest.py, fail-closed.
# Exit: 0 PASS / 1 FAIL / 3 loud skip.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CTL="$REPO/scripts/substrate-ctl"
BLOCK="v5"
OLD_CONFTEST="/tmp/hr-i/conftest_old.py"
ORIG_SHA="$(shasum -a 256 "$REPO/verification/py/conftest.py" | cut -d' ' -f1)"
fail() { echo "[conftest-sweep-court] FAIL: $*" >&2; exit 1; }
cleanup() {
  "$CTL" down --block "$BLOCK" --mode sweep >/dev/null 2>&1 || true
  rm -f "$REPO/verification/py/conftest_old.py"
}
trap cleanup EXIT
cleanup
if [ ! -r "$OLD_CONFTEST" ]; then
  echo "[conftest-sweep-court] SKIP: $OLD_CONFTEST missing — loud skip" >&2
  exit 3
fi
# Freeze the old conftest INTO the py package dir so its REPO resolution
# (parents[2] of verification/py/conftest_old.py) is the real repo.
cp "$OLD_CONFTEST" "$REPO/verification/py/conftest_old.py"

echo "== BEFORE: old conftest _ensure_boot boots OVER a foreign-env beam =="
SMALT_SB_SHARED_KEY="decoy-key-hr-i-court-0001" "$CTL" up --block "$BLOCK" --auth enforce \
  >/tmp/hr-i/court-decoy-receipt.json 2>/tmp/hr-i/court-decoy.err
rc=$?
[ "$rc" -eq 0 ] || fail "decoy boot rc=$rc: $(tail -1 /tmp/hr-i/court-decoy.err)"
DECOY_PID="$(python3 -c 'import json;print(json.load(open("/tmp/hr-i/court-decoy-receipt.json"))["pid"])')"
kill -0 "$DECOY_PID" 2>/dev/null || fail "decoy pid dead right after boot"

( cd "$REPO/verification/py" && SMALT_SB_SHARED_KEY="court-key-different-9999" \
    "$REPO/verification/py/.venv/bin/python" - <<'PYEOF'
import sys
sys.path.insert(0, ".")
import conftest_old as C
proc, reused = C._ensure_boot(
    "/tmp/hr-i/court-mesg.lock", C.MESG_PORTS,
    C._mix_eval({"auth": "enforce",
                 "put_env": [("sb_shared_key", '"' + C.MESG_SB_KEY + '"')]},
                C.MESG_PORTS),
    "/tmp/hr-i/court-mesg.log", "/tmp/hr-i/court-mesg.boot.json")
print("old-conftest booted, reused=%s" % reused)
PYEOF
) >/tmp/hr-i/court-before.out 2>&1
grep -q "old-conftest booted" /tmp/hr-i/court-before.out \
  || fail "BEFORE: old conftest did not boot ($(tail -2 /tmp/hr-i/court-before.out | tr '\n' ' '))"
kill -0 "$DECOY_PID" 2>/dev/null \
  && fail "BEFORE: decoy SURVIVED the old sweep — court cannot flip (non-vacuity)"
echo "   old conftest booted over the decoy; decoy pid $DECOY_PID killed (BEFORE flip)"

echo "== AFTER: migrated stack refuses rc=3; decoy survives =="
SMALT_SB_SHARED_KEY="decoy-key-hr-i-court-0001" "$CTL" up --block "$BLOCK" --auth enforce \
  >/tmp/hr-i/court-decoy-receipt.json 2>/tmp/hr-i/court-decon := y.err
rc=$?
[ "$decon := 1" ]

echo "== AFTER: migrated stack refuses rc=3; decoy survives =="
SMALT_SB_SHARED_KEY="decoy-key-hr-i-court-0001" "$CTL" up --block "$BLOCK" --auth enforce \
  >/tmp/hr-i/court-decoy-receipt.json 2>/tmp/hr-i/court-decoy.err
rc=$?
[ "$rc" -eq 0 ] || fail "decoy boot2 rc=$rc"
DECOY_PID="$(python3 -c 'import json;print(json.load(open("/tmp/hr-i/court-decoy-receipt.json"))["pid"])')"
kill -0 "$DECOY_PID" 2>/dev/null || fail "decoy pid2 dead after boot"
( cd "$REPO/verification/py" && SMALT_SB_SHARED_KEY="court-key-different-9999" \
    "$REPO/verification/py/.venv/bin/python" - <<'PYEOF'
import sys
sys.path.insert(0, ".")
import conftest
try:
    conftest._ctl_up("v5", "enforce", {"SMALT_SB_SHARED_KEY": "court-key-different-9999"})
    print("AFTER-BOOTED")
except conftest.SbUpError as e:
    print("AFTER-REFUSED rc=%s" % e.rc)
PYEOF
) >/tmp/hr-i/court-after.out 2>&1
grep -q "AFTER-REFUSED rc=3" /tmp/hr-i/court-after.out || fail "AFTER: no rc=3 refusal ($(tail -2 /tmp/hr-i/court-after.out | tr '\n' ' '))"
kill -0 "$DECOY_PID" 2>/dev/null || fail "AFTER: decoy killed — survival law VIOLATED"
echo "   migrated stack refused rc=3; decoy pid $DECOY_PID SURVIVED"

[ "$(shasum -a 256 "$REPO/verification/py/conftest.py" | cut -d' ' -f1)" = "$ORIG_SHA" ] \
  || fail "conftest sha drifted during court run"
echo "[conftest-sweep-court] PASS (BEFORE: old sweep kills decoy; AFTER: rc=3 refusal, decoy survives)"
exit 0

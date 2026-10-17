#!/usr/bin/env zsh
# AMQP framing shim court (KD-21/KD-49) — proves the connection.ex shims are
# NON-VACUOUS: without them the real pyamqp client (azure-servicebus) fails at
# connect/attach; with them it completes a real send/receive roundtrip.
#
# DEFECT HISTORY (V5 verify lane, repaired R12): the old BEFORE leg stashed
# shims via `git show HEAD:` — once the shims LANDED at HEAD this mechanism
# broke (HEAD == shimmed → BLOCKED, or during the in-flight window a polluted
# BEFORE admitted the witness rc=0 both legs, with the client-side
# `TypeError('Target.__new__() takes from 1 to 8 positional arguments but 9
# were given')` dominating the leg outcome and masking which broker state the
# witness actually saw). Fix: pin a pristine pre-shim baseline file
# (amqp_connection_baseline.ex, from 518b31a, sha256-pinned below) and assert
# an EXPLICIT discriminating signature per leg:
#
#   LOCK    — the whole BASELINE→SHIM→AFTER→RESTORE window runs under an
#             exclusive flock on /tmp/smalt-shim-court-connection.ex.lock
#             (fd 9, same convention as disposition_token_court). No other
#             court may transiently overwrite connection.ex concurrently,
#             and a crash inside the window cannot strand a foreign snapshot
#             on the live tree unserialized.
#   LIVE-BASELINE RESTORE — the restore point is a temp snapshot of the
#             CURRENT live connection.ex taken under the lock at start
#             (not the pinned historical baseline). The court only ever
#             round-trips the live state it observed; the pinned pre-shim
#             file (amqp_connection_baseline.ex, sha-pinned) is used ONLY
#             for the BEFORE leg's historical unshimmed shape.
#   BEFORE  — copy the pinned pristine baseline into place, boot, run the
#             witness. The witness MUST FAIL (rc 1 or 3) AND its output MUST
#             match the recorded unshimmed signature set (wire-induced
#             IndexError / Invalid link / Target.__new__ TypeError /
#             WITNESS_TIMEOUT / ConnectionError / socket / AMQPError /
#             Detached). rc=0 on this leg is an immediate VACUOUS FAIL.
#   AFTER   — restore the shimmed bytes (sha256-verified vs the pre-court
#             snapshot), reboot, witness MUST SUCCEED (rc=0 AND "WITNESS_OK"
#             in output AND none of the failure signatures present).
#   RESTORE — final sha256 verification that connection.ex on disk is the
#             shimmed file byte-exact, plus the all-hunks assertion.
#
# ENVIRONMENT DEPENDENCY (documented per R12 directive, lib/ not edited here):
# `boot` compiles and starts the WHOLE :smalt application, so this court's
# runnability depends on the landed lib/ tree compiling. In-flight lanes'
# broken lib/ files (e.g. a transient TokenMissingError in data_plane/
# cosmos.ex during the v26.10.16 wave) make boot fail → exit 2 BLOCKED. The
# subject file connection.ex is content-frozen in this court (baseline +
# snapshot) so landed-vs-HEAD drift cannot pollute a leg.
#
# Exit codes: 0 = court NON-VACUOUS; 1 = vacuous/failed; 2 = BLOCKED (boot
# failed / ports held / venv missing / baseline drift, nothing faked).

set -u
set +e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CONN=lib/smalt/messaging/amqp/connection.ex
VENV=$REPO/test/sdk-python/.venv-sb/bin/python
WITNESS=$REPO/scripts/shim_court/amqp_witness.py
BASELINE=$REPO/scripts/shim_court/amqp_connection_baseline.ex
BASELINE_SHA=ea5a13708e87ccaf4244a8dce93d2ffd0636cc3c84624db46801ea44e2b651ae
LOCK=/tmp/smalt-shim-court-connection.ex.lock   # SHIM-COURT: serialize vs sibling courts (R-lane282)
TRACE_LOG=$REPO/test/sdk-python/.logs/pyamqp-attach-trace.log
LOG=/tmp/s1-amqp-shim-court_substrate.log
BEFORE_OUT=/tmp/s1-amqp-shim-court_before.out
AFTER_OUT=/tmp/s1-amqp-shim-court_after.out

# private port block (docs/how-to/dev-loop.md range 39000-39999)
AMQP_PORT=39382
EH_PORT=39383
ARM_PORT=39474
EGRESS_PORT=39475
ARM_TLS_PORT=39476

SUB_PID=""

cleanup() {
  if [ -n "$SUB_PID" ]; then
    kill -TERM -- -$SUB_PID 2>/dev/null || kill $SUB_PID 2>/dev/null
    sleep 1
    kill -KILL -- -$SUB_PID 2>/dev/null
  fi
  # RESTORE safety net: never leave the tree with a foreign snapshot on any
  # exit path — restore the LIVE state observed at court start, fail-closed.
  if [ -f "$LIVE_SNAP" ] && [ "$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)" != "$SHA_LIVE" ]; then
    cp "$LIVE_SNAP" "$REPO/$CONN"
    echo "[court] safety-net restore of live connection.ex applied"
  fi
}

port_held() {
  nc -z 127.0.0.1 "$1" 2>/dev/null
}

boot() {
  : > "$LOG"
  MIX_ENV=test mix run --no-start --no-halt -e "
Application.put_env(:smalt, :sb_shared_key, \"$SHARED_KEY\");
Application.put_env(:smalt, :sb_endpoint, \"sb://127.0.0.1:$AMQP_PORT\");
Application.put_env(:smalt, :amqp_port, $AMQP_PORT);
Application.put_env(:smalt, :event_hubs_port, $EH_PORT);
Application.put_env(:smalt, :arm_port, $ARM_PORT);
Application.put_env(:smalt, :egress_port, $EGRESS_PORT);
Application.put_env(:smalt, :arm_tls_port, $ARM_TLS_PORT);
{:ok, _} = Application.ensure_all_started(:smalt)" >>"$LOG" 2>&1 &
  SUB_PID=$!
  local up=0
  for i in $(seq 1 120); do
    if nc -z 127.0.0.1 $AMQP_PORT 2>/dev/null && nc -z 127.0.0.1 $EH_PORT 2>/dev/null \
       && nc -z 127.0.0.1 $EGRESS_PORT 2>/dev/null; then up=1; break; fi
    if ! kill -0 $SUB_PID 2>/dev/null; then break; fi
    sleep 1
  done
  if [ $up -ne 1 ]; then
    echo "BLOCKED: substrate never bound on $AMQP_PORT; log tail:" >&2
    tail -25 "$LOG" >&2
    cleanup
    exit 2
  fi
  echo "[court] substrate up (pid $SUB_PID) amqp=$AMQP_PORT arm=$ARM_PORT"
}

stop_broker() {
  if [ -n "$SUB_PID" ]; then
    kill -TERM -- -$SUB_PID 2>/dev/null || kill $SUB_PID 2>/dev/null
    for i in $(seq 1 20); do
      kill -0 $SUB_PID 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL -- -$SUB_PID 2>/dev/null
    wait $SUB_PID 2>/dev/null || true
    SUB_PID=""
  fi
  # wait for port release (a stale VM would poison the next phase)
  for i in $(seq 1 40); do
    port_held $AMQP_PORT || break
    sleep 0.5
  done
  if port_held $AMQP_PORT; then
    echo "BLOCKED: port $AMQP_PORT still held after stop; lsof -ti tcp:$AMQP_PORT | xargs kill -9" >&2
    exit 2
  fi
}

witness() {
  COURT_AMQP_PORT=$AMQP_PORT COURT_ARM_PORT=$ARM_PORT COURT_SB_KEY=$SHARED_KEY \
    "$VENV" "$WITNESS" >"$1" 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------
cd "$REPO" || exit 2
LIVE_SNAP=/tmp/s1-amqp-shim-court_conn_live.$$.ex
[ -x "$VENV" ] || { echo "BLOCKED: pyamqp venv missing: $VENV" >&2; exit 2; }
[ -f "$WITNESS" ] || { echo "BLOCKED: witness missing: $WITNESS" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "BLOCKED: pristine baseline missing: $BASELINE" >&2; exit 2; }

# pinned pristine baseline must be byte-exact (fail-closed on drift) —
# used ONLY as the BEFORE leg's historical unshimmed shape, never as the
# restore point.
SHA_BASE=$(shasum -a 256 "$BASELINE" | cut -d' ' -f1)
if [ "$SHA_BASE" != "$BASELINE_SHA" ]; then
  echo "BLOCKED: pristine baseline sha drift ($SHA_BASE != $BASELINE_SHA) — re-pin from 518b31a" >&2
  exit 2
fi
echo "[court] pristine baseline verified sha256=$SHA_BASE"

for p in $AMQP_PORT $EH_PORT $EGRESS_PORT; do
  if port_held $p; then
    echo "BLOCKED: port $p already held — choose a free block. lsof -ti tcp:$p" >&2
    exit 2
  fi
done

SHARED_KEY=$(head -c 48 /dev/urandom | base64)

# Whole-window self-serialization: exclusive flock on fd 9 for the entire
# BASELINE→SHIM→AFTER→RESTORE window (same convention as disposition_token_
# court). Inside the lock, snapshot the LIVE connection.ex — this snapshot,
# not the pinned historical baseline, is the restore point.
exec 9>"$LOCK"
flock -x 9 || { echo "BLOCKED: cannot acquire $LOCK" >&2; exit 2; }
echo "[court] lock held: $LOCK (fd 9)"

cp "$CONN" "$LIVE_SNAP"
SHA_LIVE=$(shasum -a 256 "$LIVE_SNAP" | cut -d' ' -f1)
echo "[court] live connection.ex snapshot sha256=$SHA_LIVE (restore point)"
if [ "$SHA_LIVE" = "$SHA_BASE" ]; then
  echo "BLOCKED: live connection.ex == pristine baseline; shims missing from subject" >&2
  exit 2
fi

trap cleanup EXIT INT TERM

VERDICT=1
WIT_RC=""
AFTER_RC=""

# ---------------------------------------------------------------------------
# BEFORE — install pristine baseline, witness the OLD failure signature
# ---------------------------------------------------------------------------
echo "== BEFORE: install pristine pre-shim baseline (sha-pinned) =="
cp "$BASELINE" "$REPO/$CONN"
SHA_ORIG=$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)
if [ "$SHA_ORIG" != "$SHA_BASE" ]; then
  echo "BLOCKED: baseline install sha mismatch" >&2
  exit 2
fi

boot
echo "== BEFORE: running pyamqp witness against UNSHIMMED broker =="
witness "$BEFORE_OUT"
WIT_RC=$?
stop_broker

# recorded unshimmed failure signatures (wire-induced client failures)
OLD_SIGS="IndexError|Invalid link|Target.__new__|WITNESS_TIMEOUT|ConnectionError|socket|AMQPError|Detached"
BEFORE_SIG_OK=0
if [ -s "$BEFORE_OUT" ] && grep -Eq "$OLD_SIGS" "$BEFORE_OUT"; then
  BEFORE_SIG_OK=1
fi

if [ $WIT_RC -eq 0 ]; then
  echo "FAIL: unshimmed broker ADMITTED the pyamqp witness (rc=0) — shim looks vacuous"
  echo "  witness output: $(tail -3 "$BEFORE_OUT" | tr '\n' ' ')"
  VERDICT=1
elif [ $BEFORE_SIG_OK -ne 1 ]; then
  echo "FAIL: unshimmed witness failed (rc=$WIT_RC) but NO recorded signature matched —"
  echo "  the leg outcome is dominated by an unregistered failure mode. Output tail:"
  tail -5 "$BEFORE_OUT"
  VERDICT=1
else
  SIG=$(grep -Eo "$OLD_SIGS" "$BEFORE_OUT" | head -1)
  echo "[BEFORE] live leg FAILED as expected (rc=$WIT_RC, signature: $SIG)"
  VERDICT=0_CANDIDATE
fi

# ---------------------------------------------------------------------------
# AFTER — restore shims (sha256 verified), witness success
# ---------------------------------------------------------------------------
echo "== AFTER: restore live connection.ex from live snapshot =="
cp "$LIVE_SNAP" "$REPO/$CONN"
SHA_NOW=$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)
if [ "$SHA_NOW" != "$SHA_LIVE" ]; then
  echo "BLOCKED: live-snapshot restore sha256 mismatch ($SHA_NOW != $SHA_LIVE)" >&2
  exit 2
fi
echo "[court] live restore verified byte-exact"

boot
echo "== AFTER: running pyamqp witness against SHIMMED broker =="
witness "$AFTER_OUT"
AFTER_RC=$?
stop_broker

AFTER_CLEAN=1
if grep -Eq "$OLD_SIGS" "$AFTER_OUT"; then
  echo "[AFTER] failure signature present in shimmed leg output:"
  grep -E "$OLD_SIGS" "$AFTER_OUT" | head -3
  AFTER_CLEAN=0
fi

if [ $AFTER_RC -eq 0 ] && [ $AFTER_CLEAN -eq 1 ] && grep -q "WITNESS_OK" "$AFTER_OUT"; then
  echo "[AFTER] witness connect + roundtrip SUCCEEDED (WITNESS_OK, no failure signatures)"
  [ "$VERDICT" = "0_CANDIDATE" ] && VERDICT=0
else
  echo "[AFTER] witness FAILED (rc=$AFTER_RC, clean=$AFTER_CLEAN) — shim does not fix the pyamqp tier"
  tail -5 "$AFTER_OUT"
  VERDICT=1
fi

# ---------------------------------------------------------------------------
# RESTORE — final byte-exact verification of the landing state
# ---------------------------------------------------------------------------
echo "== RESTORE: final sha256 verification of live connection.ex =="
SHA_FINAL=$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)
RESTORED_OK=0
if [ "$SHA_FINAL" = "$SHA_LIVE" ]; then
  RESTORED_OK=1
  echo "[court] connection.ex byte-exact vs live snapshot: OK"
fi

# Post-restore all-hunks assertion (coordinator directive): the restored
# landing file must carry every merged hunk (S-1 KD-21/49 + S-2 KD-18/19/20).
HUNKS_OK=1
for hunk in "KD-21 shim" "idle_time_out: idle" "KD-49 shim" "source: perf.source" \
            "target: perf.target" 'type: props\["type"\]' "message_format: 0" \
            "extract_body_section" "KD-COVERS: KD-21" "KD-COVERS: KD-49"; do
  grep -q "$hunk" "$REPO/$CONN" || { echo "POST-RESTORE HUNK MISSING: $hunk"; HUNKS_OK=0; }
done
if [ $HUNKS_OK -ne 1 ]; then
  echo "[court] post-restore hunk assertion FAILED — refusing to report success"
  RESTORED_OK=0
fi

echo
echo "==============================================================================="
echo "AMQP FRAMING SHIM COURT RECEIPT (subject: $CONN)"
echo "==============================================================================="
echo "BEFORE (unshimmed) : witness rc=$WIT_RC, signature: ${SIG:-none matched}"
echo "AFTER  (shimmed)   : witness rc=$AFTER_RC ($([ $AFTER_RC -eq 0 ] && echo SUCCESS || echo FAIL))"
echo "RESTORE sha256     : $([ $RESTORED_OK -eq 1 ] && echo OK || echo FAIL) ($SHA_FINAL vs live $SHA_LIVE)"
echo "before-leg output  : $BEFORE_OUT"
echo "after-leg output   : $AFTER_OUT"
echo "trace-log signature available: $([ -f "$TRACE_LOG" ] && echo yes || echo no)"
echo "==============================================================================="

if [ "$VERDICT" = "0" ] && [ $RESTORED_OK -eq 1 ] && [ $HUNKS_OK -eq 1 ]; then
  echo "VERDICT: NON-VACUOUS — unshimmed witness fails with the recorded signature, shimmed witness passes, restore byte-exact."
  rm -f "$LIVE_SNAP"
  exit 0
else
  echo "VERDICT: FAILED or VACUOUS — see phases above."
  rm -f "$LIVE_SNAP"
  exit 1
fi

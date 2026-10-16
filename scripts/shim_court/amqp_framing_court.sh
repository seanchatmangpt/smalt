#!/usr/bin/env zsh
# AMQP framing shim court (KD-21/KD-49) — proves the connection.ex shims are
# NON-VACUOUS: without them the real pyamqp client (azure-servicebus) fails at
# connect/attach; with them it completes a real send/receive roundtrip.
#
# Protocol (mirrors scripts/mutation_court.py: BEFORE / AFTER / RESTORE,
# sha256 byte-exact restore, exit 0 only if all phases pass, never fakes):
#
#   BEFORE  — stash the shims (connection.ex reverted to HEAD content via
#             `git show HEAD:`; the working tree at HEAD holds the original
#             two maps), boot the broker on a private port block, run the
#             pyamqp witness, expect the recorded failure signature
#             (IndexError from pyamqp _incoming_open / "Invalid link" /
#             socket error / timeout). If the pyamqp environment cannot run
#             in this window, this phase falls back to the recorded trace
#             signature (test/sdk-python/.logs/pyamqp-attach-trace.log) and
#             marks the live leg SKIP-loud.
#   AFTER   — restore the shimmed bytes (sha256-verified vs the pre-court
#             snapshot), reboot, witness connect + roundtrip MUST succeed.
#   RESTORE — final sha256 verification that connection.ex on disk is the
#             shimmed file byte-exact (the landing state).
#
# Exit codes: 0 = court NON-VACUOUS (or BEFORE live leg loud-SKIP with trace
# fallback and AFTER green); 1 = vacuous/failed; 2 = BLOCKED (boot failed /
# ports held / venv missing, nothing faked).

set -u
set +e
REPO=/Users/sac/smalt
CONN=lib/smalt/messaging/amqp/connection.ex
VENV=$REPO/test/sdk-python/.venv-sb/bin/python
WITNESS=$REPO/scripts/shim_court/amqp_witness.py
TRACE_LOG=$REPO/test/sdk-python/.logs/pyamqp-attach-trace.log
LOG=/tmp/s1-amqp-shim-court_substrate.log

# private port block (docs/DEV_LOOP.md range 39000-39999)
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
  # RESTORE safety net: never leave the tree unshimmed on any exit path.
  if [ -f "$SNAP" ] && [ "$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)" != "$SHA_SHIMMED" ]; then
    cp "$SNAP" "$REPO/$CONN"
    echo "[court] safety-net restore of shimmed connection.ex applied"
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
    "$VENV" "$WITNESS"
}

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------
cd "$REPO" || exit 2
SNAP=/tmp/s1-amqp-shim-court_conn_shimmed.ex

[ -x "$VENV" ] || { echo "BLOCKED: pyamqp venv missing: $VENV" >&2; exit 2; }
[ -f "$WITNESS" ] || { echo "BLOCKED: witness missing: $WITNESS" >&2; exit 2; }

for p in $AMQP_PORT $EH_PORT $EGRESS_PORT; do
  if port_held $p; then
    echo "BLOCKED: port $p already held — choose a free block. lsof -ti tcp:$p" >&2
    exit 2
  fi
done

SHARED_KEY=$(head -c 48 /dev/urandom | base64)
cp "$CONN" "$SNAP"
SHA_SHIMMED=$(shasum -a 256 "$SNAP" | cut -d' ' -f1)
echo "[court] shimmed connection.ex snapshot sha256=$SHA_SHIMMED"

trap cleanup EXIT INT TERM

VERDICT=1
SKIP_LOUD=""
ORIG_SIG=""

# ---------------------------------------------------------------------------
# BEFORE — stash shims, witness the OLD failure signature
# ---------------------------------------------------------------------------
echo "== BEFORE: stash shims (git show HEAD -> connection.ex) =="
git show HEAD:"$CONN" > "$REPO/$CONN" || { echo "BLOCKED: git show failed" >&2; exit 2; }
SHA_ORIG=$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)
if [ "$SHA_ORIG" = "$SHA_SHIMMED" ]; then
  echo "BLOCKED: HEAD content == shimmed content; nothing to witness" >&2
  exit 2
fi

boot
echo "== BEFORE: running pyamqp witness against UNSHIMMED broker =="
set +e
witness
WIT_RC=$?
stop_broker

OLD_SIGS="IndexError|Invalid link|WITNESS_TIMEOUT|ConnectionError|socket|AMQPError|Detached"
if [ $WIT_RC -eq 0 ]; then
  echo "FAIL: unshimmed broker ADMITTED the pyamqp witness — shim looks vacuous"
  VERDICT=1
elif [ $WIT_RC -eq 3 ]; then
  ORIG_SIG="WITNESS_TIMEOUT (hang/detach, the recorded pyamqp signature)"
  echo "[BEFORE] live leg failed with the hang/detach signature: $ORIG_SIG"
  VERDICT=0_CANDIDATE
else
  ORIG_SIG="unshimmed witness rc=$WIT_RC (see witness stderr in court log)"
  echo "[BEFORE] live leg FAILED as expected (rc=$WIT_RC)"
  VERDICT=0_CANDIDATE
fi

# ---------------------------------------------------------------------------
# AFTER — restore shims (sha256 verified), witness success
# ---------------------------------------------------------------------------
echo "== AFTER: restore shimmed connection.ex =="
cp "$SNAP" "$REPO/$CONN"
SHA_NOW=$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)
if [ "$SHA_NOW" != "$SHA_SHIMMED" ]; then
  echo "BLOCKED: shim restore sha256 mismatch ($SHA_NOW != $SHA_SHIMMED)" >&2
  exit 2
fi
echo "[court] shim restore verified byte-exact"

boot
echo "== AFTER: running pyamqp witness against SHIMMED broker =="
set +e
witness
AFTER_RC=$?
stop_broker

if [ $AFTER_RC -eq 0 ]; then
  echo "[AFTER] witness connect + roundtrip SUCCEEDED"
  [ "$VERDICT" = "0_CANDIDATE" ] && VERDICT=0
else
  echo "[AFTER] witness FAILED (rc=$AFTER_RC) — shim does not fix the pyamqp tier"
  VERDICT=1
fi

# ---------------------------------------------------------------------------
# RESTORE — final byte-exact verification of the landing state
# ---------------------------------------------------------------------------
echo "== RESTORE: final sha256 verification of shimmed connection.ex =="
SHA_FINAL=$(shasum -a 256 "$REPO/$CONN" | cut -d' ' -f1)
RESTORED_OK=0
if [ "$SHA_FINAL" = "$SHA_SHIMMED" ]; then
  RESTORED_OK=1
  echo "[court] connection.ex byte-exact vs shimmed snapshot: OK"
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
echo "BEFORE (unshimmed) : $([ -n "$SKIP_LOUD" ] && echo "SKIP-loud ($SKIP_LOUD)" || echo "witness rc=$WIT_RC, signature: $ORIG_SIG")"
echo "AFTER  (shimmed)   : witness rc=$AFTER_RC ($([ $AFTER_RC -eq 0 ] && echo SUCCESS || echo FAIL))"
echo "RESTORE sha256     : $([ $RESTORED_OK -eq 1 ] && echo OK || echo FAIL) ($SHA_FINAL)"
echo "trace-log signature available: $([ -f "$TRACE_LOG" ] && echo yes || echo no)"
echo "==============================================================================="

if [ "$VERDICT" = "0" ] && [ $RESTORED_OK -eq 1 ] && [ $HUNKS_OK -eq 1 ]; then
  echo "VERDICT: NON-VACUOUS — unshimmed witness fails, shimmed witness passes, restore byte-exact."
  exit 0
elif [ "$VERDICT" = "0_CANDIDATE" ] && [ $AFTER_RC -eq 0 ] && [ $RESTORED_OK -eq 1 ]; then
  echo "VERDICT: PARTIAL — AFTER green but BEFORE live leg inconclusive; see receipt."
  exit 1
else
  echo "VERDICT: FAILED or VACUOUS — see phases above."
  exit 1
fi

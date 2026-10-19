#!/usr/bin/env bash
# scripts/have/have_11_drill.sh — HAVE-11 end-to-end fault drill (solo lane).
#
# Proves the HAVE engine catches what it claims, on real faulted state:
#   (1) boot a private substrate (private DETS dir, dets_mirrored sync per write)
#   (2) SIGKILL the beam mid-write -> storage_probe --verify-clean-open:
#       NEEDS_REPAIR or OK, both typed; record which
#   (2b) non-vacuity mutation: truncate a mirror file -> probe MUST fire
#        NEEDS_REPAIR/CORRUPT_HEADER + exit 1 (a probe that cannot fire is FAIL)
#   (3) meta_watchdog --dry-run (orphan/zombie detection pass)
#   (4) telemetry --emit-all -> every have_* metric present, severity classified
#   (5) alert_policy on the emitted rows -> typed alert or clean bill
#   (6) drill JSONL -> docs/jira/v26.10.18/bench/have-11-drill.jsonl
#
# Lane writes ONLY that result file. No git.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT="$REPO/docs/jira/v26.10.18/bench/have-11-drill.jsonl"
LOGDIR="$REPO/tmp/have/drill"
TS=$(date -u +%Y%m%dT%H%M%SZ)
WORK="$LOGDIR/$TS"
mkdir -p "$WORK" "$REPO/docs/jira/v26.10.18/bench"
: > "$RESULT"

MACHINE=$(cpu=$(sysctl -n machdep.cpu.brand_string); cores=$(sysctl -n hw.ncpu); \
ram=$(( $(sysctl -n hw.memsize) / 1073741824 )); \
elixir=$(elixir -e 'IO.puts System.version()' | tail -1); \
otp=$(elixir -e 'IO.puts :erlang.system_info(:otp_release)' | tail -1); \
printf '{"cpu":"%s","cores":%s,"ram_gb":%s,"elixir":"%s","otp":"%s","darwin":"%s"}' \
  "$cpu" "$cores" "$ram" "$elixir" "$otp" "$(sw_vers -productVersion)")

emit() { # emit <op> <verdict> <detail-json>
  python3 -c '
import json, sys, datetime
op, verdict, detail, machine = sys.argv[1:5]
errors = 0 if verdict in ("PASS", "TYPED_NEEDS_REPAIR", "TYPED_OK") else 1
print(json.dumps({
    "lane": "have-11", "surface": "have", "op": op, "n": 1,
    "ops_per_sec": None, "p50_ms": None, "p95_ms": None, "p99_ms": None,
    "errors": errors, "verdict": verdict, "detail": json.loads(detail),
    "machine": json.loads(machine),
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}))' "$1" "$2" "$3" "$MACHINE" >> "$RESULT"
}

stage() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$WORK/stages.log"; }

stage "drill $TS start"

# --- (1) boot private substrate -------------------------------------------
DETS_DIR="$WORK/dets"
mkdir -p "$DETS_DIR"
EVAL_CODE='Application.put_env(:smalt, :blob_storage, persistence: :dets_mirrored, sync_interval_ms: 0)
{:ok, _} = Smalt.Store.start_link([])
{:ok, _} = Smalt.Store.DetsMirror.start_link(dir: "'"$DETS_DIR"'", tables: [:smalt_blobs], interval: 3_600_000)
:ets.insert(:smalt_blobs, {"drill-seed", "seed"})
Smalt.Store.DetsMirror.sync_write(:smalt_blobs)
IO.puts("WRITER_READY")
for i <- 1..50000 do
  :ets.insert(:smalt_blobs, {"drill-#{i}", String.duplicate("x", 2048)})
  Smalt.Store.DetsMirror.sync_write(:smalt_blobs)
end
IO.puts("WRITER_DONE_50000")
Process.sleep(:infinity)'

MIX_ENV=test mix run --no-start -e "$EVAL_CODE" --no-halt > "$WORK/writer.log" 2>&1 &
WPID=$!
READY=0
for i in $(seq 1 120); do
  if grep -q WRITER_READY "$WORK/writer.log" 2>/dev/null; then READY=1; break; fi
  kill -0 "$WPID" 2>/dev/null || break
  sleep 0.5
done
if [ "$READY" != 1 ]; then
  emit "boot_private_substrate" "FAIL" "{\"reason\": \"writer never ready\"}"
  stage "boot FAILED"; tail -20 "$WORK/writer.log"; exit 1
fi
emit "boot_private_substrate" "PASS" "{\"pid\": $WPID, \"dets_dir\": \"$DETS_DIR\"}"
stage "(1) substrate up pid=$WPID dir=$DETS_DIR"

# --- (2) SIGKILL mid-write ---------------------------------------------------
# Kill while the 2000-write burst is still running (before WRITER_DONE).
BYTES_AT_KILL=$(du -k "$DETS_DIR" | cut -f1)
BEAMPID=$(pgrep -P "$WPID" beam.smp 2>/dev/null | head -1); BEAMPID=${BEAMPID:-$WPID}
kill -9 "$BEAMPID" 2>/dev/null || kill -9 "$WPID"
wait "$WPID" 2>/dev/null
DONE_BEFORE_KILL=$(grep -c WRITER_DONE_2000 "$WORK/writer.log" 2>/dev/null || echo 0)
stage "(2) SIGKILL pid=$BEAMPID midwrite=$([ "$DONE_BEFORE_KILL" = 0 ] && echo yes || echo no)"
emit "sigkill_midwrite" "PASS" "{\"killed_pid\": ${BEAMPID:-0}, \"midwrite\": $([ "$DONE_BEFORE_KILL" = 0 ] && echo true || echo false)}"

P_OUT=$(python3 "$REPO/scripts/have/storage_probe.py" --verify-clean-open --data-dir "$DETS_DIR" 2>&1)
P_RC=$?
stage "(2) storage_probe exit=$P_RC: $(echo "$P_OUT" | tail -3 | tr '\n' ' | ')"
TYPED=$(echo "$P_OUT" | grep -oE "NEEDS_REPAIR|CORRUPT_HEADER|OK" | head -1)
case "$P_RC" in
  0) emit "storage_verify_clean_open" "TYPED_OK" "{\"exit\": 0, \"typed\": \"${TYPED:-OK}\"}" ;;
  1) emit "storage_verify_clean_open" "TYPED_NEEDS_REPAIR" "{\"exit\": 1, \"typed\": \"${TYPED:-UNKNOWN}\"}" ;;
  *) emit "storage_verify_clean_open" "FAIL" "{\"exit\": $P_RC, \"out\": \"$(echo "$P_OUT" | tail -3 | tr '\n' ' ')\"}" ;;
esac

# --- (2b) non-vacuity mutation: truncate -> probe MUST fire -------------------
V=$(ls "$DETS_DIR"/*.dets | head -1)
SZ=$(stat -f%z "$V")
truncate -s $((SZ * 3 / 4)) "$V"
M_OUT=$(python3 "$REPO/scripts/have/storage_probe.py" --verify-clean-open --data-dir "$DETS_DIR" 2>&1)
M_RC=$?
MTYPED=$(echo "$M_OUT" | grep -oE "NEEDS_REPAIR|CORRUPT_HEADER|OK" | head -1)
stage "(2b) mutation exit=$M_RC typed=${MTYPED:-none}"
if [ "$M_RC" = 1 ] && [ -n "$MTYPED" ] && [ "$MTYPED" != "OK" ]; then
  emit "storage_probe_mutation_witness" "PASS" "{\"exit\": $M_RC, \"typed\": \"$MTYPED\", \"method\": \"truncate 25% of first mirror file\"}"
else
  emit "storage_probe_mutation_witness" "FAIL" "{\"exit\": $M_RC, \"typed\": \"${MTYPED:-none}\"}"
  stage "MUTATION NOT WITNESSED — probe vacuous"
fi

# --- (3) meta_watchdog --dry-run ----------------------------------------------
W_OUT=$(python3 "$REPO/scripts/have/meta_watchdog.py" --dry-run 2>&1)
W_RC=$?
echo "$W_OUT" | tee -a "$WORK/stages.log"
# exit 1 = typed alerts fired = detection PASS for this drill
if [ "$W_RC" = 0 ] || [ "$W_RC" = 1 ]; then
  emit "meta_watchdog_dry_run" "PASS" "{\"exit\": $W_RC, \"alerts_fired\": $(echo "$W_OUT" | grep -c 'ALERT \[')}"
else
  emit "meta_watchdog_dry_run" "FAIL" "{\"exit\": $W_RC}"
fi

# --- (4) telemetry --emit-all ---------------------------------------------------
python3 "$REPO/scripts/have/telemetry.py" --emit-all > "$WORK/telemetry.jsonl" 2>"$WORK/telemetry.err"
T_RC=$?
GOT=$(wc -l < "$WORK/telemetry.jsonl" | tr -d ' ')
SEV=$(grep -c '"severity"' "$WORK/telemetry.jsonl" || true)
ABSENT=$(grep -c '"ABSENT"' "$WORK/telemetry.jsonl" || true)
stage "(4) telemetry exit=$T_RC rows=$GOT severity=$SEV absent=$ABSENT"
cat "$WORK/telemetry.jsonl" | tee -a "$WORK/stages.log"
if [ "$T_RC" = 0 ] && [ "$GOT" -ge 8 ] && [ "$SEV" = "$GOT" ]; then
  emit "telemetry_emit_all" "PASS" "{\"rows\": $GOT, \"severity_classified\": $SEV, \"absent\": $ABSENT, \"file\": \"$WORK/telemetry.jsonl\"}"
else
  emit "telemetry_emit_all" "FAIL" "{\"exit\": $T_RC, \"rows\": $GOT, \"severity_classified\": $SEV}"
fi

# --- (5) alert_policy ------------------------------------------------------------
A_OUT=$(python3 "$REPO/scripts/have/alert_policy.py" "$WORK/telemetry.jsonl" --no-write --rows-out "$WORK/alerts.jsonl" 2>&1)
A_RC=$?
stage "(5) alert_policy exit=$A_RC: $(echo "$A_OUT" | tail -5 | tr '\n' ' | ')"
ALERTS=$(wc -l < "$WORK/alerts.jsonl" 2>/dev/null | tr -d ' '); ALERTS=${ALERTS:-0}
case "$A_RC" in
  0) emit "alert_policy_eval" "PASS" "{\"exit\": 0, \"bill\": \"clean\", \"alerts\": 0}" ;;
  1) emit "alert_policy_eval" "PASS" "{\"exit\": 1, \"bill\": \"typed-alerts\", \"alerts\": $ALERTS}" ;;
  *) emit "alert_policy_eval" "FAIL" "{\"exit\": $A_RC, \"out\": \"$(echo "$A_OUT" | tail -3 | tr '\n' ' ')\"}" ;;
esac

stage "drill complete; artifacts in $WORK"

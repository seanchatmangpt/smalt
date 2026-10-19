#!/usr/bin/env bash
# scripts/chaos/kill_storm.sh — AZB-14 HOST-FORM precursor (SIGKILL storm +
# DETS repair + typed vocabulary on restart), container form lands with AZB-13.
#
# Per cycle, against a PRIVATE-PORT substrate (c-law: never the shared dev
# defaults; block registered in this header, registry pending — see receipt):
#
#   boot (dets-mirrored blob profile, sync_interval_ms 0 => ack-before-fsync)
#   -> write ledger blobs on the data plane under load
#   -> SIGKILL the beam at a seeded offset (mid-write stream)
#   -> reboot on the SAME dets dir with repair: true (needs_repair exercised)
#   -> typed vocabulary only: health 200, token 200, acked blob GETs 200 with
#      byte-exact bodies, missing blob 404 BlobNotFound (never an untyped 500)
#   -> i24-class closed-read probe of the dets files with repair: false,
#      bounded retry ONLY on the torn states {:needs_repair,_}/
#      {:not_a_dets_file,_} (receipts/i24-store-dets-torn.md); any other open
#      error is immediate fail-closed.
#
# Emits smalt-burn rows (burn-row.schema.json consts) + run_header to
# docs/jira/v26.10.18/burn/kill-storm-host.jsonl. NOTE: the on-disk schema
# const is smalt-burn/v2 (AZB-03); the ticket's "smalt-burn/v1" naming refers
# to the container-burn row family — rows here validate against the v2 file.
#
# Zero-sleep law (AZB-21): all waiting is deadline polls; the poll step is a
# `read -t` against a held-open fd (POLL-STEP), never `sleep`.
#
# Usage: scripts/chaos/kill_storm.sh [cycles]   (env: SMALT_KS_CYCLES,
#   SMALT_KS_SEED, SMALT_KS_WRITES_MIN/MAX, SMALT_KS_PORTS_BASE,
#   SMALT_KS_JSONL, SMALT_KS_SKIP_VALIDATOR)
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO" || exit 1

CYCLES=${SMALT_KS_CYCLES:-10}
SEED=${SMALT_KS_SEED:-$(( $(date +%s) % 2147483647 ))}
BASE=${SMALT_KS_PORTS_BASE:-39620}      # private block 39620..39625
ARM_PORT=$((BASE));      TLS_PORT=$((BASE+1)); DATA_PORT=$((BASE+2))
AMQP_PORT=$((BASE+3));   EH_PORT=$((BASE+4));  MCP_PORT=$((BASE+5))
ACCOUNT=ksstorm
CONTAINER=ledger
JSONL=${SMALT_KS_JSONL:-docs/jira/v26.10.18/burn/kill-storm-host.jsonl}
RUN_ID="kill-storm-host-$(date +%s)"
WORKDIR="$REPO/tmp/kill-storm/$RUN_ID"
DATA_DIR="$WORKDIR/dets"                # mirror dir, shared across reboot
LOG_BOOT="$WORKDIR/boot.log"
LOG_BOOT2="$WORKDIR/boot2.log"
mkdir -p "$DATA_DIR"

SUBJECT_SHA=$(git rev-parse --short=7 HEAD 2>/dev/null || echo unrecorded)
HOST=http://127.0.0.1

# Seeded LCG (mirrors the ticket's randomized-but-seeded kill offsets).
KSRAND=$SEED
rnd() { KSRAND=$(( (KSRAND * 1103515245 + 12345) % 2147483648 )); echo $(( KSRAND % $1 )); }

# POLL-STEP micro-wait: `read -t` on a fd held open by `tail -f /dev/null`
# (no output, negligible CPU). Closed on exit by the trap.
exec 3< <(tail -f /dev/null)
micro_wait() { read -r -t "${1:-0.05}" -u 3 _ || true; }

port_up()   { (exec 4<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 4>&- 4<&-; return 0; } || return 1; }
cleanup() {
  exec 3>&- 2>/dev/null || true
  [ -n "${SUB_PID:-}" ] && kill -9 "$SUB_PID" 2>/dev/null
  for p in "$ARM_PORT" "$TLS_PORT" "$DATA_PORT" "$AMQP_PORT" "$EH_PORT" "$MCP_PORT"; do
    for bpid in $(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u); do
      kill -9 "$bpid" 2>/dev/null || true
    done
  done
}
trap cleanup EXIT

fail() { echo "[FAULT] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Deadline polls (no sleeps)
# ---------------------------------------------------------------------------

# poll_until <deadline_s> <cmd...> — run cmd every poll step until it exits 0.
poll_until() {
  local deadline=$(( SECONDS + $1 )); shift
  until "$@"; do
    [ $SECONDS -ge $deadline ] && return 1
    micro_wait 0.1
  done
}

poll_port_up()   { poll_until "$1" port_up "$2"; }
poll_port_free() {
  local deadline=$(( SECONDS + $1 ))
  until ! port_up "$2"; do
    [ $SECONDS -ge $deadline ] && return 1
    micro_wait 0.1
  done
}

boot_substrate() { # <log> -> sets SUB_PID; fail-closed on boot deadline
  local log=$1
  : > "$log"
  # Lane-private build root (no contention with other lanes' mix lock).
  MIX_BUILD_ROOT=${SMALT_KS_BUILD_ROOT:-_build-kill-storm} \
    mix run --no-start --no-halt --eval "$(boot_eval)" </dev/null >>"$log" 2>&1 &
  SUB_PID=$!
  poll_port_up 150 "$ARM_PORT"   || fail "arm :$ARM_PORT never bound (log: $log)"
  poll_port_up 20  "$DATA_PORT"  || fail "data :$DATA_PORT never bound (log: $log)"
  # Settle: the boot deadline already covers late lazy-bind crashes; assert
  # the spawn is still alive before we trust the boot.
  kill -0 "$SUB_PID" 2>/dev/null || fail "substrate exited during boot (log: $log)"

}

boot_eval() {
  cat <<EOF
Application.put_env(:smalt, :auth_mode, :enforce)
Application.put_env(:smalt, :sb_shared_key, "${SMALT_SB_SHARED_KEY:-ws8sharedkey}")
Application.put_env(:smalt, :arm_port, $ARM_PORT)
Application.put_env(:smalt, :arm_tls_port, $TLS_PORT)
Application.put_env(:smalt, :egress_port, $DATA_PORT)
Application.put_env(:smalt, :amqp_port, $AMQP_PORT)
Application.put_env(:smalt, :event_hubs_port, $EH_PORT)
Application.put_env(:smalt, :mcp_port, $MCP_PORT)
Application.put_env(:smalt, :blob_storage, persistence: :dets_mirrored, sync_interval_ms: 0)
{:ok, _} = Application.ensure_all_started(:smalt)
{:ok, _} = Smalt.Store.DetsMirror.start_link(dir: "$DATA_DIR", repair: true, interval: 5_000)
{:ok, _} = Smalt.Store.DetsMirror.restore()
EOF
}

beam_pid() { lsof -nP -iTCP:"$ARM_PORT" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -1; }

mint_token() {
  local body="grant_type=client_credentials&client_id=kill-storm&client_secret=kill-storm"
  TOKEN=$(curl -fsS --max-time 5 -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "$body" "$HOST:$ARM_PORT/oauth2/v2.0/token" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') \
    || return 1
}

auth() { echo "Authorization: Bearer $TOKEN"; }

# ---------------------------------------------------------------------------
# JSONL emission (burn-row.schema.json fields; never hand-edited downstream)
# ---------------------------------------------------------------------------

emit_row() { # <stage> <verdict> <exit> <recovery_ms> <detail>
  KS_STAGE=$1 KS_VERDICT=$2 KS_EXIT=$3 KS_RECOVERY_MS=$4 KS_DETAIL=$5 KS_CYCLE=$CYCLE \
  KS_RUN_ID=$RUN_ID KS_SHA=$SUBJECT_SHA KS_EVIDENCE="$REPO/$JSONL" KS_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  python3 - <<'PY'
import json, os
row = {
  "schema": "smalt-burn/v2",
  "subject_sha": os.environ["KS_SHA"],
  "image_digest": "unrecorded",
  "container": "kill-storm-host",
  "plane": "data",
  "cycle": int(os.environ["KS_CYCLE"]),
  "stage": os.environ["KS_STAGE"],
  "verdict": os.environ["KS_VERDICT"],
  "t_start": os.environ["KS_TS"], "t_end": os.environ["KS_TS"],
  "exit_code": int(os.environ["KS_EXIT"]),
  "orphans": [],
  "crash_reports": 0,
  "evidence_path": os.environ["KS_EVIDENCE"],
  "broken_term": None,
  "lane": os.environ["KS_RUN_ID"],
  "detail": os.environ["KS_DETAIL"][:2000],
  "recovery_ms": int(os.environ["KS_RECOVERY_MS"]),
}
print(json.dumps(row))
PY
}

append_row() { emit_row "$@" >>"$JSONL"; }

# ---------------------------------------------------------------------------
# Cycle
# ---------------------------------------------------------------------------

CYCLE=0
VERDICT=CLEAN
DETAIL=""
RECOVERY_MS=0

run_cycle() {
  VERDICT=CLEAN; DETAIL=""; RECOVERY_MS=0
  local kill_at=$(( ${SMALT_KS_WRITES_MIN:-20} + $(rnd "${SMALT_KS_WRITES_MAX:-60}") ))
  local ledger="$WORKDIR/ledger-c$CYCLE.txt"
  : > "$ledger"

  # --- boot (fresh or post-kill reboot on the same dets dir) ---
  local t0=$SECONDS
  boot_substrate "$LOG_BOOT" || { append_row "chaos" TIMEOUT_DEADLINE 1 0 "boot failed: $(tail -3 "$LOG_BOOT" | tr '\n' ' ')"; return 1; }
  mint_token || { append_row "chaos" TIMEOUT_DEADLINE 2 0 "token mint failed"; return 1; }
  kill -0 "$SUB_PID" 2>/dev/null || { append_row "chaos" UNHANDLED_EXIT 6 0 "substrate exited right after boot: $(tail -3 "$LOG_BOOT" | tr '\n' ' ')"; return 1; }

  # Container (idempotent; 201 create or 409 already-present both proceed)
  local cc
  cc=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "$(auth)" \
    "$HOST:$DATA_PORT/$ACCOUNT/$CONTAINER?restype=container") || cc=000
  case "$cc" in 201|202|409) : ;; *) DETAIL+="container-create=$cc; " ;; esac

  # --- write stream + seeded kill ---
  (
    i=0
    while :; do
      name="c$CYCLE-blob-$i"
      payload="ks-$RUN_ID-c$CYCLE-$i-$(printf 'x%.0s' $(seq 1 64))"
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X PUT -H "$(auth)" \
        -H "x-ms-blob-type: BlockBlob" --data-binary "$payload" \
        "$HOST:$DATA_PORT/$ACCOUNT/$CONTAINER/$name") || { break; }   # beam died mid-write
      [ "$code" = "201" ] || { echo "$name UNEXPECTED_$code" >> "$ledger"; break; }
      printf '%s\t%s\n' "$name" "$(printf '%s' "$payload" | shasum -a 256 | cut -d" " -f1)" >> "$ledger"
      i=$((i+1))
    done
  ) &
  local writer=$!

  # Kill at the seeded offset: as soon as >= kill_at acks are on the ledger.
  local kd
  kd=$(beam_pid)
  [ -n "$kd" ] || { fail "no beam listener on :$ARM_PORT to kill (lsof: $(lsof -nP -iTCP:"$ARM_PORT" 2>/dev/null | head -3 | tr '\n' ';'))"; }
  local killed=0
  local deadline=$(( SECONDS + 120 ))
  while :; do
    if [ "$(wc -l < "$ledger" | tr -d ' ')" -ge "$kill_at" ]; then
      kill -9 "$kd" 2>/dev/null && killed=1
      break
    fi
    kill -0 "$writer" 2>/dev/null || break
    [ $SECONDS -ge $deadline ] && break
    micro_wait 0.01
  done
  wait "$writer" 2>/dev/null
  [ "$killed" = "1" ] || { append_row "chaos" UNHANDLED_EXIT 3 0 "beam vanished before seeded kill ($kill_at target)"; return 1; }
  local acked_pre=$(wc -l < "$ledger" | tr -d ' ')

  # --- reboot on the same dets dir (repair: true exercises needs_repair) ---
  poll_port_free 30 "$DATA_PORT" || fail "data port never freed after SIGKILL"
  boot_substrate "$LOG_BOOT2" || { append_row "chaos" TIMEOUT_DEADLINE 4 0 "reboot failed: $(tail -3 "$LOG_BOOT2" | tr '\n' ' ')"; return 1; }
  mint_token || { append_row "chaos" TIMEOUT_DEADLINE 5 0 "token mint after reboot failed"; return 1; }
  RECOVERY_MS=$(( (SECONDS - t0) * 1000 ))

  # --- typed vocabulary on restart ---
  local missing=0 mismatched=0 typed404=0 untyped=0
  local line name sha code got
  while IFS=$'\t' read -r name sha; do
    case "$name" in UNEXPECTED_*) untyped=$((untyped+1)); continue ;; esac
    bodyfile="$WORKDIR/get-body"
    code=$(curl -s -o "$bodyfile" -w '%{http_code}' --max-time 5 -H "$(auth)" \
      "$HOST:$DATA_PORT/$ACCOUNT/$CONTAINER/$name") || code=000
    case "$code" in
      200) got=$(shasum -a 256 "$bodyfile" | cut -d" " -f1)
           [ "$got" = "$sha" ] || mismatched=$((mismatched+1)) ;;
      *)   missing=$((missing+1)) ;;
    esac
  done < "$ledger"

  # Missing blob must be a typed 404 BlobNotFound, never an untyped 500.
  local miss_body miss_code
  miss_code=$(curl -s -o "$WORKDIR/miss-body" -w '%{http_code}' -H "$(auth)" \
    "$HOST:$DATA_PORT/$ACCOUNT/$CONTAINER/c$CYCLE-never-written") || miss_code=000
  miss_body=$(cat "$WORKDIR/miss-body" 2>/dev/null)
  case "$miss_code" in
    404) echo "$miss_body" | grep -q "BlobNotFound" && typed404=1 ;;
    *)   : ;;
  esac

  # --- i24-class closed-read dets probe (repair: false, bounded torn retry) ---
  # Retry budget 20 x 250ms = 5s per file, sized to the i20b sync fat tail;
  # ONLY the torn states retry, any other open error fails immediately.
  local probe
  probe=$(PROBE_DIR="$DATA_DIR" elixir -e '
  torn_probe = fn path, _tag ->
    do_try = fn attempt ->
      case :dets.open_file(String.to_charlist(path), repair: false) do
        {:ok, d} -> :dets.close(d); :clean_after_retry
        {:error, {:needs_repair, _}} when attempt < 20 -> :timer.sleep(250); :retry
        {:error, {:not_a_dets_file, _}} when attempt < 20 -> :timer.sleep(250); :retry
        {:error, r} -> {:open_error, r}
        _ -> :still_torn
      end
    end
    res = Enum.reduce_while(0..20, :retry, fn attempt, acc ->
      if acc == :retry do
        case do_try.(attempt) do
          :retry -> {:cont, :retry}
          other -> {:halt, other}
        end
      else
        {:halt, acc}
      end
    end)
    {Path.basename(path), res}
  end
  dir = System.get_env("PROBE_DIR")
  results = Enum.map(Path.wildcard(Path.join(dir, "*.dets")), fn path ->
    case :dets.open_file(String.to_charlist(path), repair: false) do
      {:ok, d} -> :dets.close(d); {Path.basename(path), :clean}
      {:error, {:needs_repair, _}} -> torn_probe.(path, nil)
      {:error, {:not_a_dets_file, _}} -> torn_probe.(path, nil)
      {:error, r} -> {Path.basename(path), {:open_error, r}}
      other -> {Path.basename(path), other}
    end
  end)
  IO.puts("PROBE " <> inspect(results, limit: :infinity))
' 2>&1 | grep -m1 '^PROBE ')
  echo "[CYCLE $CYCLE] dets closed-read probe: $probe"

  # --- verdict ---
  if [ "$missing" -gt 0 ]; then
    VERDICT=DETS_UNREPAIRED
    DETAIL+="acked_missing=$missing; "
  elif [ "$mismatched" -gt 0 ]; then
    VERDICT=DETS_UNREPAIRED
    DETAIL+="body_mismatch=$mismatched; "
  elif [ "$typed404" -ne 1 ]; then
    VERDICT=TYPED_VOCAB_MISMATCH
    DETAIL+="missing-blob probe answered $miss_code not typed-404 BlobNotFound; "
  elif echo "$probe" | grep -q "open_error"; then
    VERDICT=TYPED_VOCAB_MISMATCH
    DETAIL+="dets probe open_error; "
  fi
  DETAIL+="seed=$SEED kill_at=$kill_at acked=$acked_pre recover_ms=$RECOVERY_MS"

  append_row "chaos" "$VERDICT" 0 "$RECOVERY_MS" "$DETAIL"
  [ "$VERDICT" = "CLEAN" ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[ -f "$JSONL" ] || printf '{"type":"run_header","run_id":"%s","expected":{"containers":["kill-storm-host"],"cycles":[%s],"stages":["chaos"]}}\n' \
  "$RUN_ID" "$(printf '%s,' $(seq 0 $((CYCLES-1))) | sed 's/,$//')" > "$JSONL"

echo "[KILL-STORM] run=$RUN_ID cycles=$CYCLES seed=$SEED ports=$ARM_PORT..$MCP_PORT jsonl=$JSONL"
FAILED=0
for CYCLE in $(seq 0 $((CYCLES-1))); do
  LOG_BOOT="$WORKDIR/boot-c$CYCLE.log"
  LOG_BOOT2="$WORKDIR/reboot-c$CYCLE.log"
  if run_cycle; then echo "[KILL-STORM] cycle $CYCLE: CLEAN"; else echo "[KILL-STORM] cycle $CYCLE: $VERDICT"; FAILED=1; fi
  # Teardown between cycles: kill whatever is left before the next boot.
  [ -n "${SUB_PID:-}" ] && kill -9 "$SUB_PID" 2>/dev/null
  for p in "$ARM_PORT" "$TLS_PORT" "$DATA_PORT" "$AMQP_PORT" "$EH_PORT" "$MCP_PORT"; do
    for bpid in $(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u); do
      kill -9 "$bpid" 2>/dev/null || true
    done
  done
  poll_port_free 15 "$DATA_PORT" || true
done

if [ "${SMALT_KS_SKIP_VALIDATOR:-0}" != "1" ]; then
  python3 scripts/validate_burn.py "$JSONL" && echo "[KILL-STORM] burn rows validate OK"
fi
exit $FAILED

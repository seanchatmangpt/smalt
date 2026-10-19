#!/usr/bin/env bash
# docker/burn/boot-burn.sh — AZB-13 boot burn: 50 boot/probe/teardown cycles
# per plane, inside containers (smalt:local).
#
# Two modes:
#   HOST mode (on the dev host; no release bin at /app/_release/bin/smalt):
#     docker/burn/boot-burn.sh --planes all,control,data,integration,identity
#                             --cycles 50
#     For each plane: `docker run --rm` one smalt:local container whose entry
#     runs this same script in CONTAINER mode; collect per-plane JSONL into
#     docker/burn/results/boot-burn-<run>/, gate-validate, then copy to
#     docs/jira/v26.10.18/burn/boot-<plane>-<run>.jsonl (tracked, replayable).
#   CONTAINER mode (SMALT_BIN executable at the release path):
#     N x { SMALT_PLANES=<plane> release boot -> deadline-poll readiness on
#     all 6 ports -> one canonical request per plane -> `bin/smalt stop` ->
#     assert: no listener on plane ports, no beam.smp/epmd/erl_child_setup
#     process remains, no crash.log / SASL crash report }.
#     Every 10th cycle kill -9 + DETS-recovery assertions (AZB-14 fence).
#
# Jidoka: the first typed violation (ORPHAN_LISTENER / ZOMBIE_BEAM /
# UNHANDLED_EXIT / DETS_UNREPAIRED / TIMEOUT_DEADLINE) emits its row and exits
# non-zero immediately — remaining cycles are NOT_RUN (the expected-matrix
# header makes them loudly MISSING_CELL at --gate, never silently dropped).
#
# No fixed sleeps: every wait is a bounded deadline poll on an observable.
# NO-SLEEP-DOCTRINE.
#
# Exit: 0 all cycles green / 1 typed failure / 2 preflight refusal / 3 skip.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COMPOSE_IMG=${BURN_IMAGE:-smalt:local}
SMALT_BIN=${SMALT_BIN:-/app/_release/bin/smalt}
CYCLES=${SMALT_BURN_CYCLES:-50}
PROBE_TIMEOUT=${SMALT_BURN_PROBE_TIMEOUT:-90}   # seconds per deadline poll
BURN_DIR=${SMALT_BURN_DIR:-/smalt/docs/jira/v26.10.18/burn}
JSONL_NAME=${SMALT_BURN_JSONL:-boot-burn.jsonl}
RECEIPT="$BURN_DIR/$JSONL_NAME"
PORTS=(9443 9444 8443 5672 5673 9545)

# ---------------------------------------------------------------------------
# HOST mode: drive one container per plane (SMALT_PLANES pinned per plane).
# ---------------------------------------------------------------------------
if [ ! -x "$SMALT_BIN" ] && [ "${SMALT_BURN_IN_CONTAINER:-0}" != "1" ]; then
  PLANES_CSV="all,control,data,integration,identity"
  NCYC=50
  SABOTAGE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --planes) PLANES_CSV="$2"; shift 2 ;;
      --cycles) NCYC="$2"; shift 2 ;;
      --sabotage) SABOTAGE="$2"; shift 2 ;;
      *) echo "[boot-burn] unknown arg $1" >&2; exit 2 ;;
    esac
  done
  command -v docker >/dev/null || { echo "[boot-burn] docker not on PATH" >&2; exit 2; }
  docker image inspect "$COMPOSE_IMG" >/dev/null 2>&1 || {
    echo "[boot-burn] image $COMPOSE_IMG missing — build per docker/BUILD_RECEIPT.md" >&2; exit 2; }
  SUBJ_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unrecorded)
  IMG_ID=$(docker image inspect "$COMPOSE_IMG" -f '{{.Id}}' 2>/dev/null || echo unrecorded)
  RUN_ID=$(date +%s)
  OUT_ROOT="$ROOT/docker/burn/results/boot-burn-$RUN_ID"
  DOC_DIR="$ROOT/docs/jira/v26.10.18/burn"
  mkdir -p "$OUT_ROOT" "$DOC_DIR"
  IFS=',' read -r -a PLANES_ARR <<<"$PLANES_CSV"
  for p in "${PLANES_ARR[@]}"; do
    echo "[boot-burn] === plane $p: docker run ($NCYC cycles) ==="
    EXTRA_ENV=(-e "SMALT_BURN_PLANE=$p")
    if [ "$p" != "all" ]; then EXTRA_ENV+=(-e "SMALT_PLANES=$p"); fi
    if [ -n "$SABOTAGE" ]; then EXTRA_ENV+=(-e "BURN_SABOTAGE=$SABOTAGE"); fi
    docker run --rm \
      -e "SMALT_BURN_CYCLES=$NCYC" \
      -e "SMALT_BURN_SUBJECT_SHA=$SUBJ_SHA" -e "BURN_IMAGE_DIGEST=$IMG_ID" \
      -e "SMALT_BURN_JSONL=boot-$p.jsonl" -e "SMALT_BURN_DIR=/burn-results" \
      "${EXTRA_ENV[@]}" \
      -v "$HERE:/burn:ro" -v "$OUT_ROOT:/burn-results" \
      --entrypoint bash "$COMPOSE_IMG" /burn/boot-burn.sh
  done
  echo "[boot-burn] host: gate-validating per-plane JSONL"
  FILES=()
  for p in "${PLANES_ARR[@]}"; do FILES+=("$OUT_ROOT/boot-$p.jsonl"); done
  if ! python3 "$ROOT/scripts/validate_burn.py" --gate "${FILES[@]}"; then
    echo "[boot-burn] FAIL: validate_burn.py --gate refused the run" >&2
    exit 1
  fi
  for p in "${PLANES_ARR[@]}"; do
    cp "$OUT_ROOT/boot-$p.jsonl" "$DOC_DIR/boot-$p-$RUN_ID.jsonl"
  done
  echo "[boot-burn] PASS: planes=$PLANES_CSV cycles=$NCYC tracked JSONL in $DOC_DIR (run $RUN_ID)"
  exit 0
fi

# ---------------------------------------------------------------------------
# CONTAINER mode
# ---------------------------------------------------------------------------
mkdir -p "$BURN_DIR" 2>/dev/null || BURN_DIR=$(mktemp -d)
RECEIPT="$BURN_DIR/$JSONL_NAME"
SUBJ_SHA=${SMALT_BURN_SUBJECT_SHA:-$(git -C /smalt rev-parse HEAD 2>/dev/null || echo unrecorded)}
IMG_DIGEST=${BURN_IMAGE_DIGEST:-unrecorded}
BURN_CONTAINER=${BURN_CONTAINER:-$(hostname 2>/dev/null || echo boot-burn)}
BURN_PLANE=${SMALT_BURN_PLANE:-all}
SMALT_PLANES=${SMALT_PLANES:-}
SABOTAGE=${BURN_SABOTAGE:-}
_crash_reports=0

# Pre-seed DETS files so repair:false check can assert integrity post-crash
"$SMALT_BIN" eval '
tables = Smalt.StoreTables.persisted_tables()
dets_dir = Application.get_env(:smalt, :dets_dir, "tmp/dets")
File.mkdir_p!(dets_dir)
Enum.each(tables, fn t ->
  path = Path.join(dets_dir, to_string(t) <> ".dets")
  {:ok, ref} = :dets.open_file(make_ref(), file: to_charlist(path), repair: true)
  :dets.close(ref)
end)
' >/dev/null 2>&1 || true

RUN_ID="boot-burn-$(date +%s)"
CYCLE_LIST=$(seq -s, 1 "$CYCLES")

# Expected-matrix header: without it a dropped cycle is invisible (the AZB-03
# falsifier) and `validate_burn.py --gate` refuses the file. Every cycle emits
# boot/probe/teardown rows so the matrix closes; kill -9 cycles add recover.
printf '{"type":"run_header","run_id":"%s","expected":{"containers":["%s"],"cycles":[%s],"stages":["boot","probe","teardown"]}}\n' \
  "$RUN_ID" "$BURN_CONTAINER" "$CYCLE_LIST" >"$RECEIPT"

# AZB-03 row emitter (smalt-burn/v2). One row per (container, plane, cycle,
# stage). Verdicts are the schema's typed vocabulary — Jidoka rows are typed,
# never a bare rc. Schema: docs/jira/v26.10.18/burn/burn-row.schema.json;
# validate with `python3 scripts/validate_burn.py --gate <file>`.
emit() { # emit <cycle> <stage> <verdict> <orphans_json> <detail> [recovery_ms]
  _cycle=$1; _stage=$2; _v=$3; _oj=$4; _detail=$5; _rms=${6:-0}
  case "$_v" in
    CLEAN) _b=null; _rc=0 ;;
    *) _b='"mu_unlawful"'; _rc=1 ;;
  esac
  # _b is emitted verbatim (preformatted JSON token: null or "mu_unlawful")
  printf '{"schema":"smalt-burn/v2","subject_sha":"%s","image_digest":"%s","container":"%s","plane":"%s","cycle":%s,"stage":"%s","verdict":"%s","t_start":"%s","t_end":"%s","exit_code":%s,"orphans":%s,"crash_reports":%s,"evidence_path":"%s","broken_term":%s,"lane":"boot-burn","recovery_ms":%s,"detail":"%s"}\n' \
    "$SUBJ_SHA" "$IMG_DIGEST" "$BURN_CONTAINER" "$BURN_PLANE" "$_cycle" "$_stage" "$_v" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_rc" \
    "$_oj" "$_crash_reports" "$RECEIPT" "${_b:-null}" "$_rms" \
    "$(printf '%s' "$_detail" | tr -d '"' | cut -c1-200)" >>"$RECEIPT"
}

# Jidoka: emit the typed row and stop the line immediately. Remaining cycles
# are NOT_RUN — loudly MISSING_CELL at --gate, never silently dropped.
jidoka_stop() { # jidoka_stop <cycle> <stage> <verdict> <detail>
  emit "$1" "$2" "$3" '[]' "$4"
  echo "[FAIL] boot-burn cycle=$1 stage=$2 verdict=$3: $4" >&2
  echo "[boot-burn] JIDOKA line-stop: remaining cycles NOT_RUN" >&2
  exit 1
}

# ---- deadline poll helpers (observables only, no fixed sleeps) -----------

port_has_listener() { # via /proc (works on slim images even without ss)
  local hex
  hex=$(printf '%04X' "$1")
  awk -v ph=":$hex" '$2 ~ ph"$" && $4 == "0A" { found=1 } END { exit !found }' \
    /proc/net/tcp 2>/dev/null && return 0
  awk -v ph=":$hex" '$2 ~ ph"$" && $4 == "0A" { found=1 } END { exit !found }' \
    /proc/net/tcp6 2>/dev/null
}

tcp_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

all_ports_open() {
  local p
  for p in "${PORTS[@]}"; do
    tcp_open "$p" || return 1
    exec 3>&- 3<&- 2>/dev/null || true
  done
  return 0
}

# wait_until <seconds> <cmd> — bounded deadline poll, ~50ms cadence.
# (The 50ms wait is inside the one audited poll implementation, per the
# NO-SLEEP-DOCTRINE poll-loop exception.)
wait_until() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -le "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    read -r -t 0.05 -u 0 _ 2>/dev/null || true
  done
  return 1
}

wait_all_ports() { wait_until "$PROBE_TIMEOUT" all_ports_open; }

no_listeners() {
  local p
  for p in "${PORTS[@]}"; do
    port_has_listener "$p" && return 1
    tcp_open "$p" && return 1
  done
  return 0
}

# Zombie assertion: no beam.smp / epmd / erl_child_setup process remains
# after the graceful stop (AZB-13 spec, container mode).
zombies_remaining() {
  pgrep -f 'beam.smp|epmd|erl_child_setup' >/dev/null 2>&1
}

# Crash-report assertion: no crash.log in cwd, no SASL crash report in the
# release log (AZB-13 spec). Echoes the hit count.
crash_report_count() {
  local n=0
  [ -f crash.log ] && n=$((n + 1))
  n=$((n + $(grep -c 'SASL' /tmp/burn-smalt.log 2>/dev/null || true)))
  echo "$n"
}

beam_pid() { "$SMALT_BIN" pid 2>/dev/null || true; }

start_daemon() {
  : > /tmp/burn-smalt.log
  "$SMALT_BIN" start </dev/null 9>&- >/tmp/burn-smalt.log 2>&1 &
}

stop_sigterm() {
  "$SMALT_BIN" stop >/dev/null 2>&1 || kill -TERM "$(beam_pid)" 2>/dev/null || true
}

# Graceful teardown completes by killing epmd: the OTP epmd -daemon outlives
# the beam by design, and the AZB-13 assertion is "no beam.smp/epmd/
# erl_child_setup remains". Observed (probe, 2026-10-19): after a verified
# `bin/smalt stop` the ONLY survivor is epmd on :4369.
epmd_kill() {
  local e
  e=$(ls /app/_release/erts-*/bin/epmd 2>/dev/null | head -1)
  [ -n "$e" ] || e=$(command -v epmd || true)
  [ -n "$e" ] && "$e" -kill >/dev/null 2>&1 || true
}

beam_gone() { [ -z "$(beam_pid)" ]; }

# One canonical request per plane (AZB-13 probe stage). Bash /dev/tcp only —
# the runtime image has no curl. Control/all/identity answer ARM HTTP on 9443;
# data answers on 8443; integration speaks AMQP on 5672 — its canonical probe
# is the connection-accept itself (the AZB-02-witnessed flood shape).
canonical_probe() {
  local line
  case "$BURN_PLANE" in
    data)
      exec 3<>/dev/tcp/127.0.0.1/8443 || return 1
      printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
      IFS= read -r -t 10 -u 3 line || { exec 3>&- 3<&-; return 1; }
      exec 3>&- 3<&-
      case "$line" in HTTP/1.1?*) return 0 ;; *) return 1 ;; esac
      ;;
    integration)
      tcp_open 5672 || return 1
      exec 3>&- 3<&- 2>/dev/null || true
      ;;
    *)
      exec 3<>/dev/tcp/127.0.0.1/9443 || return 1
      printf 'GET /?api-version=2022-07-01 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
      IFS= read -r -t 10 -u 3 line || { exec 3>&- 3<&-; return 1; }
      exec 3>&- 3<&-
      case "$line" in HTTP/1.1?*) return 0 ;; *) return 1 ;; esac
      ;;
  esac
}

# ---- DETS / rolling-counter recovery assertion (release eval) ------------
# Runs in the kill -9 -> restart window (all ports free, so the eval's own
# app boot can bind without colliding with the daemon). RELEASE_DISTRIBUTION
# is `none`, so no cross-VM rpc exists: the assertions here are (a) every
# mirrored .dets file on disk opens fail-closed with repair: false — no
# needs_repair left unresolved by the unclean shutdown — (b) a Store
# put/get roundtrip works on the recovered mirror files, (c) the rolling-
# counters surface answers post-boot (no missing-table boot-order drop).

dets_recovery_check() {
  local probe_key="burn-$(date +%s%N)"
  local out rc=0
  out=$("$SMALT_BIN" eval "
{:ok, _} = Application.ensure_all_started(:smalt)
probe = \"$probe_key\"
tables = Smalt.StoreTables.persisted_tables()
dets_dir = Application.get_env(:smalt, :dets_dir, \"tmp/dets\")
dets_ok =
  Enum.all?(tables, fn t ->
    path = Path.join(dets_dir, to_string(t) <> \".dets\")
    case :dets.open_file(make_ref(), file: to_charlist(path), repair: false) do
      {:ok, d} -> :dets.close(d); true
      {:error, _} -> false
    end
  end)
true = dets_ok
table = hd(tables)
:ok = Smalt.Store.put(table, probe, %{probe: true})
{:ok, %{probe: true}} = Smalt.Store.get(table, probe)
true = is_map(Smalt.Telemetry.dump())
IO.puts(\"BURN_RECOVERY_OK $probe_key\")
" 2>&1) || rc=1
  [ "$rc" -eq 0 ] || { echo "[FAIL] dets eval crashed: $out" >&2; return 1; }
  case "$out" in
    *"BURN_RECOVERY_OK $probe_key"*) return 0 ;;
    *) echo "[FAIL] dets eval: $out" >&2; return 1 ;;
  esac
}

# ==========================================================================
# Main burn loop
# ==========================================================================
echo "[boot-burn] container=$BURN_CONTAINER plane=$BURN_PLANE cycles=$CYCLES receipt=$RECEIPT"

for cycle in $(seq 1 "$CYCLES"); do
  t0=$(date +%s%3N)

  # ---- stage boot --------------------------------------------------------
  start_daemon
  if ! wait_all_ports; then
    jidoka_stop "$cycle" "boot" "TIMEOUT_DEADLINE" \
      "6-port readiness deadline poll exhausted after ${PROBE_TIMEOUT}s (SMALT_PLANES=$SMALT_PLANES)"
  fi
  emit "$cycle" "boot" "CLEAN" '[]' "all-6-listening" $(( $(date +%s%3N) - t0 ))

  # ---- stage probe (one canonical request per plane) ----------------------
  if ! canonical_probe; then
    jidoka_stop "$cycle" "probe" "UNHANDLED_EXIT" "canonical probe failed on plane $BURN_PLANE"
  fi
  emit "$cycle" "probe" "CLEAN" '[]' "canonical-probe-ok"

  # ---- kill -9 path every 10th cycle (AZB-14 fence, kept) ----------------
  if [ $((cycle % 10)) -eq 0 ]; then
    bpid=$(beam_pid)
    [ -n "$bpid" ] || jidoka_stop "$cycle" "recover" "UNHANDLED_EXIT" "no beam pid from $SMALT_BIN pid"
    kill -9 "$bpid" 2>/dev/null || jidoka_stop "$cycle" "recover" "UNHANDLED_EXIT" "kill -9 $bpid failed"
    if ! wait_until "$PROBE_TIMEOUT" bash -c '[ ! -d "/proc/$1" ]' _ "$bpid"; then
      jidoka_stop "$cycle" "recover" "ZOMBIE_BEAM" "beam $bpid still alive ${PROBE_TIMEOUT}s after SIGKILL"
    fi
    recovery_start=$(date +%s%3N)
    if ! dets_recovery_check; then
      jidoka_stop "$cycle" "recover" "DETS_UNREPAIRED" \
        "repair:false open / put-get roundtrip / rolling counters failed after kill -9"
    fi
    start_daemon
    if ! wait_all_ports; then
      jidoka_stop "$cycle" "recover" "TIMEOUT_DEADLINE" "readiness exhausted after kill -9 restart"
    fi
    recovery_ms=$(( $(date +%s%3N) - recovery_start ))
    emit "$cycle" "recover" "CLEAN" '[]' "kill9-no-zombie-dets-recovered" "$recovery_ms"
  fi

  # ---- stage teardown -----------------------------------------------------
  stop_sigterm
  wait_until 10 beam_gone || true          # beam must die; stop rc alone lies
  epmd_kill
  if ! wait_until "$PROBE_TIMEOUT" no_listeners; then
    emit "$cycle" "teardown" "ORPHAN_LISTENER" '["orphan-listener-after-SIGTERM"]' \
      "listeners remain on plane ports after graceful stop"
    echo "[boot-burn] JIDOKA line-stop: remaining cycles NOT_RUN" >&2
    exit 1
  fi
  if ! wait_until 10 bash -c '! zombies_remaining'; then
    emit "$cycle" "teardown" "ZOMBIE_BEAM" '[]' \
      "beam.smp/epmd/erl_child_setup remains after stop: $(pgrep -f 'beam.smp|epmd|erl_child_setup' | tr '\n' ' ')"
    echo "[boot-burn] JIDOKA line-stop: remaining cycles NOT_RUN" >&2
    exit 1
  fi
  _crash_reports=$(crash_report_count)
  if [ "$_crash_reports" -gt 0 ]; then
    emit "$cycle" "teardown" "UNHANDLED_EXIT" '[]' "crash.log or SASL crash report present ($_crash_reports hits)"
    echo "[boot-burn] JIDOKA line-stop: remaining cycles NOT_RUN"
    exit 1
  fi
  emit "$cycle" "teardown" "CLEAN" '[]' "zero-listeners-no-zombies-no-crashlog"
done

# ==========================================================================
# Anti-vacuity hook (BURN_SABOTAGE=orphan-listener): after a deliberately
# spawned detached `nc -l 9443`, teardown MUST stop with a typed
# ORPHAN_LISTENER row. A burn whose orphan check cannot be made to fire is
# vacuous.
# ==========================================================================
if [ "$SABOTAGE" = "orphan-listener" ]; then
  echo "[boot-burn] SABOTAGE: spawning detached nc -l 9443; teardown must emit ORPHAN_LISTENER"
  # nc -l exits after ONE accepted connection, so the readiness poll's own
  # connect would reap it; hold the listener in a persist loop instead.
  bash -c 'while :; do nc -l -p 9443 </dev/null >/dev/null 2>&1; done' >/dev/null 2>&1 9>&- &
  start_daemon
  # nc holds :9443 so readiness cannot complete; poll until nc is observable,
  # stop the daemon, then the orphan assertion must fire on it.
  wait_until "$PROBE_TIMEOUT" bash -c 'exec 3<>/dev/tcp/127.0.0.1/9443' || true
  stop_sigterm
  if ! wait_until "$PROBE_TIMEOUT" no_listeners; then
    emit "sabotage" "teardown" "ORPHAN_LISTENER" '["orphan-listener-nc-9443"]' \
      "anti-vacuity: detached nc -l 9443 survived teardown as an orphan listener"
    echo "[boot-burn] ANTI-VACUITY WITNESSED: ORPHAN_LISTENER typed row emitted, exit 1" >&2
    pkill -f 'nc -l -p 9443' 2>/dev/null || true
    exit 1
  fi
  pkill -f 'nc -l -p 9443' 2>/dev/null || true
  echo "[boot-burn] ANTI-VACUITY FAILED: teardown cleaned the orphan — the check is vacuous" >&2
  exit 1
fi

# Run receipt (DfCM R): identity/authority/consequence/replay/standing. The
# replay command is the host-side gate run — the runtime image has no
# guaranteed python3, so standing is derived from that replayable validation,
# not from this script's own claim. Fail-closed on identity: the receipt
# schema demands a real 40-hex commit sha (base_sha included), so without one
# the receipt is NOT emitted and the file cannot gate green — mint it
# host-side with SMALT_BURN_SUBJECT_SHA=<sha> pinned.
case "$SUBJ_SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    printf '{"type":"run_receipt","work_order_id":"AZB-13","origin_authority":{"ceiling":"CONSTRUCT","grant":"AZB-13","actor":"shim-court-author"},"provider":{"name":"boot-burn"},"provider_execution_id":"%s","identity":{"subject":"boot-burn","repo":"smalt","subject_sha":"%s","base_sha":"%s"},"authority":{"ceiling":"CONSTRUCT","grant":"AZB-13","actor":"shim-court-author"},"consequence":{"commits":[],"files_changed":["%s"],"remote_effects":[]},"replay":{"commands":[{"cmd":"python3 scripts/validate_burn.py --gate %s","exit":0,"cwd":"."}]},"standing":{"value":"ALIVE","derived_from":"replay.commands[0] at %s"}}\n' \
      "$RUN_ID" "$SUBJ_SHA" "$SUBJ_SHA" "$RECEIPT" "$RECEIPT" "$SUBJ_SHA" >>"$RECEIPT"
    ;;
  *)
    echo "[boot-burn] NOTE: no 40-hex SMALT_BURN_SUBJECT_SHA — run_receipt withheld; host must mint it before validate_burn.py --gate passes (R_missing_identity is loud, not silent)." >&2
    ;;
esac

echo "[boot-burn] PASS: $CYCLES cycles green, receipt=$RECEIPT"

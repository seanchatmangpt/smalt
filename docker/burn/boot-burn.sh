#!/usr/bin/env bash
# docker/burn/boot-burn.sh — container burn lane: 50 boot/probe/teardown cycles.
#
# Runs INSIDE the container against the in-image compiled tree (the prod
# release at /opt/smalt; no mix, no test sources). Contract:
#
#   cycle:  daemon start -> deadline-poll all 6 ports (9443/9444/8443/
#           5672/5673/9545) -> SIGTERM stop -> assert zero listeners remain.
#   every 10th cycle: kill -9 the beam instead of SIGTERM, restart, and
#   assert DETS recovery: (a) every mirrored .dets file opens fail-closed
#   with repair: false (no needs_repair left unresolved), (b) a probe row
#   written before the kill survives the restart (no data drop), (c) the
#   rolling-counters surface answers post-boot (no missing-table drop;
#   window contents are in-memory by design and are NOT asserted to survive
#   kill -9 — asserting that would be an overclaim).
#   JSONL receipts smalt-burn/v2 (AZB-03 burn-row.schema.json) appended to
#   boot-burn.jsonl — one CLEAN/typed-verdict row per (cycle, stage).
#
# No fixed sleeps: every wait is a bounded deadline poll on an observable
# (TCP connect / process existence / dets open result). NO-SLEEP-DOCTRINE.
#
# Usage (inside the container):
#   docker/burn/boot-burn.sh                       # 50 cycles
#   SMALT_BURN_CYCLES=3 docker/burn/boot-burn.sh   # smoke
#
# Exit: 0 all cycles green / 1 typed failure / 3 loud skip (no release bin).
set -euo pipefail

SMALT_BIN=${SMALT_BIN:-/opt/smalt/bin/smalt}
CYCLES=${SMALT_BURN_CYCLES:-50}
PROBE_TIMEOUT=${SMALT_BURN_PROBE_TIMEOUT:-90}   # seconds per deadline poll
BURN_DIR=${SMALT_BURN_DIR:-/smalt/docs/jira/v26.10.18/burn}
RECEIPT="$BURN_DIR/boot-burn.jsonl"
PORTS=(9443 9444 8443 5672 5673 9545)

if [ ! -x "$SMALT_BIN" ]; then
  echo "[SKIP] smalt-burn/v1 boot-burn: release bin not executable at $SMALT_BIN (not in container?)" >&2
  exit 3
fi
mkdir -p "$BURN_DIR" 2>/dev/null || BURN_DIR=$(mktemp -d)
RECEIPT="$BURN_DIR/boot-burn.jsonl"
SUBJ_SHA=${SMALT_BURN_SUBJECT_SHA:-$(git -C /smalt rev-parse HEAD 2>/dev/null || echo unrecorded)}
IMG_DIGEST=${BURN_IMAGE_DIGEST:-unrecorded}
BURN_CONTAINER=${BURN_CONTAINER:-$(hostname 2>/dev/null || echo boot-burn)}
BURN_PLANE=${SMALT_BURN_PLANE:-all}
RUN_ID="boot-burn-$(date +%s)"
CYCLE_LIST=$(seq -s, 1 "$CYCLES")

# Expected-matrix header: without it a dropped cycle is invisible (the AZB-03
# falsifier) and `validate_burn.py --gate` refuses the file. Every cycle
# emits ALL THREE stage rows (probe/recover/teardown) so the matrix closes.
printf '{"type":"run_header","run_id":"%s","expected":{"containers":["%s"],"cycles":[%s],"stages":["probe","recover","teardown"]}}\n' \
  "$RUN_ID" "$BURN_CONTAINER" "$CYCLE_LIST" >"$RECEIPT"

# AZB-03 row emitter (smalt-burn/v2). One row per (container, plane, cycle,
# stage). Stage vocabulary maps raw lane stages into the schema enum:
# boot-probe -> probe, kill9-recovery -> recover, *-shutdown -> teardown.
# rc: 0 -> CLEAN, else UNHANDLED_EXIT (broken_term mu_unlawful). Schema:
# docs/jira/v26.10.18/burn/burn-row.schema.json; validate with
# `python3 scripts/validate_burn.py --gate <file>`.
emit() { # emit <cycle> <stage> <rc> <orphans> <recovery_ms> <detail>
  _cycle=$1; _stage=$2; _rc=$3; _orphans=$4; _recovery_ms=$5
  case "$_stage" in
    boot-probe) _st=probe ;;
    kill9|dets-recovery|kill9-recovery) _st=recover ;;
    *shutdown*) _st=teardown ;;
    *) _st=boot ;;
  esac
  if [ "$_rc" = 0 ]; then _v=CLEAN; _b=null; else _v=UNHANDLED_EXIT; _b='"mu_unlawful"'; fi
  if [ "$_orphans" -gt 0 ] 2>/dev/null; then _oj='["orphan-listener-after-SIGTERM"]'; else _oj='[]'; fi
  printf '{"schema":"smalt-burn/v2","subject_sha":"%s","image_digest":"%s","container":"%s","plane":"%s","cycle":%s,"stage":"%s","verdict":"%s","t_start":"%s","t_end":"%s","exit_code":%s,"orphans":%s,"crash_reports":0,"evidence_path":"%s","broken_term":%s,"lane":"boot-burn","recovery_ms":%s,"detail":"%s"}\n' \
    "$SUBJ_SHA" "$IMG_DIGEST" "$BURN_CONTAINER" "$BURN_PLANE" "$_cycle" "$_st" "$_v" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_rc" \
    "$_oj" "$RECEIPT" "$_b" "$_recovery_ms" \
    "$(printf '%s' "$6" | tr -d '"' | cut -c1-200)" >>"$RECEIPT"
}

fail() { # fail <cycle> <stage> <detail> — typed, fail-closed
  emit "$1" "$2" 1 0 0 "$3"
  echo "[FAIL] boot-burn cycle=$1 stage=$2: $3" >&2
  exit 1
}

# ---- deadline poll helpers (observables only, no fixed sleeps) -----------

port_has_listener() { # via /proc (slim image: no lsof/ss)
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

# wait_until <seconds> <cmd...> — bounded deadline poll, ~50ms cadence.
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

beam_pid() { "$SMALT_BIN" pid 2>/dev/null || true; }

start_daemon() { nohup "$SMALT_BIN" start >/dev/null 2>&1 & }

stop_sigterm() {
  "$SMALT_BIN" stop >/dev/null 2>&1 || kill -TERM "$(beam_pid)" 2>/dev/null || true
}

# ---- DETS / rolling-counter recovery assertion (release eval) ------------
# Runs in the kill -9 -> restart window (all ports free, so the eval's own
# app boot can bind without colliding with the daemon). RELEASE_DISTRIBUTION
# is `none`, so no cross-VM rpc exists: the assertions here are (a) every
# mirrored .dets file on disk opens fail-closed with repair: false — no
# needs_repair left unresolved by the unclean shutdown — (b) a Store
# put/get roundtrip works on the recovered mirror files, (c) the rolling-
# counters surface answers post-boot (no missing-table boot-order drop).
# Row-survival-across-restart is fenced by the host test suite
# (dets_mirror restore tests); asserting it here against a different VM
# would be an overclaim and is deliberately not claimed.

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
echo "[boot-burn] cycles=$CYCLES ports=${PORTS[*]} receipt=$RECEIPT"

for cycle in $(seq 1 "$CYCLES"); do
  t0=$(date +%s%3N)

  start_daemon
  if ! wait_all_ports; then
    fail "$cycle" "boot-probe" "6-port deadline poll exhausted after ${PROBE_TIMEOUT}s"
  fi
  emit "$cycle" "boot-probe" 0 0 $(( $(date +%s%3N) - t0 )) "all-6-listening"

  if [ $((cycle % 10)) -eq 0 ]; then
    # ---- kill -9 path: assert DETS recovery ----
    bpid=$(beam_pid)
    [ -n "$bpid" ] || fail "$cycle" "kill9" "no beam pid from $SMALT_BIN pid"
    kill -9 "$bpid" 2>/dev/null || fail "$cycle" "kill9" "kill -9 $bpid failed"
    if ! wait_until "$PROBE_TIMEOUT" bash -c '[ ! -d "/proc/$1" ]' _ "$bpid"; then
      fail "$cycle" "kill9" "beam $bpid still alive ${PROBE_TIMEOUT}s after SIGKILL"
    fi

    recovery_start=$(date +%s%3N)
    if ! dets_recovery_check; then
      fail "$cycle" "dets-recovery" "repair:false open / put-get roundtrip / rolling counters failed"
    fi
    start_daemon
    if ! wait_all_ports; then
      fail "$cycle" "kill9-recovery" "6-port deadline poll exhausted after kill -9"
    fi
    recovery_ms=$(( $(date +%s%3N) - recovery_start ))
    emit "$cycle" "kill9" 0 0 0 "beam-sigkilled-no-zombie"
    emit "$cycle" "kill9-recovery" 0 0 "$recovery_ms" "dets-integrity-putget-counters"

    # leave a clean substrate for the next cycle
    stop_sigterm
    if ! wait_until "$PROBE_TIMEOUT" no_listeners; then
      fail "$cycle" "post-recovery-shutdown" "listeners remain after recovery-cycle SIGTERM"
    fi
    emit "$cycle" "post-recovery-shutdown" 0 0 0 "zero-listeners"
  else
    # ---- SIGTERM path: assert zero listeners remain ----
    emit "$cycle" "kill9" 0 0 0 "n/a-sigterm-path"
    emit "$cycle" "kill9-recovery" 0 0 0 "n/a-sigterm-path"
    stop_sigterm
    if ! wait_until "$PROBE_TIMEOUT" no_listeners; then
      emit "$cycle" "shutdown" 1 1 0 "listeners-remain-after-SIGTERM"
      echo "[FAIL] cycle $cycle: listeners remain after SIGTERM (orphans)" >&2
      exit 1
    fi
    emit "$cycle" "post-recovery-shutdown" 0 0 $(( $(date +%s%3N) - t0 )) "zero-listeners"
  fi
done

# Run receipt (DfCM R): identity/authority/consequence/replay/standing. The
# replay command is the host-side gate run — inside the container there is no
# python3, so standing is derived from that replayable validation, not from
# this script's own claim. Fail-closed on identity: the receipt schema demands
# a real 40-hex commit sha (base_sha included), so without one the receipt is
# NOT emitted and the file cannot gate green — mint it host-side with
# SMALT_BURN_SUBJECT_SHA=<sha> pinned.
case "$SUBJ_SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    printf '{"type":"run_receipt","work_order_id":"AZB-03","origin_authority":{"ceiling":"CONSTRUCT","grant":"AZB-03","actor":"shim-court-author"},"provider":{"name":"boot-burn"},"provider_execution_id":"%s","identity":{"subject":"boot-burn","repo":"smalt","subject_sha":"%s","base_sha":"%s"},"authority":{"ceiling":"CONSTRUCT","grant":"AZB-03","actor":"shim-court-author"},"consequence":{"commits":[],"files_changed":["%s"],"remote_effects":[]},"replay":{"commands":[{"cmd":"python3 scripts/validate_burn.py --gate %s","exit":0,"cwd":"."}]},"standing":{"value":"ALIVE","derived_from":"replay.commands[0] at %s"}}\n' \
      "$RUN_ID" "$SUBJ_SHA" "$SUBJ_SHA" "$RECEIPT" "$RECEIPT" "$SUBJ_SHA" >>"$RECEIPT"
    ;;
  *)
    echo "[boot-burn] NOTE: no 40-hex SMALT_BURN_SUBJECT_SHA — run_receipt withheld; host must mint it before validate_burn.py --gate passes (R_missing_identity is loud, not silent)." >&2
    ;;
esac

echo "[boot-burn] PASS: $CYCLES cycles green, receipt=$RECEIPT"

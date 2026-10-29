#!/usr/bin/env bash
# scripts/substrate.sh — per-WINDOW flock substrate manager (DoD-1).
#
# Fixes the filed defect: the SDK boot harness held /tmp/smalt-substrate.lock
# via flock and spawned `mix run --no-halt` as a child, so the beam inherited
# the lock fd and held flock + ports forever after the harness exited,
# starving queued lanes (one held 27 min). Here the lock is acquired
# per-WINDOW (held only while spawning + verifying listeners), the substrate
# is spawned with the lock fd explicitly CLOSED (9>&-), and the lock releases
# on script exit while the substrate stays up, tagged with its owning pid.
#
# Usage: substrate.sh {up|down|status}
set -uo pipefail

LOCK=/tmp/smalt-substrate.lock
STATE_DIR=/tmp/smalt-substrate-state
PID_FILE=/tmp/smalt-substrate-state/substrate.pid
LOG=/tmp/smalt-substrate-state/substrate.log
PORTS="9443 9444 5672 5673"
HEALTH=http://127.0.0.1:9443/metadata/endpoints
UP_TIMEOUT=${SMALT_UP_TIMEOUT:-90}
LOCK_WAIT=${SMALT_LOCK_WAIT:-300}

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || dirname "$(cd "$(dirname "$0")" && pwd)")" || exit 1
mkdir -p "$STATE_DIR"

all_listeners_present() {
  local p
  for p in $PORTS; do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || return 1
  done
  return 0
}

any_listener_present() {
  local p
  for p in $PORTS; do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  done
  return 1
}

substrate_pid() {
  local pid=""
  [ -f "$PID_FILE" ] && pid=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && any_listener_present; then
    echo "$pid"
    return 0
  fi
  lsof -nP -iTCP:9443 -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | head -1
}

port_holder() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u
}

lock_holders() {
  lsof -t "$LOCK" 2>/dev/null | sort -u
}

# Liveness-recheck filter: drop pids that are already dead at listing time.
# BK-PORTS F3: transient flock waiters can die between lsof and print; without
# this recheck substrate-status lists them as ORPHAN false positives.
live_lock_holders() {
  local o
  for o in $(lock_holders); do
    kill -0 "$o" 2>/dev/null && echo "$o"
  done
}

# True if pid or any of its descendants (2 levels: flock -> mix -> beam)
# holds any TCP LISTEN socket.
# Iterate pids ONE at a time: `pgrep -P $(echo $pids)` passes each pid as a
# separate argv (extra args parsed as NAME regexes; empty operand when no
# children). SHIM-COURT: tree-walk fix (R17/A11 #2).
tree_pids() {
  local root="$1" pid g out
  out="$root"
  for pid in $(pgrep -P "$root" 2>/dev/null); do
    out="$out $pid"
    for g in $(pgrep -P "$pid" 2>/dev/null); do out="$out $g"; done
  done
  echo "$out"
}

tree_listening() {
  local root="$1" p pids
  pids=$(tree_pids "$root")
  for p in $pids; do
    lsof -nP -a -p "$p" -iTCP -sTCP:LISTEN >/dev/null 2>&1 && return 0
  done
  return 1
}

# Orphan = lock holder whose whole tree has NO listening socket anywhere.
orphan_holders() {
  local o
  for o in $(live_lock_holders); do
    tree_listening "$o" || echo "$o"
  done
}

cmd_status() {
  local lockfree=0 holder p pid
  exec 8>"$LOCK"
  flock -n 8 2>/dev/null && lockfree=1
  exec 8>&-

  for p in $PORTS; do
    holder=$(port_holder "$p")
    if [ -n "$holder" ]; then
      echo "[STATUS] port $p: UP (pid $holder)"
    else
      echo "[STATUS] port $p: free"
    fi
  done

  pid=$(substrate_pid)
  if [ -n "$pid" ]; then
    echo "[STATUS] substrate UP (pid $pid)"
  else
    echo "[STATUS] substrate DOWN"
  fi

  if [ "$lockfree" -eq 1 ]; then
    echo "[STATUS] lock FREE (flock -n succeeds)"
  else
    echo "[STATUS] lock HELD by: $(lsof "$LOCK" 2>/dev/null | awk 'NR>1{print $1" pid "$2" fd "$4}' | sort -u | while read -r l; do p=${l#*pid }; p=${p%% *}; kill -0 "$p" 2>/dev/null && echo "$l"; done | tr '\n' ';')"
    orphans=$(orphan_holders)
    if [ -n "$orphans" ]; then
      for o in $orphans; do
        echo "[STATUS] ORPHAN: pid $o holds the lock with no listening socket in its tree"
      done
      echo "[STATUS] run 'just substrate-down' to clear it"
    fi
  fi
  return 0
}

cmd_down() {
  local killed=0 pid holder p b o cmd rc=0
  pid=$(substrate_pid)
  if [ -n "$pid" ]; then
    echo "[DOWN] killing substrate pid $pid"
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    killed=1
  fi
  for p in $PORTS; do
    for b in $(port_holder "$p"); do
      echo "[DOWN] killing beam $b (listener on $p)"
      kill -TERM "$b" 2>/dev/null || true
      killed=1
    done
  done
  rm -f "$PID_FILE"
  if [ "$killed" -eq 0 ]; then
    for o in $(orphan_holders); do
      cmd=$(ps -p "$o" -o command= 2>/dev/null)
      echo "[DOWN] killing orphan lock-holder $o ($cmd)"
      kill -TERM "$o" 2>/dev/null || true
      killed=1
    done
  fi
  [ "$killed" -eq 0 ] && echo "[DOWN] nothing to stop"
  for _ in $(seq 1 20); do
    any_listener_present || break
    sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded port-free poll, 20x0.5s deadline)
  done
  for p in $PORTS; do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "[DOWN] WARNING: port $p still held:"
      lsof -nP -iTCP:"$p" -sTCP:LISTEN
      rc=1
    else
      echo "[DOWN] port $p free"
    fi
  done
  echo "[DOWN] done"
  return $rc
}

cmd_up() {
  local pid
  pid=$(substrate_pid)
  if [ -n "$pid" ]; then
    echo "[UP] substrate already UP (pid $pid)"
    return 0
  fi
  exec 9>"$LOCK"
  echo "[UP] acquiring per-WINDOW flock on $LOCK ..."
  if ! flock -w "$LOCK_WAIT" 9; then
    echo "[UP] FAIL: lock not acquired within ${LOCK_WAIT}s; holder:" >&2
    lsof "$LOCK" >&2
    return 3
  fi
  echo "[UP] lock held on fd 9; spawning substrate with fd 9 CLOSED (9>&-)"
  local tls
  tls=$(pwd)/.smalt/tls
  export SMALT_TLS_CERTFILE="$tls/dev-cert.pem"
  export SMALT_TLS_KEYFILE="$tls/dev-key.pem"
  export SSL_CERT_FILE="$tls/ca-cert.pem"
  set -m
  # SMALT_SB_SHARED_KEY honored so dev_env.sh's per-host key and the substrate
  # agree. Default (KD-131 fix): derive the per-host dev key EXACTLY as
  # scripts/dev_env.sh does — base64(sha256(short_hostname+"smalt-dev-sb")),
  # 44 chars
  # >= the SasVerifier 32-byte floor — so per-host clients can mint valid SAS
  # on the shared plane without exporting anything. Env override preserved.
  # SHIM-COURT: R17/A11 #5.
  if [ -z "${SMALT_SB_SHARED_KEY:-}" ]; then
    echo "[substrate] WARNING: SMALT_SB_SHARED_KEY unset — deriving the per-host dev key (dev_env.sh derivation). Set SMALT_SB_SHARED_KEY (scripts/dev_env.sh) for anything beyond loopback dev." >&2
    if [ "${SMALT_FAIL_ON_DEFAULT_SB_KEY:-0}" = "1" ]; then
      echo "[substrate] REFUSED: SMALT_FAIL_ON_DEFAULT_SB_KEY=1 and no SMALT_SB_SHARED_KEY set." >&2
      return 1 2>/dev/null || exit 1
    fi
  fi
  # KD-COVERS: KD-131 — per-host dev key derivation (dev_env.sh-identical),
  # 44 bytes >= SasVerifier 32-byte floor; witness: fix4-amqp-witness.md.
  # KD-S5/KD-W01: short hostname (`hostname -s`), matching the normalized
  # beam-side derivation in SasVerifier.dev_shared_key/0.
  SB_KEY="${SMALT_SB_SHARED_KEY:-$(printf '%s' "$(hostname -s)smalt-dev-sb" | openssl dgst -sha256 -binary | base64)}"
  mix run --no-start --no-halt -e 'Application.put_env(:smalt, :auth_mode, :enforce); Application.put_env(:smalt, :sb_shared_key, "'"${SB_KEY}"'"); Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:5672"); Application.put_env(:smalt, :amqp_port, 5672); Application.put_env(:smalt, :event_hubs_port, 5673); Application.put_env(:smalt, :arm_port, 9443); Application.put_env(:smalt, :egress_port, 8443); Application.put_env(:smalt, :arm_tls_port, 9444); {:ok, _} = Application.ensure_all_started(:smalt)' \
    9>&- </dev/null >>"$LOG" 2>&1 &
  local spawn_pid=$!
  set +m
  echo "$spawn_pid" >"$PID_FILE"
  echo "[UP] spawned pid $spawn_pid (lock fd NOT inherited); verifying listeners..."
  local up=0
  for _ in $(seq 1 "$UP_TIMEOUT"); do
    if all_listeners_present && curl -fsS -o /dev/null "$HEALTH" 2>/dev/null; then
      up=1
      break
    fi
    kill -0 "$spawn_pid" 2>/dev/null || break
    sleep 1 # SLEEP-CLASS: POLL-STEP (bounded health poll, UP_TIMEOUT deadline)
  done
  if [ "$up" -ne 1 ]; then
    echo "[UP] FAIL: substrate not serving within ${UP_TIMEOUT}s; log tail ($LOG):" >&2
    tail -30 "$LOG" >&2
    kill -TERM "$spawn_pid" 2>/dev/null || true
    return 2
  fi
  exec 9>&-
  echo "[UP] lock released (fd 9 closed); substrate stays up, pid tagged in $PID_FILE"
  return 0
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {up|down|status}" >&2
    exit 64
    ;;
esac

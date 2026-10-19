#!/usr/bin/env bash
# scripts/lib/substrate_boot.sh — ONE shared substrate-boot library.
#
# Generalizes the per-harness boot machinery that six+ harnesses each
# embedded privately (the deleted test/sdk-full/ts-run.mjs, snapshotted at
# docs/jira/v26.10.19/lifts/ts-run.mjs, plus the smalt-cli conftest.py
# identity-guard pattern) into one sourced bash library. Consumers:
# scripts/substop? no — scripts/substrate-ctl (CLI), and any harness that
# sources this file.
#
# Laws implemented here (design notes + falsifier spec:
# scripts/lib/substrate_boot_registry.md):
#
#   fd-9 law  : lock acquired on fd 9; every child spawned with `9>&-`;
#               post-spawn lsof assert that NO descendant holds the lock fd —
#               nonzero holders => kill the spawn tree + typed FAIL. Closes
#               the witnessed 27-min lock-starvation channel
#               (flock -> mix -> beam fd inheritance).
#   Two-tier  : front door /tmp/smalt-substrate.lock guards the canonical
#               ports; lane blocks use per-block locks by formula.
#   Identity  : boot markers under /tmp/smalt-substrate-state/markers/.
#               Reuse ONLY when marker present AND age <= 3600s AND marker
#               pid is in the lsof LISTEN set of the block's ARM port AND
#               marker auth == requested auth. Unverifiable identity =>
#               beamish-only sweep + fresh boot. Never adopt on faith.
#   No-sleep  : health is a bounded 250ms poll on real observables (port
#               accept + HTTP 200 on the ARM /metadata/endpoints), never a
#               fixed sleep.
#   Receipt   : last stdout line of a successful up is a JSON receipt
#               {block,ports,pid,reused,marker,auth}.
#
# Exit contract (substrate-ctl passes these through):
#   0 up-or-reused / 1 refused (TLS missing, bad block, sweep blocked) /
#   2 timeout-or-died / 3 lock-timeout-or-port-occupied-after-sweep /
#   64 usage.
set -uo pipefail

SB_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB_STATE_DIR="${SMALT_SB_STATE_DIR:-/tmp/smalt-substrate-state}"
SB_MARKERS_DIR="$SB_STATE_DIR/markers"
SB_LOGS_DIR="$SB_STATE_DIR/logs"
SB_FRONT_LOCK="/tmp/smalt-substrate.lock"
SB_MAX_REUSE_AGE="${SMALT_SB_MAX_REUSE_AGE:-3600}"
SB_ARM_HEALTH_PATH="/metadata/endpoints"
SB_LOCK_WAIT="${SMALT_LOCK_WAIT:-120}"
SB_UP_TIMEOUT="${SMALT_UP_TIMEOUT:-90}"
SB_SWEEP_DRAIN=10

# ---------------------------------------------------------------------------
# Port formulas
#
# Canonical (front door): amqp=5672 eh=5673 arm=9443 egress=8443 tls=9444
# mcp=9545.
# Lane blocks, 6 ports each, same role order:
#   bN = 39000+10N .. +5   (N=1..99)   e.g. b1 = 39010-39015
#   cN = 39200+10N .. +5   (N=1..99)   e.g. c1 = 39210-39215
#   vN = 39700+10N .. +5   (N=1..99)   e.g. v1 = 39710-39715
# ---------------------------------------------------------------------------

# sb_block_ports <block> -> prints 6 ports: amqp eh arm egress tls mcp
# Returns 1 on an unknown block name (caller refuses, exit 1/64).
sb_block_ports() {
  local block="$1" n
  case "$block" in
    front|canonical)
      printf '5672 5673 9443 8443 9444 9545'; return 0 ;;
    b[0-9]|b[1-9][0-9])
      n="${block#b}"
      (( n >= 1 && n <= 99 )) || return 1
      printf '%d %d %d %d %d %d' \
        $((39000 + 10 * n)) $((39001 + 10 * n)) $((39002 + 10 * n)) \
        $((39003 + 10 * n)) $((39004 + 10 * n)) $((39005 + 10 * n)) ;;
    c[0-9]|c[1-9][0-9])
      n="${block#c}"
      (( n >= 1 && n <= 99 )) || return 1
      printf '%d %d %d %d %d %d' \
        $((39200 + 10 * n)) $((39201 + 10 * n)) $((39202 + 10 * n)) \
        $((39203 + 10 * n)) $((39204 + 10 * n)) $((39205 + 10 * n)) ;;
    v[0-9]|v[1-9][0-9])
      n="${block#v}"
      (( n >= 1 && n <= 99 )) || return 1
      printf '%d %d %d %d %d %d' \
        $((39700 + 10 * n)) $((39701 + 10 * n)) $((39702 + 10 * n)) \
        $((39703 + 10 * n)) $((39704 + 10 * n)) $((39705 + 10 * n)) ;;
    *) return 1 ;;
  esac
}

# sb_block_lock <block> -> lock path for the block (front door for canonical)
sb_block_lock() {
  local block="$1"
  case "$block" in
    front|canonical) printf '%s' "$SB_FRONT_LOCK" ;;
    *) printf '/tmp/smalt-substrate-%s.lock' "$block" ;;
  esac
}

# ---------------------------------------------------------------------------
# Liveness / identity primitives
# ---------------------------------------------------------------------------

# sb_port_open <port> — CONNECT probe (side-effect: consumes one backlog
# slot). Used ONLY by the health poll against the real beam, which accepts
# continuously.
sb_port_open() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

# sb_port_listening <port> — lsof LISTEN probe, zero side effects. Used for
# occupancy checks and sweep drain: a connect probe can false-negative
# against a pathological listener whose accept backlog is full.
sb_port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

sb_ports_all_open() {
  local p
  for p in "$@"; do sb_port_open "$p" || return 1; done
}

sb_ports_all_listening() {
  local p
  for p in "$@"; do sb_port_listening "$p" || return 1; done
}

# sb_listener_pids <port> -> newline-separated LISTEN pids
sb_listener_pids() {
  lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sort -u
}

sb_is_beamish() {
  local pid="$1" cmd
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  case "$cmd" in *beam*|*mix*) return 0 ;; *) return 1 ;; esac
}

# sb_sweep_block <block> <ports...> — SIGTERM beam/mix LISTENers on the
# block's ports, bounded drain (default 10s), poll every 200ms. Returns
# 0 when all ports drain, 1 when ports remain occupied after the deadline
# (caller fails closed: exit 3).
sb_sweep_block() {
  local block="$1"; shift
  local port pid drained deadline
  for port in "$@"; do
    for pid in $(sb_listener_pids "$port"); do
      if sb_is_beamish "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
      else
        sb_log "SWEEP" "$block port $port held by non-beam pid $pid ($(ps -o command= -p "$pid" 2>/dev/null)) — not killed, will fail closed"
      fi
    done
  done
  deadline=$(( $(date +%s) + SB_SWEEP_DRAIN ))
  while :; do
    drained=1
    for port in "$@"; do
      sb_port_listening "$port" && drained=0
    done
    [ "$drained" -eq 1 ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# sb_marker_path <block>
sb_marker_path() { printf '%s/%s.boot.json' "$SB_MARKERS_DIR" "$1"; }

# sb_marker_valid <block> <arm_port> <auth> -> 0 iff marker present, fresh,
# pid is a live ARM-port listener, and auth matches.
sb_marker_valid() {
  local block="$1" arm_port="$2" auth="$3" mp now pid marker_auth booted
  mp="$(sb_marker_path "$block")"
  [ -r "$mp" ] || return 1
  sb_now_epoch
  now=$_SB_NOW
  sb_marker_field "$mp" booted || return 1
  booted=$_SB_FIELD
  sb_marker_field "$mp" pid || return 1
  pid=$_SB_FIELD
  sb_marker_field "$mp" auth || return 1
  marker_auth=$_SB_FIELD
  [ -n "$pid" ] && [ "$pid" -eq "$pid" ] 2>/dev/null || return 1
  [ $(( now - ${booted:-0} )) -le "$SB_MAX_REUSE_AGE" ] || return 1
  case "$marker_auth" in anonymous|enforce) ;; *) return 1 ;; esac
  [ "$marker_auth" = "$auth" ] || { sb_log "GUARD" "$block auth mismatch: marker=$marker_auth requested=$auth — sweep+fresh"; return 1; }
  sb_pid_listens_on "$pid" "$arm_port"
}

# Integer field extraction without jq dependency.
sb_marker_field() {
  local file="$1" key="$2" line val
  line="$(sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9A-Za-z_.-]*\)"\{0,1\}.*/\1/p' "$file" | head -1)"
  [ -n "$line" ] || return 1
  _SB_FIELD="$line"
  return 0
}

sb_now_epoch() { _SB_NOW="$(date +%s)"; }

# sb_pid_listens_on <pid> <port>
sb_pid_listens_on() {
  local pid="$1" port="$2"
  kill -0 "$pid" 2>/dev/null || return 1
  lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

sb_log() {
  local tag="$1"; shift
  printf '[substrate-boot][%s] %s\n' "$tag" "$*" >&2
}

# ---------------------------------------------------------------------------
# fd-9 lock discipline
#
# Lock order (acyclic): substrate.lock (front door) > block lock > any other.
# A lane touches exactly ONE lock here — the canonical block takes the front
# door, every lane block takes only its own — so no cycle is constructible.
# The lock is acquired on fd 9 and held ONLY while spawning + verifying
# health (per-WINDOW, matching scripts/substrate.sh); the substrate itself is
# spawned with `9>&-` and detached into its own session.
# ---------------------------------------------------------------------------

# sb_lock_acquire <lock_path> — acquires exclusive flock on fd 9. Caller MUST
# close fd 9 (exec 9>&-) when done; sb_lock_release does that.
sb_lock_acquire() {
  local lock="$1"
  exec 9>"$lock" || { sb_log "FAIL" "cannot open lock $lock"; return 1; }
  if ! flock -w "$SB_LOCK_WAIT" 9; then
    exec 9>&-
    sb_log "FAIL" "lock timeout: $lock not acquired within ${SB_LOCK_WAIT}s (holder: lsof $lock)"
    return 3
  fi
  return 0
}

sb_lock_release() { exec 9>&- 9<&- 2>/dev/null || true; }

# sb_assert_no_fd9_leak <child_pid> <lock_path> — lsof-prove that no
# descendant of the spawn (spawn -> mix -> beam, 3 levels like
# scripts/substrate.sh tree_pids) inherited the lock file on any fd.
# Any holder => kill spawn tree, typed FAIL, exit 2 (per task: typed FAIL).
sb_assert_no_fd9_leak() {
  local spawn_pid="$1" lock="$2" p g desc
  local -a descendants=("$spawn_pid")
  for p in $(pgrep -P "$spawn_pid" 2>/dev/null); do
    descendants+=("$p")
    for g in $(pgrep -P "$p" 2>/dev/null); do descendants+=("$g"); done
  done
  for desc in "${descendants[@]}"; do
    if lsof -a -p "$desc" "$lock" >/dev/null 2>&1; then
      sb_log "FAIL" "FD9-LEAK: pid $desc (descendant of spawn $spawn_pid) holds $lock — killing spawn tree"
      kill -TERM "$desc" 2>/dev/null || true
      kill -KILL "-$spawn_pid" 2>/dev/null || true
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# TLS gate
# ---------------------------------------------------------------------------

sb_tls_gate() {
  local cert_dir="${SMALT_CERT_DIR:-$SB_REPO_DIR/.smalt/tls}"
  SB_CA_CERT="$cert_dir/ca-cert.pem"
  SB_CERT_FILE="$cert_dir/dev-cert.pem"
  SB_KEY_FILE="$cert_dir/dev-key.pem"
  local f
  for f in "$SB_CA_CERT" "$SB_CERT_FILE" "$SB_KEY_FILE"; do
    [ -r "$f" ] || {
      sb_log "REFUSED" "missing TLS material $f — hint: bash scripts/gen_dev_cert.sh"
      return 1
    }
  done
  export SMALT_TLS_CERTFILE="$SB_CERT_FILE" SMALT_TLS_KEYFILE="$SB_KEY_FILE" SSL_CERT_FILE="$SB_CA_CERT"
  return 0
}

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

# sb_spawn_substrate <block> <auth> <amqp> <eh> <arm> <egress> <tls> <mcp> <log>
# Boot-eval shape lifted from ts-run.mjs: put_envs then
# `{:ok,_} = Application.ensure_all_started(:smalt)`.
sb_spawn_substrate() {
  local block="$1" auth="$2" amqp="$3" eh="$4" arm="$5" egress="$6" tls="$7" mcp="$8" log="$9"
  local shared_key
  shared_key="$(head -c 48 /dev/urandom | base64)"
  # Bridge operator SMALT_* rate-limit knobs into app env before start.
  # Mechanism (KD-110 defect): the ARM throttle plug reads
  # Application.get_env(:smalt, :arm_rate_limit) directly (router.ex), NOT the
  # env-first accessor Smalt.Config.arm_rate_limit/0 — so SMALT_ARM_RATE_LIMIT
  # in System.get_env was silently ignored under substrate-ctl boots. Bridging
  # here makes the ctl boot env-obedient without touching the router.
  local rate_putenvs="" v
  for v in ARM_RATE_LIMIT COSMOS_RU_LIMIT; do
    eval "local val=\"\${SMALT_${v}:-}\""
    case "$val" in
      ''|*[!0-9]*) : ;;  # unset or non-integer: leave app env untouched
      *) rate_putenvs+="Application.put_env(:smalt, :$(echo "$v" | tr 'A-Z' 'a-z'), $val); " ;;
    esac
  done
  local SB_RATE_LIMIT_PUTENVS="$rate_putenvs"
  local boot_eval
  boot_eval="$(cat <<EOE
Application.put_env(:smalt, :sb_shared_key, "${shared_key}");
Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${amqp}");
Application.put_env(:smalt, :amqp_port, ${amqp});
Application.put_env(:smalt, :event_hubs_port, ${eh});
Application.put_env(:smalt, :arm_port, ${arm});
Application.put_env(:smalt, :egress_port, ${egress});
Application.put_env(:smalt, :arm_tls_port, ${tls});
Application.put_env(:smalt, :mcp_port, ${mcp});
Application.put_env(:smalt, :auth_mode, :${auth});
$SB_RATE_LIMIT_PUTENVS{:ok, _} = Application.ensure_all_started(:smalt)
EOE
)"
  mkdir -p "$SB_LOGS_DIR"
  : >"$log"
  ( cd "$SB_REPO_DIR" && MIX_ENV=test exec mix run --no-start --no-halt -e "$boot_eval" ) \
    9>&- >>"$log" 2>&1 &
  _SB_SPAWN_PID=$!
  # Lock fd 9 explicitly closed at spawn; the driver survives the parent
  # shell (bash does not HUP background jobs on normal exit), supervision is
  # via sb_wait_health + the state file, never job-table detachment.
  return 0
}

# sb_wait_health <arm_port> <spawn_pid> <log> <ports...> — bounded 250ms
# poll: all 6 ports accept AND curl ARM health 200. Death of spawn =>
# SUBSTRATE_DIED with a 30-line log tail. Deadline expiry => SUBSTRATE_TIMEOUT.
sb_wait_health() {
  local arm="$1" spawn_pid="$2" log="$3"; shift 3
  local ports=("$@") deadline
  sb_now_epoch
  deadline=$(( _SB_NOW + SB_UP_TIMEOUT ))
  while :; do
    if ! kill -0 "$spawn_pid" 2>/dev/null; then
      sb_log "FAIL" "SUBSTRATE_DIED: spawn pid $spawn_pid exited pre-ready — last 30 lines of $log:"
      tail -n 30 "$log" >&2 || true
      return 2
    fi
    if sb_ports_all_open "${ports[@]}" && \
       [ "$(curl -fsS -o /dev/null -w '%{http_code}' \
            "http://127.0.1:${arm}${SB_ARM_HEALTH_PATH}" 2>/dev/null)" = "200" ]; then
      return 0
    fi
    sb_now_epoch
    [ "$_SB_NOW" -ge "$deadline" ] && {
      sb_log "FAIL" "SUBSTRATE_TIMEOUT: not healthy within ${SB_UP_TIMEOUT}s — last 30 lines of $log:"
      tail -n 30 "$log" >&2 || true
      return 2
    }
    sleep 0.25
  done
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# sb_up <block> <auth> [fresh] — reuse-else-sweep-else-boot under the block's
# lock (fd-9 discipline). Emits the JSON receipt as the LAST stdout line:
#   {block,ports,pid,reused,marker,auth}
# Exit: 0 up/reused, 1 refused, 2 died/timeout, 3 lock-timeout-or-occupied.
sb_up() {
  local block="$1" auth="${2:-enforce}" fresh="${3:-}"
  local -a ports
  sb_block_ports "$block" >/dev/null || { sb_log "REFUSED" "unknown block '$block'"; return 1; }
  read -r -a ports <<<"$(sb_block_ports "$block")"
  local arm="${ports[2]}" lock log marker pid
  lock="$(sb_block_lock "$block")"
  mkdir -p "$SB_MARKERS_DIR"
  marker="$(sb_marker_path "$block")"
  log="$SB_LOGS_DIR/$block.log"

  if [ -z "$fresh" ] && sb_marker_valid "$block" "$arm" "$auth" && sb_ports_all_listening "${ports[@]}"; then
    sb_marker_field "$marker" pid || true
    pid=$_SB_FIELD
    _sb_receipt "$block" "${ports[*]}" "$pid" true "$marker" "$auth"
    return 0
  fi

  sb_lock_acquire "$lock"
  local lrc=$?
  if [ "$lrc" -ne 0 ]; then
    [ "$lrc" -eq 3 ] && return 3
    return 1
  fi
  # Re-check identity under the lock (another lane may have just booted it).
  if [ -z "$fresh" ] && sb_marker_valid "$block" "$arm" "$auth" && sb_ports_all_listening "${ports[@]}"; then
    sb_marker_field "$marker" pid || true
    pid=$_SB_FIELD
    sb_lock_release
    _sb_receipt "$block" "${ports[*]}" "$pid" true "$marker" "$auth"
    return 0
  fi
  # Identity unverifiable or --fresh: sweep beamish squatters, fail closed
  # if any port stays occupied.
  if sb_ports_any_open "${ports[@]}"; then
    if ! sb_sweep_block "$block" "${ports[@]}"; then
      sb_log "FAIL" "ports still occupied after sweep: ${ports[*]}"
      sb_lock_release
      return 3
    fi
  fi

  sb_tls_gate || { sb_lock_release; return 1; }

  sb_spawn_substrate "$block" "$auth" "${ports[@]}" "$log"
  pid=$_SB_SPAWN_PID
  sb_wait_health "$arm" "$pid" "$log" "${ports[@]}"
  local hrc=$?
  if [ "$hrc" -ne 0 ]; then
    sb_lock_release
    return "$hrc"
  fi
  # fd-9 leak assert (lsof proof). Nonzero holders => kill + typed FAIL.
  if ! sb_assert_no_fd9_leak "$pid" "$lock"; then
    sb_lock_release
    rm -f "$marker"
    return 2
  fi
  sb_write_marker "$block" "${ports[*]}" "$pid" "$auth" "$log"
  sb_lock_release
  _sb_receipt "$block" "${ports[*]}" "$pid" false "$marker" "$auth"
  return 0
}

sb_ports_any_open() {
  local p
  for p in "$@"; do sb_port_listening "$p" && return 0; done
  return 1
}

sb_write_marker() {
  local block="$1" ports="$2" pid="$3" auth="$4" log="$5"
  sb_now_epoch
  printf '{"block": "%s", "ports": [%s], "pid": %s, "auth": "%s", "booted": %s, "log": "%s"}\n' \
    "$block" "$(sb_ports_json_array "$ports")" "$pid" "$auth" "$_SB_NOW" "$log" >"$(sb_marker_path "$block")"
}

_sb_receipt() {
  local block="$1" ports="$2" pid="$3" reused="$4" marker="$5" auth="$6"
  printf '{"block": "%s", "ports": [%s], "pid": %s, "reused": %s, "marker": "%s", "auth": "%s"}\n' \
    "$block" "$(sb_ports_json_array "$ports")" "$pid" "$reused" "$marker" "$auth"
}

# sb_ports_json_array "1 2 3" -> "1, 2, 3" (valid JSON array body)
sb_ports_json_array() {
  local out="" p
  for p in $1; do out+="${out:+, }${p}"; done
  printf '%s' "$out"
}

# sb_down <block> <mode> — mode=owner: kill only the pid named in a VALID
# marker (identity-guarded teardown). mode=sweep: beamish sweep of the
# block's ports.
sb_down() {
  local block="$1" mode="${2:-sweep}" auth="${SB_AUTH:-enforce}"
  local -a ports
  sb_block_ports "$block" >/dev/null || { sb_log "REFUSED" "unknown block '$block'"; return 1; }
  read -r -a ports <<<"$(sb_block_ports "$block")"
  local lock marker pid arm="${ports[2]}"
  lock="$(sb_block_lock "$block")"
  marker="$(sb_marker_path "$block")"
  sb_lock_acquire "$lock"
  local lrc=$?
  if [ "$lrc" -ne 0 ]; then
    [ "$lrc" -eq 3 ] && return 3
    return 1
  fi
  if [ "$mode" = "owner" ]; then
    if sb_marker_valid "$block" "$arm" "$auth"; then
      sb_marker_field "$marker" pid || true
      pid=$_SB_FIELD
      kill -TERM "$pid" 2>/dev/null || true
      local deadline=$(( $(date +%s) + 10 ))
      while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.2; done
      kill -KILL "$pid" 2>/dev/null || true
    else
      sb_log "FAIL" "owner-mode down refused: marker identity unverifiable for $block (use --mode sweep)"
      sb_lock_release
      return 1
    fi
  else
    sb_sweep_block "$block" "${ports[@]}" || { sb_lock_release; return 3; }
  fi
  rm -f "$marker"
  sb_lock_release
  sb_log "DOWN" "block $block down (mode=$mode)"
  return 0
}

# sb_status <block> — one human line + trailing key=value status to stdout.
sb_status() {
  local block="$1" auth="${SB_AUTH:-enforce}"
  local -a ports
  sb_block_ports "$block" >/dev/null || { sb_log "REFUSED" "unknown block '$block'"; return 1; }
  read -r -a ports <<<"$(sb_block_ports "$block")"
  local arm="${ports[2]}" marker pid="" up=0 verified=0 health="ERR"
  marker="$(sb_marker_path "$block")"
  sb_ports_all_listening "${ports[@]}" && up=1
  if [ "$up" -eq 1 ] && sb_marker_valid "$block" "$arm" "$auth"; then
    verified=1
    sb_marker_field "$marker" pid || true
    pid=$_SB_FIELD
    health="$(curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.1:${arm}${SB_ARM_HEALTH_PATH}" 2>/dev/null || echo ERR)"
  fi
  printf 'block=%s ports=%s up=%d identity_verified=%d pid=%s health=%s\n' \
    "$block" "${ports[*]}" "$up" "$verified" "${pid:-none}" "$health"
  return 0
}

# sb_verify <block> — ports open + ARM health 200 + marker identity valid.
sb_verify() {
  local block="$1" auth="${SB_AUTH:-enforce}"
  local -a ports
  sb_block_ports "$block" >/dev/null || return 1
  read -r -a ports <<<"$(sb_block_ports "$block")"
  local arm="${ports[2]}"
  sb_ports_all_open "${ports[@]}" || { sb_log "FAIL" "verify $block: not all ports open"; return 2; }
  [ "$(curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.1:${arm}${SB_ARM_HEALTH_PATH}" 2>/dev/null)" = "200" ] \
    || { sb_log "FAIL" "verify $block: ARM health != 200"; return 2; }
  sb_marker_valid "$block" "$arm" "$auth" || { sb_log "FAIL" "verify $block: marker identity unverifiable"; return 2; }
  return 0
}

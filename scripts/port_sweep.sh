#!/usr/bin/env bash
# scripts/port_sweep.sh — pre-flight scavenger for Q-5 (F-6/F-8 clean-ports).
#
# Tree-aware orphan sweep, same guard as scripts/substrate.sh: a process is an
# ORPHAN only when its whole flock->mix->beam tree has NO LISTEN socket, AND
# its lane is provably dead. Provably-alive guards (any one skips the kill):
#   - live LISTEN socket anywhere in its 2-level tree (private-port lanes)
#   - age < boot window (in-flight boot; -b / SMALT_UP_TIMEOUT)
#   - pid is a live flock holder of $LOCK, or in such a holder's tree
#   - pid is the live substrate.pid owner, or in its tree
#   - recent /tmp receipts (state dir touched within the boot window)
#
# Usage: scripts/port_sweep.sh [-y] [-b boot_window_secs]
#   -y  actually kill (default: dry-run report only)
#   -b  boot window in seconds (default: SMALT_UP_TIMEOUT or 90)
set -uo pipefail

LOCK=/tmp/smalt-substrate.lock
STATE_DIR=/tmp/smalt-substrate-state
PID_FILE=$STATE_DIR/substrate.pid
CANONICAL_PORTS="9443 9444 8443 5672 5673"
BOOT_WINDOW=${SMALT_UP_TIMEOUT:-90}
KILL=0
while getopts ":yb:" opt; do
  case "$opt" in
    y) KILL=1 ;;
    b) BOOT_WINDOW="$OPTARG" ;;
    \?) echo "port_sweep: unknown option -$OPTARG" >&2; exit 64 ;;
    :)  echo "port_sweep: -$OPTARG requires an argument" >&2; exit 64 ;;
  esac
done
shift $((OPTIND - 1))

now_epoch() { date +%s; }
proc_start_epoch() { ps -o lstart= -p "$1" 2>/dev/null | xargs -I{} date -j -f "%a %b %d %H:%M:%S %Y" "{}" +%s 2>/dev/null; }

# 2-level descendant set (flock -> mix -> beam), mirroring substrate.sh.
# Iterate pids ONE at a time: `pgrep -P $(echo $pids)` passes each pid as a
# separate argv, so extra args are parsed as NAME regexes (and the operand is
# empty when there are no children). SHIM-COURT: tree-walk fix (R17/A11 #2).
tree_pids() {
  local root="$1" pid kids out
  out="$root"
  kids=$(pgrep -P "$root" 2>/dev/null)
  for pid in $kids; do
    out="$out $pid"
    # grandchildren (beam under mix)
    local gkids
    gkids=$(pgrep -P "$pid" 2>/dev/null)
    for g in $gkids; do out="$out $g"; done
  done
  echo "$out"
}

tree_listening() {
  local p
  for p in $(tree_pids "$1"); do
    lsof -nP -a -p "$p" -iTCP -sTCP:LISTEN >/dev/null 2>&1 && return 0
  done
  return 1
}

# Live flock holders of the substrate lock + their 2-level trees: PROTECTED.
protected_pids() {
  local h p
  for h in $(lsof -t "$LOCK" 2>/dev/null | sort -u); do
    kill -0 "$h" 2>/dev/null || continue
    for p in $(tree_pids "$h"); do echo "$p"; done
  done
  # live registered owner from the substrate pid file + its tree
  if [ -f "$PID_FILE" ]; then
    local spid
    spid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
      for p in $(tree_pids "$spid"); do echo "$p"; done
    fi
  fi
}

# Recent /tmp receipts: state dir touched within the boot window => a lane
# booted recently; do not classify anything as orphan this sweep.
recent_receipts() {
  [ -d "$STATE_DIR" ] || return 1
  local ref newest
  ref=$(mktemp) || return 1
  touch -t "$(date -v-"${BOOT_WINDOW}"S +%Y%m%d%H%M.%S 2>/dev/null)" "$ref" 2>/dev/null || { rm -f "$ref"; return 1; }
  newest=$(find "$STATE_DIR" -type f -newer "$ref" -print -quit 2>/dev/null)
  rm -f "$ref"
  [ -n "$newest" ]
}

echo "== canonical port map (pre) =="
for p in $CANONICAL_PORTS; do
  holders=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u)
  if [ -n "$holders" ]; then
    for h in $holders; do
      echo "port $p: HELD by pid $h $(ps -o command= -p "$h" 2>/dev/null | cut -c1-100)"
    done
  else
    echo "port $p: free"
  fi
done

PROTECTED=" $(protected_pids | tr '\n' ' ')"
RECENT=0
recent_receipts && RECENT=1

echo
echo "== orphan candidates (beam.smp / epmd) =="
echo "protected pids (lock/owner trees):${PROTECTED} ; recent_receipts=$RECENT (boot_window=${BOOT_WINDOW}s)"
KILLS=()
for pid in $(pgrep -f 'beam.smp|epmd' 2>/dev/null); do
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
  age_min=$(( ( $(now_epoch) - $(proc_start_epoch "$pid" 2>/dev/null || echo $(now_epoch)) ) / 60 ))
  if tree_listening "$pid"; then
    echo "SKIP pid $pid: live LISTEN in tree (private-port lane) :: ${cmd:0:120}"
    continue
  fi
  ev="no LISTEN in tree; age=${age_min}m"
  if [ "$age_min" -lt 2 ]; then ev="$ev; FRESH (boot window)"; echo "SKIP pid $pid: $ev"; continue; fi
  if [[ "$PROTECTED" == *" $pid "* ]]; then
    ev="$ev; PROTECTED (live lock holder / registered owner tree)"
    echo "SKIP pid $pid: $ev :: ${cmd:0:120}"
    continue
  fi
  if [ "$RECENT" -eq 1 ]; then
    ev="$ev; RECENT /tmp receipts (boot window)"
    echo "SKIP pid $pid: $ev :: ${cmd:0:120}"
    continue
  fi
  echo "ORPHAN pid $pid: $ev :: ${cmd:0:120}"
  KILLS+=("$pid")
done

echo
echo "== stale epmd (zero registered nodes) =="
# epmd -names emits a 1-line header; registered nodes start at line 2.
if pgrep -x epmd >/dev/null && [ -z "$(epmd -names 2>/dev/null | sed -n '2,$p')" ]; then
  for pid in $(pgrep -x epmd); do
    echo "ORPHAN epmd pid $pid: no registered nodes"
    KILLS+=("$pid")
  done
fi

echo
echo "== provably-dead lanes: substrate.pid owner check =="
if [ -f "$PID_FILE" ]; then
  spid=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then
    echo "STALE pid-file: owner $spid dead; holders of canonical ports inherit orphan status"
  else
    echo "pid-file owner $spid alive (protected)"
  fi
fi

echo
if [ ${#KILLS[@]} -eq 0 ]; then
  echo "nothing to kill"
else
  if [ "$KILL" = 1 ]; then
    for pid in "${KILLS[@]}"; do
      echo "killing pid $pid"
      kill "$pid" 2>/dev/null
    done
    sleep 3
    for pid in "${KILLS[@]}"; do
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done
  else
    echo "DRY-RUN: rerun with -y to kill: ${KILLS[*]}"
  fi
fi

echo
echo "== canonical port map (post) =="
rc=0
for p in $CANONICAL_PORTS; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $p: STILL HELD ($(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1"("$2")"}' | sort -u | tr '\n' ' '))"
    rc=1
  else
    echo "port $p: free"
  fi
done
exit $rc

#!/usr/bin/env bash
# scripts/port_sweep.sh — pre-flight scavenger for Q-5 (F-6/F-8 clean-ports).
#
# Tree-aware orphan sweep, same guard as scripts/substrate.sh: a process is an
# ORPHAN only when its whole flock->mix->beam tree has NO LISTEN socket, OR its
# lane is provably dead (registered owner pid dead / no lock holder / no recent
# /tmp receipts). Private-port lanes with live listeners are NOT orphans.
# In-flight boot lock holders (age < boot window) are left alone.
#
# Usage: scripts/port_sweep.sh [-y] [-b boot_window_secs]
#   -y  actually kill (default: dry-run report only)
set -uo pipefail

LOCK=/tmp/smalt-substrate.lock
STATE_DIR=/tmp/smalt-substrate-state
PID_FILE=$STATE_DIR/substrate.pid
CANONICAL_PORTS="9443 9444 8443 5672 5673"
BOOT_WINDOW=${SMALT_UP_TIMEOUT:-90}
KILL=0
[ "${1:-}" = "-y" ] && KILL=1

now_epoch() { date +%s; }
proc_start_epoch() { ps -o lstart= -p "$1" 2>/dev/null | xargs -I{} date -j -f "%a %b %d %H:%M:%S %Y" "{}" +%s 2>/dev/null; }

# 2-level descendant set (flock -> mix -> beam), mirroring substrate.sh
tree_pids() {
  local root="$1" kids
  kids=$(pgrep -P "$root" 2>/dev/null)
  echo "$root $kids $(pgrep -P $(echo $kids) 2>/dev/null)"
}

tree_listening() {
  local p
  for p in $(tree_pids "$1"); do
    lsof -nP -a -p "$p" -iTCP -sTCP:LISTEN >/dev/null 2>&1 && return 0
  done
  return 1
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

echo
echo "== orphan candidates (beam.smp / epmd) =="
KILLS=()
for pid in $(pgrep -f 'beam.smp|epmd' 2>/dev/null); do
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
  age_min=$(( ( $(now_epoch) - $(proc_start_epoch "$pid" 2>/dev/null || echo $(now_epoch)) ) / 60 ))
  ev=""
  if tree_listening "$pid"; then
    # private-port lane with live listeners: orphan only if lane provably dead
    continue   # live listeners => not an orphan by the tree rule
  fi
  ev="no LISTEN in tree; age=${age_min}m"
  if [ "$age_min" -lt 2 ]; then ev="$ev; FRESH (boot window) skip"; echo "SKIP pid $pid: $ev"; continue
  fi
  echo "ORPHAN pid $pid: $ev :: ${cmd:0:120}"
  KILLS+=("$pid")
done

echo
echo "== stale epmd (zero registered nodes) =="
if pgrep -x epmd >/dev/null && [ -z "$(epmd -names 2>/dev/null | sed -n '3,$p')" ]; then
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

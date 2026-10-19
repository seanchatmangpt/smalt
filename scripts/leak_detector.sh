#!/usr/bin/env bash
# scripts/leak_detector.sh — live orphan-process detector (AZB-24 envelope
# lane, Phase 1). Wraps scripts/port_sweep.sh for beam.smp/epmd (the tree
# law lives THERE — this script never duplicates the kill/classification
# logic) and extends the same law to node processes:
#
#   a beam/epmd/node process is an ORPHAN only when its whole 2-level tree
#   (pid -> children -> grandchildren) has NO LISTEN socket, AND it holds
#   no smalt lock and is not in a lock-holder's tree, AND it is older than
#   the boot window.
#
# Detection only — never kills (that is `scripts/port_sweep.sh -y`).
# Exit 0 = clean, 1 = orphans detected, 2 = port_sweep wrapper failure.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCK=/tmp/smalt-substrate.lock
STATE_DIR=/tmp/smalt-substrate-state
PID_FILE=$STATE_DIR/substrate.pid
BOOT_WINDOW=${SMALT_UP_TIMEOUT:-90}

now_epoch() { date +%s; }
proc_start_epoch() { ps -o lstart= -p "$1" 2>/dev/null | xargs -I{} date -j -f "%a %b %d %H:%M:%S %Y" "{}" +%s 2>/dev/null; }

tree_pids() {
  local root="$1" pid out
  out="$root"
  for pid in $(pgrep -P "$root" 2>/dev/null); do
    out="$out $pid"
    local g
    for g in $(pgrep -P "$pid" 2>/dev/null); do out="$out $g"; done
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

protected_pids() {
  local h p
  for h in $(lsof -t "$LOCK" 2>/dev/null | sort -u); do
    kill -0 "$h" 2>/dev/null || continue
    for p in $(tree_pids "$h"); do echo "$p"; done
  done
  if [ -f "$PID_FILE" ]; then
    local spid
    spid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
      for p in $(tree_pids "$spid"); do echo "$p"; done
    fi
  fi
}

recent_receipts() {
  [ -d "$STATE_DIR" ] || return 1
  local ref newest
  ref=$(mktemp) || return 1
  touch -t "$(date -v-"${BOOT_WINDOW}"S +%Y%m%d%H%M.%S 2>/dev/null)" "$ref" 2>/dev/null || { rm -f "$ref"; return 1; }
  newest=$(find "$STATE_DIR" -type f -newer "$ref" -print -quit 2>/dev/null)
  rm -f "$ref"
  [ -n "$newest" ]
}

echo "== leak detector: node-process pass (beam/epmd delegated to port_sweep) =="
PROTECTED=" $(protected_pids | tr '\n' ' ')"
RECENT=0
recent_receipts && RECENT=1
echo "protected pids (lock/owner trees):${PROTECTED} ; recent_receipts=$RECENT (boot_window=${BOOT_WINDOW}s)"
ORPHANS=()
for pid in $(pgrep -f 'node( |$)|node$' 2>/dev/null); do
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
  [[ "$cmd" == *"leak_detector"* ]] && continue
  age=$(( $(now_epoch) - $(proc_start_epoch "$pid" 2>/dev/null || echo $(now_epoch)) ))
  if tree_listening "$pid"; then
    echo "SKIP pid $pid: live LISTEN in tree :: ${cmd:0:110}"
    continue
  fi
  ev="no LISTEN in tree; age=$(( age / 60 ))m"
  if [ "$age" -lt "$BOOT_WINDOW" ]; then ev="$ev; FRESH (boot window)"; echo "SKIP pid $pid: $ev"; continue; fi
  if [[ "$PROTECTED" == *" $pid "* ]]; then
    ev="$ev; PROTECTED (live lock holder / registered owner tree)"
    echo "SKIP pid $pid: $ev :: ${cmd:0:110}"
    continue
  fi
  if [ "$RECENT" -eq 1 ]; then
    ev="$ev; RECENT /tmp receipts (boot window)"
    echo "SKIP pid $pid: $ev"
    continue
  fi
  echo "ORPHAN node pid $pid: $ev :: ${cmd:0:110}"
  ORPHANS+=("$pid")
done

echo
echo "== leak detector: beam/epmd pass (port_sweep.sh, detection-only parse) =="
PSWEEP_OUT=$(bash "$REPO/scripts/port_sweep.sh" 2>&1)
PS_RC=$?
printf '%s\n' "$PSWEEP_OUT" | grep -E '^(ORPHAN|SKIP|STALE|port .*:|== )' || true
if [ $PS_RC -ne 0 ] && [ $PS_RC -ne 1 ]; then
  echo "leak_detector: port_sweep wrapper failure (rc=$PS_RC)"
  exit 2
fi
BEAM_ORPHANS=$(printf '%s\n' "$PSWEEP_OUT" | grep -c '^ORPHAN ' || true)

echo
TOTAL=$(( ${#ORPHANS[@]} + BEAM_ORPHANS ))
if [ "$TOTAL" -eq 0 ]; then
  echo "LEAK-DETECTOR PASS — 0 orphans (node + beam/epmd passes)"
  exit 0
fi
echo "LEAK-DETECTOR FAIL — $TOTAL orphan(s) detected (node=${#ORPHANS[@]}, beam/epmd=$BEAM_ORPHANS); remediate via scripts/port_sweep.sh -y"
exit 1

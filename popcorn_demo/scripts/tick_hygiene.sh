#!/usr/bin/env bash
# tick_hygiene.sh — overnight-loop disk guard (ENOSPC wall must not recur).
# S12 lane; owned file, never touches scripts/bench/ shared infra.
#
# (1) df check: avail < 5GiB -> loud WARN + aggressive reclaim, re-report;
#     avail < 1GiB -> exit 2 (page-level loud failure for the cron).
# (2) crash-dump sweep (erl_crash.dump *.core).
# (3) orphan-beam census via scripts/port_sweep.sh dry-run (report only, never kill).
# (4) lane-root count report.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT_SWEEP="$(cd "$ROOT/.." && pwd)/scripts/port_sweep.sh"
RECLAIMED=0

avail_gib() { df -g / | awk 'NR==2 {print $4}'; }

echo "=== tick_hygiene $(date -u +%Y-%m-%dT%H:%M:%SZ) root=$ROOT ==="

# (2) crash-dump sweep
DUMPS="$(find "$ROOT" -maxdepth 2 \( -name 'erl_crash.dump*' -o -name '*.core' \) 2>/dev/null || true)"
if [ -n "$DUMPS" ]; then
  echo "$DUMPS" | while IFS= read -r f; do [ -f "$f" ] && rm -f "$f" && echo "SWEEP crash-dump: $f"; done
else
  echo "SWEEP crash-dumps: none"
fi

# (1) disk guard
AV="$(avail_gib)"
echo "DF avail=${AV}GiB"
if [ "$AV" -lt 1 ]; then
  echo "PAGE: available disk ${AV}GiB < 1GiB — refusing to continue, cron must page"
  exit 2
fi
if [ "$AV" -lt 5 ]; then
  echo "WARN: available disk ${AV}GiB < 5GiB — aggressive reclaim"
  for d in "$ROOT"/_build-*; do
    [ -d "$d" ] || continue
    SZ="$(du -sg "$d" | awk '{print $1}')"
    rm -rf "$d"
    echo "RECLAIM lane-root: $d (${SZ}GiB)"
    RECLAIMED=$((RECLAIMED + 1))
  done
  find /tmp/wave -maxdepth 1 -type f -size +1M -exec rm -f {} \; -print 2>/dev/null | sed 's/^/RECLAIM tmp-scratch: /' || true
  AV="$(avail_gib)"
  echo "DF re-report avail=${AV}GiB (reclaimed $RECLAIMED lane roots)"
  [ "$AV" -lt 1 ] && { echo "PAGE: still <1GiB after reclaim"; exit 2; }
fi

# (3) orphan-beam census — dry-run, report only
echo "--- port_sweep dry-run census ---"
if [ -x "$PORT_SWEEP" ]; then
  "$PORT_SWEEP" 2>&1 || echo "NOTE: port_sweep exit $? (report-only, no eviction performed)"
else
  echo "NOTE: port_sweep.sh not found/executable at $PORT_SWEEP"
fi

# (4) lane-root count report
COUNT="$(find "$ROOT" -maxdepth 1 -type d -name '_build-*' | wc -l | tr -d ' ')"
SIZE="$(du -sg "$ROOT"/_build-* 2>/dev/null | awk '{s+=$1} END {print s+0}')"
echo "LANE-ROOTS: count=$COUNT total=${SIZE}GiB"

AV="$(avail_gib)"
echo "=== tick_hygiene PASS avail=${AV}GiB ==="
exit 0

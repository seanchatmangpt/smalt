#!/usr/bin/env bash
# scripts/wave_telemetry.sh — wave-level wall-clock telemetry (lane S-8, v26.10.15 idea).
#
# The next baseline reads a file, not archaeology: lanes record their own
# queue/compile/substrate/test wall-clock waits as JSONL rows in the same
# bench results directory shape as scripts/bench/lib.sh rows.
#
# Usage:
#   scripts/wave_telemetry.sh emit [--out <path>]
#       Reads env vars set by the lane at exit:
#         LANE_ID         (required, non-empty)
#         QUEUE_WAIT_S    (seconds, number)
#         COMPILE_WAIT_S  (seconds, number)
#         SUBSTRATE_WAIT_S(seconds, number)
#         TEST_WALL_S     (seconds, number)
#         RESULT          (pass|fail)
#       Appends one row:
#         {lane, queue_wait_s, compile_wait_s, substrate_wait_s, test_wall_s,
#          result, total_s, ts}
#       Malformed env (missing LANE_ID, non-numeric waits, bad RESULT):
#       skip-loud — prints to stderr, writes nothing, exits 0 (a lane must
#       not fail because telemetry failed).
#
#   scripts/wave_telemetry.sh wrap -- <command...>
#       Records wall time around any command and emits with TEST_WALL_S.
#       Propagates the command's exit status as RESULT.
#
# Schema (keys validated on emit; rows live next to bench rows):
#   docs/jira/v26.10.14/bench/wave-telemetry.jsonl
#
# Spec: docs/jira/v26.10.15/WAVE_TELEMETRY.md

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_OUT="$REPO/docs/jira/v26.10.14/bench/wave-telemetry.jsonl"

die_loud() { # skip-loud: warn, never break the lane
  echo "wave_telemetry[emit]: $1" >&2
}

is_num() {
  case "$1" in
    ''|*[!0-9.+-]*) return 1 ;;
    *) return 0 ;;
  esac
}

emit_row() {
  local out="$1"
  local lane="${LANE_ID:-}"
  [ -n "$lane" ] || { die_loud "LANE_ID missing/empty — skipping emit"; return 0; }

  local q="${QUEUE_WAIT_S:-0}" c="${COMPILE_WAIT_S:-0}" s="${SUBSTRATE_WAIT_S:-0}" t="${TEST_WALL_S:-0}"
  for v in "$q" "$c" "$s" "$t"; do
    is_num "$v" || { die_loud "non-numeric wait value '$v' — skipping emit"; return 0; }
  done

  local result="${RESULT:-}"
  case "$result" in
    pass|fail) : ;;
    *) die_loud "RESULT must be pass|fail, got '${result:-<unset>}' — skipping emit"; return 0 ;;
  esac

  local total
  total=$(python3 -c "print(f'{$q + $c + $s + $t:.3f}')")

  mkdir -p "$(dirname "$out")"
  printf '{"lane":"%s","queue_wait_s":%s,"compile_wait_s":%s,"substrate_wait_s":%s,"test_wall_s":%s,"result":"%s","total_s":%s,"ts":"%s"}\n' \
    "$lane" "$q" "$c" "$s" "$t" "$result" "$total" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >>"$out"
}

cmd_emit() {
  local out="$DEFAULT_OUT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      *) die_loud "unknown emit arg '$1'"; shift ;;
  esac
  done
  emit_row "$out"
}

cmd_wrap() {
  local out=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      *) echo "usage: wave_telemetry.sh wrap [--out <path>] -- <command...>" >&2; return 2 ;;
    esac
  done
  [ "${1:-}" = "--" ] && shift
  [ -n "$out" ] && out="--out $out" || out=""
  [ $# -gt 0 ] || { echo "wrap: no command given after --" >&2; return 2; }
  local t0 t1 rc=0
  t0=$(python3 -c 'import time; print(time.time())')
  "$@" || rc=$?
  t1=$(python3 -c 'import time; print(time.time())')
  TEST_WALL_S=$(python3 -c "print(f'{$t1 - $t0:.3f}')") \
  RESULT=$([ $rc -eq 0 ] && echo pass || echo fail) \
    "$0" emit $out
  return $rc
}

cmd_report() {
  local out="$DEFAULT_OUT"
  [ "${1:-}" = "--out-file" ] && out="$2"
  python3 - "$out" <<'PY'
import json, sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print(f"wave-report: no telemetry at {path} — empty state, nothing recorded yet.")
    sys.exit(0)
rows = []
with open(path) as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            print(f"wave-report[WARN] malformed line {i} skipped", file=sys.stderr)
if not rows:
    print(f"wave-report: {path} exists but has no valid rows — empty state.")
    sys.exit(0)
print(f"Wave telemetry — {len(rows)} lane row(s) from {path}\n")
hdr = f"{'lane':<16}{'queue_s':>9}{'compile_s':>11}{'substr_s':>10}{'test_s':>9}{'total_s':>9}  result"
print(hdr); print("-" * len(hdr))
tot = dict.fromkeys(("queue_wait_s","compile_wait_s","substrate_wait_s","test_wall_s","total_s"), 0.0)
npass = nfail = 0
for r in sorted(rows, key=lambda r: r.get("total_s", 0), reverse=True):
    print(f"{r.get('lane','?'):<16}"
          f"{r.get('queue_wait_s',0):>9.3f}{r.get('compile_wait_s',0):>11.3f}"
          f"{r.get('substrate_wait_s',0):>10.3f}{r.get('test_wall_s',0):>9.3f}"
          f"{r.get('total_s',0):>9.3f}  {r.get('result','?')}")
    for k in tot: tot[k] += float(r.get(k, 0))
    npass += r.get("result") == "pass"; nfail += r.get("result") == "fail"
print("-" * len(hdr))
print(f"{'TOTAL':<16}{tot['queue_wait_s']:>9.3f}{tot['compile_wait_s']:>11.3f}"
      f"{tot['substrate_wait_s']:>10.3f}{tot['test_wall_s']:>9.3f}{tot['total_s']:>9.3f}"
      f"  pass={npass} fail={nfail}")
PY
}

case "${1:-}" in
  emit) shift; cmd_emit "$@" ;;
  wrap) shift; cmd_wrap "$@" ;;
  report) shift; cmd_report "$@" ;;
  *)
    echo "usage: wave_telemetry.sh emit [--out <path>] | wrap -- <command...>" >&2
    exit 2
    ;;
esac

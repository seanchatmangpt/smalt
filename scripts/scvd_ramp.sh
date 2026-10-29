#!/usr/bin/env bash
# scripts/scvd_ramp.sh — one-command SCVD tier runner (SCVD-T9).
#
# Usage: scripts/scvd_ramp.sh [tier1|tier2|tier3|all]   (default: all)
#
# Boots NOTHING. Preflight probes the LIVE substrate (ARM 9443 + data 8443);
# if either is unreachable it exits 2 (substrate down) — it never starts or
# stops a substrate (law: "stop nothing").
#
# Runs the tier harnesses:
#   tier1 -> tmp/bench/scvd_tier1.mjs      (T1 product, 16 legs)
#   tier2 -> scripts/bench/scvd_tier2.mjs  (128 workers)
#   tier3 -> scripts/bench/scvd_tier3.mjs  (512/1024/2048 threshold wall)
# A missing harness is a LOUD SKIP (never a faked pass).
#
# Exit-code contract: 0 pass / 1 tier fail / 2 substrate down / 3 skip.
# Env overrides (test seams, used to exercise down/skip paths without
# touching any other lane's files):
#   SCVD_ARM / SCVD_DATA   substrate endpoints (default loopback 9443 / 8443)
#   SCVD_T{1,2,3}_SCRIPT   harness file path override
#   SCVD_QUIET=1           suppress harness stdout in the runner log
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="$ROOT/tmp/bench"
TIER="${1:-all}"

ARM="${SCVD_ARM:-http://127.0.0.1:9443}"
DATA="${SCVD_DATA:-http://127.0.0.1:8443}"
T1="${SCVD_T1_SCRIPT:-$BENCH_DIR/scvd_tier1.mjs}"
T2="${SCVD_T2_SCRIPT:-$ROOT/scripts/bench/scvd_tier2.mjs}"
T3="${SCVD_T3_SCRIPT:-$ROOT/scripts/bench/scvd_tier3.mjs}"

# TLS twin (9444) uses the local dev CA; Node needs it explicitly. Respect a
# caller-set NODE_EXTRA_CA_CERTS, otherwise default to the repo dev CA.
export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$ROOT/.smalt/tls/ca-cert.pem}"

case "$TIER" in
  tier1|tier2|tier3|all) ;;
  *) echo "[SCVD-RAMP] usage: $0 [tier1|tier2|tier3|all] (got: $TIER)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Preflight: substrate liveness. Any HTTP status (401 included) = reachable;
# connection failure / timeout = DOWN. Boots nothing, stops nothing.
# ---------------------------------------------------------------------------
probe() {
  local code
  code="$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "$1" || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

echo "[SCVD-RAMP] preflight: ARM=$ARM data=$DATA"
if ! probe "$ARM"; then
  echo "[SCVD-RAMP] FAIL: ARM endpoint $ARM unreachable — substrate DOWN (exit 2). Runner boots nothing; start it with 'just substrate-up'." >&2
  exit 2
fi
if ! probe "$DATA"; then
  echo "[SCVD-RAMP] FAIL: data endpoint $DATA unreachable — substrate DOWN (exit 2). Runner boots nothing; start it with 'just substrate-up'." >&2
  exit 2
fi
echo "[SCVD-RAMP] substrate reachable."

want() { [ "$TIER" = "all" ] || [ "$TIER" = "$1" ]; }

VERDICT_FILE="$(mktemp)"
trap 'rm -f "$VERDICT_FILE"' EXIT

run_tier() {
  local id="$1" script="$2"
  if [ ! -f "$script" ]; then
    echo "[SCVD-RAMP] SKIP($id): harness missing: $script (loud skip, never a faked pass)" >&2
    echo SKIP > "$VERDICT_FILE"
    return 0
  fi
  echo "[SCVD-RAMP] running $id: $script" >&2
  if [ "${SCVD_QUIET:-0}" = "1" ]; then
    if ! node "$script" >/dev/null; then echo FAIL > "$VERDICT_FILE"; return 0; fi
  else
    if ! node "$script"; then echo FAIL > "$VERDICT_FILE"; return 0; fi
  fi
  echo PASS > "$VERDICT_FILE"
}

overall=0     # 0 pass / 1 fail / 3 all-skipped
ran=0 skipped=0 failed=0
declare -a verdicts=()

run_and_record() {
  local tier="$1" id="$2" script="$3"
  run_tier "$id" "$script"
  local v
  v="$(cat "$VERDICT_FILE")"
  case "$v" in PASS) ran=$((ran+1));; SKIP) skipped=$((skipped+1));; FAIL) failed=$((failed+1));; esac
  verdicts+=("$tier=$v")
}

if want tier1; then run_and_record tier1 scvd-t1 "$T1"; fi
if want tier2; then run_and_record tier2 scvd-t2 "$T2"; fi
if want tier3; then run_and_record tier3 scvd-t3 "$T3"; fi

# ---------------------------------------------------------------------------
# Aggregate tmp/bench/scvd-*.jsonl into a stdout table (latest line per file).
# ---------------------------------------------------------------------------
echo
echo "[SCVD-RAMP] SCVD ramp table (latest line per tmp/bench/scvd-*.jsonl):"
printf '%-12s %8s %12s %10s %10s %7s %16s\n' LANE N OPS/SEC P50_MS P99_MS ERRORS VERDICT
for f in "$BENCH_DIR"/scvd-*.jsonl; do
  [ -e "$f" ] || continue
  tail -n 1 "$f" | node -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const row = [
      (r.lane ?? "?").slice(0, 12), r.n ?? "-", r.ops_per_sec ?? "-",
      r.p50_ms ?? "-", r.p99_ms ?? "-", r.errors ?? "-", r.verdict ?? "-",
    ];
    console.log(row.map((c) => String(c)).join("\t"));
  ' | while IFS=$'\t' read -r lane n ops p50 p99 err verdict; do
    printf '%-12s %8s %12s %10s %10s %7s %16s\n' "$lane" "$n" "$ops" "$p50" "$p99" "$err" "$verdict"
  done
done
echo

echo "[SCVD-RAMP] verdicts: ${verdicts[*]:-none} (ran=$ran skipped=$skipped failed=$failed)"
if [ "$failed" -gt 0 ]; then
  echo "[SCVD-RAMP] FAIL: tier failure(s) (exit 1)"
  exit 1
fi
if [ "$ran" -eq 0 ]; then
  echo "[SCVD-RAMP] SKIP: no tier ran (all missing) (exit 3)"
  exit 3
fi
echo "[SCVD-RAMP] PASS"
exit 0

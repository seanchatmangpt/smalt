#!/usr/bin/env bash
# PB-1 lane driver — FOND contingency-loop latency sweep (v26.10.21).
# Native leg: Smalt.POWL2.Executor + ChangeFeed, forced stale-etag CAS
# contention 0..10 retries/settlement (self-contained beam, no port binds).
# SDK leg: real @azure/cosmos over the lane's TLS twin (39014, the 9444 twin
# seat) at identical injection rates, default SDK retry policy active.
# Emits tmp/bench/pb1-fond-sweep.jsonl only (lane law: own result file).
set -euo pipefail
BENCH_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$BENCH_REPO"
source scripts/bench/lib.sh
export PATH="$HOME/.asdf/shims:$PATH"
export MIX_BUILD_ROOT=${MIX_BUILD_ROOT:-_build-pb1}
export MIX_ENV=test

BENCH_LANE="pb1"
OUT="tmp/bench/pb1-fond-sweep.jsonl"
RECEIPTS_DIR="$BENCH_REPO/docs/jira/v26.10.21/receipts"
mkdir -p "$(dirname "$OUT")" "$RECEIPTS_DIR"
: > "$OUT"
export BENCH_LANE

MACHINE=$(bench_machine_spec)
echo "machine: $MACHINE"

# ---- SDK leg substrate (lane b1 block 39010..39015, atls=39014) -----------
bench_boot b1 || { echo "PB1 BLOCKED: bench_boot refused (port held)"; exit 2; }
export PB1_ATLS=39014 PB1_EGRESS=39011

trap 'bench_down "${BENCH_BOOT_PID:-}"' EXIT INT TERM

# ---- native leg -----------------------------------------------------------
echo "== native leg (POWL2.Executor + ChangeFeed) =="
mix run --no-start scripts/bench/pb1_fond_sweep.exs 2>&1 | tee tmp/bench/pb1-native-stdout.log

# ---- SDK leg --------------------------------------------------------------
echo "== SDK leg (@azure/cosmos over TLS twin) =="
# The bench twin runs TLS :auto — a self-signed per-seat dev cert keyed by
# port (tmp/dev-certs/dev-cert-<port>.pem), NOT the .smalt/tls dev CA chain.
# Wait for the seat cert, then pin Node to exactly that cert.
CERT="tmp/dev-certs/dev-cert-39014.pem"
for i in $(seq 1 20); do [ -f "$CERT" ] && break; sleep 0.5; done
[ -f "$CERT" ] || { echo "PB1 BLOCKED: bench twin cert $CERT never appeared"; exit 2; }
NODE_EXTRA_CA_CERTS="$BENCH_REPO/$CERT" \
  node scripts/bench/pb1_cosmos_sdk.mjs 2>&1 | tee tmp/bench/pb1-sdk-stdout.log

# ---- collect rows ---------------------------------------------------------
grep -h '^PB1ROW ' tmp/bench/pb1-native-stdout.log tmp/bench/pb1-sdk-stdout.log \
  | sed 's/^PB1ROW //' >> "$OUT"
echo "rows: $(wc -l < "$OUT" | tr -d ' ') -> $OUT"
tail -2 "$OUT"

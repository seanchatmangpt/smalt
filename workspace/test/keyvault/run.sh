#!/usr/bin/env bash
# test/keyvault/run.sh — boot a private-port substrate, compile the KV console
# client + court with tsc, run under node --test. Exit 0 pass / 1 fail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ARM_PORT="${KV_TEST_ARM_PORT:-39710}"
DATA_PORT="${KV_TEST_DATA_PORT:-39711}"
OUT="$(mktemp -d /tmp/kvconsole.XXXXXX)"
trap 'kill "${SUB_PID:-}" 2>/dev/null || true; pkill -P "${SUB_PID:-}" 2>/dev/null || true' EXIT

for p in "$ARM_PORT" "$DATA_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "run.sh: port $p held — refusing to boot" >&2; exit 3
  fi
done

EVAL="Application.put_env(:smalt, :arm_port, $ARM_PORT); \
Application.put_env(:smalt, :egress_port, $DATA_PORT); \
{:ok, _} = Application.ensure_all_started(:smalt); Process.sleep(:infinity)"

cd "$ROOT"
MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build-lane524}" MIX_ENV=test \
  mix run --no-start -e "$EVAL" --no-halt >/tmp/kvconsole-substrate.log 2>&1 &
SUB_PID=$!

for i in $(seq 1 120); do
  lsof -nP -iTCP:"$ARM_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
  kill -0 "$SUB_PID" 2>/dev/null || { echo "substrate died; log /tmp/kvconsole-substrate.log" >&2; exit 2; }
  sleep 1
done
lsof -nP -iTCP:"$ARM_PORT" -sTCP:LISTEN >/dev/null 2>&1 || { echo "substrate never listened" >&2; exit 2; }
echo "substrate up: pid $SUB_PID arm=$ARM_PORT data=$DATA_PORT"

cd "$ROOT/workspace"
./node_modules/.bin/tsc \
  --module nodenext --moduleResolution nodenext --target es2022 --strict false \
  --ignoreConfig --skipLibCheck --types node --outDir "$OUT" --rootDir "$ROOT/workspace" \
  lib/azure/keyvault.ts test/keyvault_crypto.test.ts

KV_TEST_ARM="http://127.0.0.1:$ARM_PORT" KV_TEST_DATA="http://127.0.0.1:$DATA_PORT" \
  node --test "$OUT/test/keyvault_crypto.test.js"

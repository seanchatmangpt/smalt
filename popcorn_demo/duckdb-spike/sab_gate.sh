#!/usr/bin/env bash
# sab_gate.sh - FNOX-SJ-WASM-3 gate. Fail closed: exit 0 only if the positive run passes
# AND the mutation (BEAM stopped) run exits nonzero for a reason other than missing prereqs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../.." || exit 2
command -v node >/dev/null 2>&1 || { echo "BLOCKED: node absent; refusing to fake-pass"; exit 2; }
for f in duckdb-coi.wasm duckdb-browser-coi.worker.js duckdb-browser-coi.pthread.worker.js duckdb-browser.mjs; do
  found=$(find "$HERE/node_modules/@duckdb" -name "$f" 2>/dev/null | head -1)
  [ -n "$found" ] || { echo "BLOCKED: $f not on disk (needs npm install of @duckdb/duckdb-wasm in $HERE; no offline source)"; exit 2; }
done
[ -f popcorn_demo/public/out/index.mjs ] || { echo "BLOCKED: popcorn_demo/public/out/index.mjs missing"; exit 2; }
out=$(node popcorn_demo/duckdb-spike/sab_beam_verify.mjs 2>&1); rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: positive run rc=$rc"; exit 1; }
for want in 'build=duckdb-browser-coi' 'crossOriginIsolated=true' 'beam_alive=true' '"answer":42'; do
  echo "$out" | grep -qF "$want" || { echo "FAIL: missing stdout $want"; exit 1; }
done
mut=$(SAB_VERIFY_STOP_BEAM=1 node popcorn_demo/duckdb-spike/sab_beam_verify.mjs 2>&1); mrc=$?
[ "$mrc" -ne 0 ] && [ "$mrc" -ne 2 ] || { echo "VACUOUS GATE: mutation rc=$mrc"; exit 1; }
echo "PASS"

#!/usr/bin/env bash
# scripts/bench/bc_bench.sh — v26.11.6 wave+1 BENCH lane BC (bench-conversion).
#
# Compiles the pure-Erlang BC bench modules (bench/bench_bc_lane.erl +
# bench_bc_sink.erl + the additive smalt_bench_court add_bc_targets/0) with
# erlc into a BC-private dir and runs them inside `mix run --no-start
# --no-compile` (all smalt + elixir code paths, NO app boot, no ports) over
# the _build-laneKG beam set (read-only lease borrow; the shared source tree
# currently has a foreign mid-flight break in lib/smalt/aoq/arrow/flatbuf.ex
# that refuses a fresh compile — disclosed per the both-receipt law).
#
# Usage: bc_bench.sh calibrate | run
#   calibrate — measures, derives fence values from measured ratios, writes
#               docs/jira/v26.11.6/bench/bc_fences.json (never post-hoc).
#   run       — measures again, checks fences, fail-closed exit 1 on breach,
#               appends extended JSONL rows + fence-verdict rows to
#               docs/jira/v26.11.6/bench/bc.jsonl.
#
# Loopback / single-host scoping; restart-under-load and multi-node scaling:
# TARGET-UNMEASURED.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

MODE="${1:-run}"
BUILD_ROOT="${MIX_BUILD_ROOT:-_build-laneKG}"
BC_EBIN="_bc-laneBC/ebin"

export PATH="/Users/sac/.asdf/shims:$PATH"
export MIX_BUILD_ROOT="$BUILD_ROOT"

# 1. Pure-Erlang bench modules into the BC lease dir.
mkdir -p "$BC_EBIN"
erlc -o "$BC_EBIN" bench/bench_bc_lane.erl bench/bench_bc_sink.erl bench/smalt_bench_court.erl

# 2. Run inside mix run --no-start --no-compile (code paths, no app boot).
exec mix run --no-start --no-compile \
  -e "Code.append_path(\"$BC_EBIN\"); :erlang.apply(:bench_bc_lane, String.to_atom(\"$MODE\"), [])"

#!/usr/bin/env bash
# One-command Service Bus census replay.
#
# Boots the smalt substrate via test/sdk-smoke/census-run.mjs and runs the
# 8-probe census (test/sdk-smoke/census.test.cjs) against it with the real
# @azure/service-bus SDK. Exit codes are the census-run.mjs codes, passed
# through unchanged:
#   0  all 8 probes PASS
#   1  census failure (>=1 probe failed)
#   2  substrate never came up (5672/9443 not open in 60s)
#   3  harness failure (ports occupied, spawn error, missing SDK root)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# 1. SDK root: a node_modules dir containing @azure packages.
if [[ -z "${SMALT_SDK_ROOT:-}" ]]; then
  echo "[sb_census_replay] SMALT_SDK_ROOT not set." >&2
  echo "  Set it to a node_modules dir containing @azure packages, e.g.:" >&2
  echo "  export SMALT_SDK_ROOT=/Users/sac/cai/athena/playground/node_modules" >&2
  exit 3
fi
if [[ ! -d "$SMALT_SDK_ROOT/@azure" ]]; then
  echo "[sb_census_replay] SMALT_SDK_ROOT=$SMALT_SDK_ROOT has no @azure dir." >&2
  exit 3
fi
export SMALT_SDK_ROOT

# Dev shared key. census-run.mjs mints the broker key and injects it into the
# substrate plus the census env; exporting ours here keeps the variable set for
# any direct census.test.cjs invocation and satisfies fail-closed consumers.
export SMALT_SB_SHARED_KEY="$(openssl rand -base64 32)"

# 1b. Pin the substrate listener ports. config/test.exs binds random
# ephemeral ports whenever SMALT_TEST_*_PORT is unset, so an unpinned front
# door races: census-run.mjs polls fixed 5672/9443 and structurally fails
# exit 2 when the substrate lands elsewhere. Export the documented private
# range (39000-39999, docs/DEV_LOOP.md "Private port allocation") so boot is
# deterministic. SMALT_TEST_ARM_TLS_PORT / SMALT_TEST_MCP_PORT stay unpinned.
export SMALT_TEST_ARM_PORT="${SMALT_TEST_ARM_PORT:-39790}"
export SMALT_TEST_EGRESS_PORT="${SMALT_TEST_EGRESS_PORT:-39791}"
export SMALT_TEST_AMQP_PORT="${SMALT_TEST_AMQP_PORT:-39792}"
export SMALT_TEST_EVENT_HUBS_PORT="${SMALT_TEST_EVENT_HUBS_PORT:-39793}"

# Court SKIP semantics: the justfile `census` recipe treats exit 3 (harness/
# env failure, incl. missing SMALT_SDK_ROOT) as SKIP; exits 0/1/2 stay hard.

# 2. Run the census (boots substrate, waits for 5672+9443, runs probes).
set +e
node test/sdk-smoke/census-run.mjs
code=$?
set -e

# 3. On failure, dump the substrate log tail.
if [[ $code -ne 0 && -f test/sdk-smoke/.logs/census-substrate.log ]]; then
  echo >&2
  echo "[sb_census_replay] FAILED (exit $code) — last 40 lines of census-substrate.log:" >&2
  tail -n 40 test/sdk-smoke/.logs/census-substrate.log >&2
fi

# 4. Exit code passthrough.
exit "$code"

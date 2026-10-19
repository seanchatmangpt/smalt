#!/usr/bin/env bash
# Enclave Testbed runner — boots ONE dedicated substrate (private ports
# 29440-29444, private lock /tmp/smalt-substrate-enclave.lock) and drives the
# composite .exs against it. The shared /tmp/smalt-substrate.lock ecosystem is
# contended by concurrent lanes on default ports; the enclave testbed never
# touches those ports, so it stays out of their way entirely.
set -uo pipefail
cd "$(dirname "$0")/../.."

BUILD_ROOT="${MIX_BUILD_ROOT:-_build-enclave}"
LOG=tmp/enclave-testbed.log
mkdir -p tmp

exec 9>"/tmp/smalt-substrate-enclave.lock"
flock -w 600 -x 9 || { echo "[enclave] substrate lock not acquired in 600s"; exit 3; }

if [ -f "$LOG" ]; then mv "$LOG" "$LOG.old"; fi

# The script starts the application itself exactly once; the ENCLAVE_PRIVATE_PORTS
# env (read inside the .exs BEFORE app boot) pins the private port set.
MIX_BUILD_ROOT="$BUILD_ROOT" ENCLAVE_PRIVATE_PORTS=1 mix run --no-start test/enclave-testbed/enclave_testbed.exs 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

if [ -f /tmp/smalt.pid ]; then
  kill "$(cat /tmp/smalt.pid)" 2>/dev/null || true
fi

echo "[enclave] substrate torn down, lock released, exit $rc"
exit "$rc"

#!/usr/bin/env bash
# verification/py/run.sh — orchestrator for the Python external-suite lane.
#
# Boot (substrate-ctl, block v1, enforce) -> venv ensure -> pytest -> teardown.
# Exit contract: 0 pass-or-honest-skip / 1 test failure / 2 substrate never up /
# 3 harness failure (venv, certs, toolchain) / 4 loud typed skip (wf5
# infinite-limit substrate).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BLOCK="${SMALT_PY_BLOCK:-v1}"
PY_BIN="${SMALT_PY_BIN:-python3.12}"

command -v "$PY_BIN" >/dev/null || { echo "[py-lane] missing $PY_BIN" >&2; exit 3; }
for f in "$REPO/.smalt/tls/ca-cert.pem" "$REPO/.smalt/tls/dev-cert.pem" "$REPO/.smalt/tls/dev-key.pem"; do
  [ -r "$f" ] || { echo "[py-lane] missing $f — run: bash scripts/gen_dev_cert.sh" >&2; exit 3; }
done

# 1. Boot the enforce substrate (reuse-else-boot; identity guard is inside
#    substrate-ctl). Receipt = last stdout line.
receipt="$("$REPO/scripts/substrate-ctl" up --block "$BLOCK" --auth enforce 2>/tmp/py-lane-substrate.err)"
rc=$?
if [ $rc -ne 0 ]; then
  echo "[py-lane] substrate-ctl up rc=$rc" >&2
  tail -n 20 /tmp/py-lane-substrate.err >&2 || true
  exit 2
fi
echo "[py-lane] substrate receipt: $receipt"

cleanup() {
  [ "${SMALT_PY_KEEP:-}" = "1" ] || "$REPO/scripts/substrate-ctl" down --block "$BLOCK" --mode owner >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 2. Venv: fresh, real installs (idempotent).
export SSL_CERT_FILE="$REPO/.smalt/tls/ca-cert.pem"
export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
export SMALT_CERT_DIR="${SMALT_CERT_DIR:-$REPO/.smalt/tls}"

if [ ! -x "$HERE/.venv/bin/pytest" ]; then
  echo "[py-lane] creating venv + installing real SDKs (one-time)"
  "$PY_BIN" -m venv "$HERE/.venv" || exit 3
  "$HERE/.venv/bin/pip" install -q --upgrade pip || exit 3
  "$HERE/.venv/bin/pip" install -q -e "$HERE[azure,dev]" || { echo "[py-lane] pip install failed" >&2; exit 3; }
fi

# 3. Suite. pytest-timeout bounds each test; wf5's loud typed skip exits 4
#    via pytest.exit and propagates as this script's rc.
mkdir -p "$HERE/.logs"
cd "$HERE"
"$HERE/.venv/bin/pytest" -q \
  --timeout=180 -rA \
  --junitxml="$HERE/.logs/pytest.xml" \
  -o cache_dir=/tmp/py-lane-pytest-cache \
  "$@"
rc=$?

# 4. Teardown happens via trap. Map rc.
case $rc in
  0) echo "[py-lane] PASS (or honest skips)" ;;
  *) echo "[py-lane] pytest rc=$rc" ;;
esac
exit "$rc"

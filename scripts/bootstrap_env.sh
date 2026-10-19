#!/usr/bin/env bash
# bootstrap_env.sh — golden-path environment wrapper for zero-touch SDK
# routing to the smalt substrate.
#
# Sequence:
#   1. bootstrap.sh            — 8-stage zero-to-green (deps/certs/doctor/smoke)
#   2. gen_dev_cert.sh         — loopback CA + leaf (idempotent)
#   3. tf_trust_check.sh       — trust chain PASS gate (fails loud w/ remediation)
#   4. hosts_alias.sh status   — /etc/hosts aliases present?
#   5. pf_redirect.sh status   — pf 443->9444 redirect active?
#   6. summary
#
# This wrapper never runs sudo mutations itself: hosts/pf are reported via
# their `status` verbs; run `hosts_alias.sh enable` / `pf_redirect.sh enable`
# yourself when the summary shows INACTIVE.
#
# Usage: bash scripts/bootstrap_env.sh
# Exit: 0 golden path, 1 any stage failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

step() { printf '\n=== [%s] %s\n' "$1" "$2"; }

fail() {
  printf '[bootstrap-env] FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

step 1/6 "bootstrap.sh (8-stage zero-to-green)"
bash "$REPO/scripts/bootstrap.sh" || fail "bootstrap.sh exited non-zero"

step 2/6 "gen_dev_cert.sh (loopback CA + leaf)"
bash "$REPO/scripts/gen_dev_cert.sh" || fail "gen_dev_cert.sh exited non-zero"

step 3/6 "trust-shim probe (Security.framework eval via scripts/trust_shim_probe)"
# Gate (2026-10-16 operator ruling): shim probe PASS — a REAL Security.framework
# trust evaluation over the smalt dev chain with the fingerprint-pinned,
# loopback-only dylib shim injected. The keychain trust attempt is shown as an
# OPTIONAL persistent alternative below — NEVER a blocker.
if [ "$(uname)" != "Darwin" ]; then
  echo "[bootstrap-env] [SKIP] trust shim is darwin-only; SSL_CERT_FILE carries the CA on $(uname)"
elif ! command -v go >/dev/null 2>&1; then
  echo "[bootstrap-env] [SKIP] go toolchain not on PATH — cannot run trust_shim_probe" \
       "(loud skip, never a fake pass)"
elif [ ! -f "$REPO/.smalt/tls/ca-cert.pem" ]; then
  fail "no CA material at $REPO/.smalt/tls/ca-cert.pem — run scripts/gen_dev_cert.sh"
else
  SHIM_DYLIB="$REPO/scripts/trust_shim/smalt_trust_shim.dylib"
  [ -f "$SHIM_DYLIB" ] || bash "$REPO/scripts/trust_shim/build.sh" >/dev/null 2>&1 || true
  if [ ! -f "$SHIM_DYLIB" ]; then
    fail "trust shim dylib could not be built ($SHIM_DYLIB) — run scripts/trust_shim/build.sh"
  else
    # Leaf pin (H1 fix): the shim byte-matches cert[0] of the PRESENTED chain.
    # SMALT_CA_SHA256 stays exported as a back-compat alias for older shim
    # builds (exact-match semantics; harmless).
    LEAF_FP="$(openssl x509 -in "$REPO/.smalt/tls/dev-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    CA_FP="$(openssl x509 -in "$REPO/.smalt/tls/ca-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    # NOTE: `go run` strips DYLD_* from the child environment (cmd/go), so the
    # shim never injects under `go run` — the probe must be built and exec'd
    # directly (witnessed 2026-10-16: go run -> SEC-TRUST fail; built binary
    # with identical env -> SEC-TRUST pass).
    PROBE_BIN="$(mktemp -t smalt_probe)" && mv "$PROBE_BIN" "$PROBE_BIN.bin" && PROBE_BIN="$PROBE_BIN.bin"
    if ! (cd "$REPO/scripts/trust_shim_probe" && go build -o "$PROBE_BIN" .); then
      fail "trust_shim_probe could not be built (go build failed)"
    elif (DYLD_INSERT_LIBRARIES="$SHIM_DYLIB" \
          SMALT_LEAF_SHA256="$LEAF_FP" SMALT_CA_SHA256="$CA_FP" \
          SMALT_CA_FILE="$REPO/.smalt/tls/ca-cert.pem" \
          "$PROBE_BIN" -tls-dir "$REPO/.smalt/tls" -want=pass); then
      echo "[bootstrap-env] trust shim probe PASS"
    else
      rc=$?
      fail "trust-shim probe FAILED (exit $rc) — Security.framework rejected the pinned chain"
      echo "  remediation (primary, zero-touch): bash $REPO/scripts/trust_shim/build.sh then re-run"
      echo "  optional persistent alternative (opt-in, NOT a gate):" \
           "$REPO/scripts/tf_trust_setup.sh trust"
      echo "  dead-CA re-trust (optional):       $REPO/scripts/tf_trust_setup.sh retrust"
    fi
    rm -f "$PROBE_BIN" 2>/dev/null || true
  fi
fi

step 4/6 "hosts_alias.sh status"
bash "$REPO/scripts/hosts_alias.sh" status \
  || fail "hosts_alias.sh status exited non-zero"
bash "$REPO/scripts/hosts_alias.sh" status | grep -q "state: ACTIVE" \
  || echo "  -> run: sudo bash $REPO/scripts/hosts_alias.sh enable"

step 5/6 "pf_redirect.sh status"
bash "$REPO/scripts/pf_redirect.sh" status \
  || fail "pf_redirect.sh status exited non-zero"
bash "$REPO/scripts/pf_redirect.sh" status | grep -q "state: ACTIVE" \
  || echo "  -> run: sudo bash $REPO/scripts/pf_redirect.sh enable"

step 6/6 "summary"
if [[ $FAILURES -eq 0 ]]; then
  echo "[bootstrap-env] GOLDEN PATH: all stages green"
  exit 0
else
  echo "[bootstrap-env] $FAILURES stage(s) failed — see transcript above"
  exit 1
fi

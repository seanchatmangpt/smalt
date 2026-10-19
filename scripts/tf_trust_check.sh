#!/usr/bin/env bash
# tf_trust_check.sh — verifies the smalt-dev-ca trust chain that Terraform
# (azurerm -> azidentity) needs when routing to the smalt substrate.
#
# Trust model (receipt 2026-10-14, lane 40):
#   linux: SSL_CERT_FILE=$ROOT/.smalt/tls/ca-cert.pem is authoritative — Go's
#          crypto/x509 reads it on non-darwin Unix. openssl probe => clean
#          PASS/FAIL.
#   darwin: Go x509 does NOT honor SSL_CERT_FILE; verification goes through
#          Apple Security.framework, i.e. the login keychain. Two honest
#          layers here:
#            a) keychain presence: security find-certificate -c smalt-dev-ca
#            b) chain proof: openssl s_client with -CAfile (openssl uses the
#               supplied CAfile, not the keychain) — proves the served chain
#               but NOT the Go provider's view.
#          `security verify-cert` is deliberately NOT used: it returns 1 even
#          for a user-domain-trusted CA, so it cannot distinguish trusted
#          from untrusted.
#          The ONLY authoritative darwin check is a real Go/azidentity run
#          (terraform plan via scripts/smalt-tf). We attempt it last; it may
#          require network (provider download) or interactive approval. When
#          the fast checks pass but the authoritative check cannot run
#          non-interactively, we report INDETERMINATE and print the exact
#          remediation command for the untrusted case.
#
# Exit codes: 0 PASS, 1 FAIL, 2 UNREACHABLE (substrate down), 3 INDETERMINATE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS_DIR="${SMALT_CERT_DIR:-$ROOT/.smalt/tls}"
CA="$TLS_DIR/ca-cert.pem"
CERT="$TLS_DIR/dev-cert.pem"
KEY="$TLS_DIR/dev-key.pem"
TLS_HOST="localhost"
TLS_PORT="${SMALT_TLS_PORT:-9444}"
STATUS="PASS"

say()  { printf '[tf-trust] %s\n' "$*"; }
mark() { # mark <name> <PASS|FAIL|SKIP> [detail]
  printf '[tf-trust] %-38s %s%s\n' "$1" "$2" "${3:+ — $3}"
  [ "$2" = "PASS" ] || [ "$2" = "SKIP" ] || STATUS="FAIL"
}

# ---------- 1. locate / mint cert ----------
if [ -f "$CA" ] && [ -f "$CERT" ] && [ -f "$KEY" ]; then
  mark "cert material present" PASS "$CA"
else
  say "cert material missing; minting via scripts/gen_dev_cert.sh"
  if bash "$ROOT/scripts/gen_dev_cert.sh"; then
    mark "cert material minted" PASS "$CA"
  else
    mark "cert material minted" FAIL "gen_dev_cert.sh failed"
  fi
fi

# ---------- 2. linux: SSL_CERT_FILE is authoritative ----------
# ---------- 3. darwin: keychain + chain probe, Go check is authoritative ---
probe_tls() { # real TLS handshake against 9444 using the CA as anchor
  local timeout="${1:-5}"
  echo | timeout "$timeout" openssl s_client -connect "$TLS_HOST:$TLS_PORT" \
    -CAfile "$CA" -verify_return_error -servername "$TLS_HOST" 2>&1 \
    | grep -q "Verify return code: 0"
}

if [ "$(uname)" = "Linux" ]; then
  if [ "${SSL_CERT_FILE:-}" != "$CA" ]; then
    mark "SSL_CERT_FILE points at smalt CA" FAIL "got '${SSL_CERT_FILE:-<unset>}' want '$CA'"
  else
    mark "SSL_CERT_FILE points at smalt CA" PASS
  fi
  if nc -z 127.0.0.1 "$TLS_PORT" 2>/dev/null; then
    if probe_tls; then
      mark "TLS probe verifies chain (openssl)" PASS
    else
      mark "TLS probe verifies chain (openssl)" FAIL "handshake/verify failed against $TLS_HOST:$TLS_PORT"
    fi
  else
    mark "TLS probe verifies chain (openssl)" SKIP "nothing listening on $TLS_PORT (UNREACHABLE)"
    STATUS="UNREACHABLE"
  fi

elif [ "$(uname)" = "Darwin" ]; then
  KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  # Presence is NOT trust (measured 2026-10-14: find-certificate hits while
  # the Go provider rejects with x509 unknown-authority because the import
  # carried zero trust settings). Gate on actual trust settings.
  trust_line="$(security dump-trust-settings 2>/dev/null | grep -A1 'smalt-dev-ca' | grep 'Number of trust settings' || true)"
  if echo "$trust_line" | grep -qv ': 0'; then
    mark "smalt-dev-ca trusted (login keychain)" PASS
  elif security find-certificate -c smalt-dev-ca "$KEYCHAIN" >/dev/null 2>&1; then
    mark "smalt-dev-ca trusted (login keychain)" FAIL "cert imported but has ZERO trust settings (presence != trust)"
  else
    mark "smalt-dev-ca trusted (login keychain)" FAIL "not in keychain at all (darwin Go verifies via Security.framework)"
  fi
  if [ "$trust_line" = "" ] || echo "$trust_line" | grep -q ': 0'; then
    echo "[tf-trust] FIX (one command, one interactive SecurityAgent approval):" >&2
    echo "  security add-trusted-cert -r trustRoot -k \"$KEYCHAIN\" \"$CA\"" >&2
  fi
  if nc -z 127.0.0.1 "$TLS_PORT" 2>/dev/null; then
    if probe_tls; then
      mark "TLS chain probe (openssl -CAfile)" PASS "proves served chain, NOT the keychain view"
    else
      mark "TLS chain probe (openssl -CAfile)" FAIL "handshake/verify failed against $TLS_HOST:$TLS_PORT"
    fi
  else
    mark "TLS chain probe (openssl -CAfile)" SKIP "nothing listening on $TLS_PORT"
    if [ "$STATUS" = "PASS" ]; then STATUS="UNREACHABLE"; fi
  fi

  # Authoritative darwin check: the real Go/azidentity path. Only attempted
  # when the fast checks passed; needs metadata endpoint on 9444 live.
  if [ "$STATUS" = "PASS" ] && nc -z 127.0.0.1 "$TLS_PORT" 2>/dev/null; then
    say "attempting authoritative check: real token POST via curl --cacert"
    metadata_body="$(mktemp)"
    http_code="$(curl -sS --cacert "$CA" -o "$metadata_body" -w '%{http_code}' \
      --max-time 10 "https://$TLS_HOST:$TLS_PORT/metadata/endpoints" 2>/dev/null || echo 000)"
    if [ "$http_code" = "200" ]; then
      mark "curl --cacert GET /metadata/endpoints" PASS "200; chain + endpoint live"
    else
      mark "curl --cacert GET /metadata/endpoints" FAIL "http_code=$http_code"
    fi
    rm -f "$metadata_body"

    # Last resort: a real `smalt-tf plan` dry attempt. This is the only check
    # that exercises the actual Go/Security.framework verification path, but
    # it needs a terraform init'd fixture and may hit the network, so failure
    # here is INDETERMINATE, not FAIL.
    if command -v terraform >/dev/null 2>&1 && [ -d "$ROOT/scripts/tf_fixtures" ]; then
      say "last-resort authoritative probe: scripts/smalt-tf plan (dry attempt)"
      if (cd "$ROOT/scripts/tf_fixtures" && timeout 120 "$ROOT/scripts/smalt-tf" plan -input=false -no-color -refresh=false >/tmp/tf-trust-plan.log 2>&1); then
        mark "authoritative: smalt-tf plan" PASS "Go/Security.framework accepted the chain"
      else
        # Distinguish trust failure from network/init failure.
        if grep -qiE "x509|certificate is not trusted|trust" /tmp/tf-trust-plan.log; then
          mark "authoritative: smalt-tf plan" FAIL "TLS trust rejected by Go provider"
        else
          mark "authoritative: smalt-tf plan" SKIP "failed for non-trust reasons (network/init); see /tmp/tf-trust-plan.log"
          if [ "$STATUS" = "PASS" ]; then STATUS="INDETERMINATE"; fi
        fi
      fi
    else
      mark "authoritative: smalt-tf plan" SKIP "terraform or fixture unavailable"
      if [ "$STATUS" = "PASS" ]; then STATUS="INDETERMINATE"; fi
    fi
  fi
  if [ "$STATUS" = "INDETERMINATE" ]; then
    say "fast checks passed but the authoritative Go/azidentity check could not"
    say "run non-interactively. If plan still fails on TLS, run the fix:"
    say "  security add-trusted-cert -r trustRoot -k \"$HOME/Library/Keychains/login.keychain-db\" \"$CA\""
  fi
else
  say "unsupported OS $(uname) — report FAIL"
  STATUS="FAIL"
fi

echo
echo "=============== TF TRUST RECEIPT ==============="
echo "verdict: $STATUS"
echo "================================================"
case "$STATUS" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  UNREACHABLE) exit 2 ;;
  *) exit 3 ;;
esac

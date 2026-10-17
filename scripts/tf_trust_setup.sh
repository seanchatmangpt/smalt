#!/usr/bin/env bash
# tf_trust_setup.sh — manage smalt-dev-ca trust in the macOS login keychain.
#
# STANDING (demoted 2026-10-16, lane 397): this script is the OPT-IN
# PERSISTENT trust alternative, no longer the primary gate — smalt-tf
# treats keychain trust as fallback-only and the primary design is the
# zero-touch trust shim (scripts/trust_shim/). Witnessed 2026-10-16
# (WRAP_LEDGER "Zero-touch validation lane"): the shim as built does NOT
# flip Go binaries' TLS verdict (Go never consults SecTrustEvaluate), so
# until a Go-reachable shim (anchor-enumeration interpose) lands, this
# script's `trust` remains the only witnessed-working path for the real
# azurerm provider on darwin. status still fails loudly (exit 1) when
# trust is absent — that FAIL is the expected zero-touch precondition.
#
# Subcommands:
#   status [--json]    non-destructive gate check (exit 0 trusted / 1 untrusted /
#                      2 no cert material); --json emits {"status","reason"}
#                      machine JSON on stdout, human text otherwise
#   trust     import + trust the current .smalt/tls/ca-cert.pem (idempotent)
#   retrust   fingerprint mismatch or rot detected: remove stale entry, re-trust current CA
#   untrust   remove trust settings + the smalt-dev-ca cert from the login keychain
#
# Design (Phase 1 item 2, 2026-10-16):
# - Fingerprint gate: `security find-certificate -Z -c smalt-dev-ca` prints
#   "SHA-256 hash:" of the KEYCHAIN copy; compare to `openssl x509 -fingerprint
#   -sha256` of .smalt/tls/ca-cert.pem. A mismatch means the keychain holds a
#   DEAD CA (re-minted locally) while still trusted — terraform keeps failing
#   x509 unknown-authority with no hint why. That state routes to retrust.
# - Trust probe: `security dump-trust-settings` nonzero "Number of trust
#   settings" for smalt-dev-ca. `security verify-cert` is deliberately NOT
#   used (returns 1 even for a user-domain-trusted CA — see tf_trust_check.sh).
# - add-trusted-cert is run WITHOUT `|| true`: rc!=0 is a real failure. But
#   rc=0 with ZERO trust settings afterwards means the SecurityAgent approval
#   dialog was dismissed — that is a loud remediation, never a silent pass,
#   and we print (never run) the sudo System-keychain command as the fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS_DIR="${SMALT_CERT_DIR:-$ROOT/.smalt/tls}"
CA="$TLS_DIR/ca-cert.pem"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CN="smalt-dev-ca"

say()  { printf '[tf-trust-setup] %s\n' "$*"; }
die()  { printf '[tf-trust-setup] FAULT: %s\n' "$*" >&2; exit 1; }

# SHIM-COURT-free emit: status verdict to stdout, human text or machine JSON.
# Reasons are script-controlled literals (no user input), so plain quoting in
# the JSON template is safe.
JSON_OUT=0
emit_status() { # emit_status <STATUS> <reason>
  if [ "$JSON_OUT" = 1 ]; then
    printf '{"status":"%s","reason":"%s"}\n' "$1" "$2"
  else
    say "status: $1 — $2"
  fi
}

# ---------- probes (reused logic from scripts/tf_trust_check.sh) ----------

# keychain cert SHA-256 fingerprint, lowercase hex no colons; empty if absent.
keychain_fp() {
  security find-certificate -Z -c "$CN" "$KEYCHAIN" 2>/dev/null \
    | awk '/^SHA-256 hash:/ {print $3}' \
    | tr -d ':' | tr 'A-F' 'a-f'
}

# CA file SHA-256 fingerprint, same canonical form; empty if file missing.
ca_fp() {
  [ -f "$CA" ] || { echo ""; return; }
  openssl x509 -fingerprint -sha256 -noout -in "$CA" 2>/dev/null \
    | sed 's/^.*=//' | tr -d ':' | tr 'A-F' 'a-f'
}

# Number of trust settings for $CN in the login keychain; "0" when none/absent.
trust_setting_count() {
  security dump-trust-settings 2>/dev/null \
    | grep -A1 "$CN" | grep 'Number of trust settings' \
    | grep -oE '[0-9]+' || echo 0
}

print_sudo_fallback() {
  say "interactive fallback if the dialog keeps getting dismissed (NEVER run by this script):"
  say "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \"$CA\""
}

# Delete EVERY keychain cert matching $CN, by SHA-256 hash. Bare
# `security delete-certificate -c "$CN"` dies with "SecKeychainSearch:
# ambiguous item" when multiple stale entries share the name (witnessed
# 2026-10-16: 3 stale entries blocked retrust). Looping the hash list until
# empty makes the ambiguity structurally impossible to recur.
delete_all_keychain_certs() {
  local hashes h rounds=0
  while :; do
    hashes="$(security find-certificate -a -Z -c "$CN" "$KEYCHAIN" 2>/dev/null \
      | awk '/^SHA-256 hash:/ {print $3}' | tr -d ':')" || true
    [ -n "$hashes" ] || break
    rounds=$(( rounds + 1 ))
    if [ "$rounds" -gt 10 ]; then
      die "delete loop did not converge after 10 rounds — keychain state abnormal"
    fi
    for h in $hashes; do
      say "deleting keychain cert ${h:0:16}…"
      security delete-certificate -Z "$h" "$KEYCHAIN" \
        || die "delete-certificate -Z $h failed"
    done
  done
}

# Gate: exit 0 trusted-and-current, 1 untrusted/stale, 2 no cert material.
cmd_status() {
  local kfp cfp n
  if [ ! -f "$CA" ]; then
    emit_status "UNREACHABLE" "no cert material: $CA missing (run scripts/gen_dev_cert.sh)"
    exit 2
  fi
  cfp="$(ca_fp)"
  kfp="$(keychain_fp)"
  n="$(trust_setting_count)"
  if [ -z "$kfp" ]; then
    emit_status "FAIL" "$CN not in login keychain (darwin Go verifies via Security.framework)"
    exit 1
  fi
  if [ "$kfp" != "$cfp" ]; then
    emit_status "FAIL" "DEAD CA: keychain fingerprint ${kfp:0:16}.. != file ${cfp:0:16}.. (CA re-minted after import; run: $0 retrust)"
    exit 1
  fi
  if [ "$n" -eq 0 ]; then
    emit_status "FAIL" "cert imported but ZERO trust settings (presence != trust)"
    exit 1
  fi
  emit_status "PASS" "$CN trusted (settings=$n), fingerprint matches $CA"
  exit 0
}

# Trust the current CA file. No `|| true`: failure is failure. rc=0 but zero
# settings afterwards => dismissed SecurityAgent dialog => loud remediation.
cmd_trust() {
  local n
  [ -f "$CA" ] || die "$CA missing; run scripts/gen_dev_cert.sh first"
  say "importing + trusting $CA in $KEYCHAIN (one interactive SecurityAgent approval)"
  security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$CA"
  n="$(trust_setting_count)"
  if [ "$n" -eq 0 ]; then
    say "FAULT: add-trusted-cert returned 0 but trust settings count is 0 —"
    say "  the SecurityAgent approval dialog was dismissed or never answered."
    say "  re-run: $0 trust  (and click 'Always Trust' when prompted)"
    print_sudo_fallback
    exit 1
  fi
  say "trust established (settings=$n)"
  cmd_status
}

# Fingerprint mismatch / rot flow: drop the stale keychain entry, re-trust.
cmd_retrust() {
  local cfp kfp
  [ -f "$CA" ] || die "$CA missing; run scripts/gen_dev_cert.sh first"
  cfp="$(ca_fp)"
  kfp="$(keychain_fp)"
  if [ -n "$kfp" ]; then
    if [ "$kfp" = "$cfp" ]; then
      say "keychain cert already matches current CA; plain trust is enough"
    else
      say "removing stale keychain cert(s) (${kfp:0:16}… != current ${cfp:0:16}…)"
      delete_all_keychain_certs
    fi
  fi
  cmd_trust
}

cmd_untrust() {
  local n
  n="$(trust_setting_count)"
  if [ "$n" -gt 0 ]; then
    say "removing $n trust setting(s) for $CN"
    security remove-trusted-cert -d "$CA" 2>/dev/null \
      || security remove-trusted-cert "$CA" \
      || say "note: remove-trusted-cert failed; delete-certificate below still drops the entry"
  else
    say "no trust settings present"
  fi
  if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
    say "deleting all $CN entries from $KEYCHAIN (by hash)"
    delete_all_keychain_certs
  fi
  cmd_status || true
}

# --json is accepted by the status subcommand ONLY (machine-readable verdict;
# human text is the default everywhere else).
sub="${1:-status}"
case "$sub" in
  status)
    shift
    JSON_OUT=0
    for arg in "$@"; do
      case "$arg" in
        --json) JSON_OUT=1 ;;
        *) die "usage: $0 status [--json] | {trust|retrust|untrust}" ;;
      esac
    done
    cmd_status
    ;;
  trust)   cmd_trust ;;
  retrust) cmd_retrust ;;
  untrust) cmd_untrust ;;
  *) die "usage: $0 {status [--json]|trust|retrust|untrust}" ;;
esac

#!/usr/bin/env bash
# Mints the smalt dev TLS material:
#   .smalt/tls/ca-cert.pem      self-signed root CA (CA:TRUE, 10y)
#   .smalt/tls/dev-cert.pem     server leaf for localhost/127.0.0.1, signed by the CA
#   .smalt/tls/dev-key.pem      leaf key
#
# Why a chain (receipt 2026-10-14): macOS Go builds verify TLS through Apple
# Security.framework even when SSL_CERT_FILE supplies the anchors, and Apple's
# strict evaluator rejects a CA:TRUE self-signed certificate presented as a
# TLS end-entity ("x509: certificate is not standards compliant"). A CA:TRUE
# root as anchor + CA:FALSE leaf (<=825 days, serverAuth, SAN DNS:localhost +
# IP:127.0.0.1) passes both Apple and pure-Go verification.
#
# SSL_CERT_FILE should point at ca-cert.pem (the trust anchor).
set -euo pipefail
# Root-cause (F4, 2026-10-15): private keys must NEVER hit disk wider than 0600.
# umask 077 closes the creation window (openssl -keyout) instead of relying on
# the trailing chmod — a crash between keyout and chmod previously left a
# group/world-readable key behind for the doctor to catch after the fact.
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# CERT_DIR resolution order: SMALT_CERT_DIR > SMALT_ROOT/.smalt/tls > script checkout.
# SMALT_ROOT support: scripts/doctor.py --fix runs the minter against SMALT_ROOT
# repos; without this the mint landed in the script's own checkout while the
# doctor check inspected SMALT_ROOT — the remediation could never satisfy the check.
CERT_DIR="${SMALT_CERT_DIR:-${SMALT_ROOT:-$ROOT}/.smalt/tls}"
CA_CERT="$CERT_DIR/ca-cert.pem"
CA_KEY="$CERT_DIR/ca-key.pem"
CERT="$CERT_DIR/dev-cert.pem"
KEY="$CERT_DIR/dev-key.pem"

mkdir -p "$CERT_DIR"

# SHIM-COURT: serialize the whole mint-or-reuse decision — concurrent lanes
# (T5 wire / e1, 2026-10-16) each decided "remint" before either minted, so
# the CA rotated mid-run (3x) and desynced substrate/terraform cert pins.
# Everything below holds the lock on fd 9; reuse requires the chain-verify
# self-heal guard to pass INSIDE the lock, so a clobbered self-signed leaf
# remints rather than being reused.
exec 9>"$CERT_DIR/.mint.lock"
if ! flock -w 120 9; then
  echo "[gen_dev_cert] could not acquire mint lock $CERT_DIR/.mint.lock within 120s" >&2
  exit 1
fi

if [ -f "$CA_CERT" ] && [ -f "$CERT" ] && [ -f "$KEY" ]; then
  # Self-heal legacy keys minted before umask 077 (pre-2026-10-15 checkouts).
  chmod 600 "$KEY" "$CA_KEY" 2>/dev/null || true
  # SHIM-COURT: R17/A11 #7 — regenerate the 800-day leaf when it is expired
  # or within 30 days of expiry instead of reusing it indefinitely.
  if openssl x509 -checkend 2592000 -noout -in "$CERT" 2>/dev/null &&
     openssl verify -CAfile "$CA_CERT" "$CERT" >/dev/null 2>&1; then
    echo "[gen_dev_cert] reusing existing $CERT"
    exit 0
  fi
  echo "[gen_dev_cert] leaf $CERT expired/expiring, or does not chain to the CA — reminting" >&2
fi

# 1. root CA — SKI required so Apple's strict evaluator links the chain (a
# SKI-less CA truncates the evaluated chain at the leaf; witnessed 2026-10-16:
# "certificate is not standards compliant" + SecTrustCopyCertificateChain
# returning only the leaf, which made the trust shim's CA-fingerprint pin
# unmatchable).
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CA_KEY" -out "$CA_CERT" \
  -subj "/CN=smalt-dev-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1

# 2. server leaf signed by the CA — SKI+AKI for the same Apple strict-eval
# chain-linking requirement.
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$KEY" -out "$CERT_DIR/dev-csr.pem" \
  -subj "/CN=localhost" >/dev/null 2>&1
# BK-CERTSAN (BK-TOPO): SMALT_CERT_SAN_HOSTS (comma-separated) adds service-DNS
# SAN entries alongside CN=localhost's DNS:localhost/IP:127.0.0.1 defaults, so
# k8s-hosted TLS twins validate from in-cluster clients (headless pod FQDNs).
# Unset -> identical SAN line to pre-BK-CERTSAN (byte-identical behavior).
SAN_EXTRA=""
if [ -n "${SMALT_CERT_SAN_HOSTS:-}" ]; then
  IFS=',' read -r -a _SAN_HOSTS <<< "$SMALT_CERT_SAN_HOSTS"
  for _h in "${_SAN_HOSTS[@]}"; do
    _h="$(echo "$_h" | tr -d '[:space:]')"
    [ -n "$_h" ] || continue
    SAN_EXTRA="${SAN_EXTRA:+${SAN_EXTRA},}DNS:${_h}"
  done
fi
SAN_LIST="DNS:localhost,IP:127.0.0.1,DNS:management.azure.com,DNS:login.microsoftonline.com${SAN_EXTRA:+,${SAN_EXTRA}}"
openssl x509 -req -sha256 -days 800 \
  -in "$CERT_DIR/dev-csr.pem" \
  -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$CERT" \
  -extfile <(printf "subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n" "$SAN_LIST") >/dev/null 2>&1

chmod 600 "$KEY" "$CA_KEY"
echo "[gen_dev_cert] minted $CERT (+ CA at $CA_CERT)"

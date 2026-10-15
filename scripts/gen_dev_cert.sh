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
CERT_DIR="${SMALT_CERT_DIR:-$ROOT/.smalt/tls}"
CA_CERT="$CERT_DIR/ca-cert.pem"
CA_KEY="$CERT_DIR/ca-key.pem"
CERT="$CERT_DIR/dev-cert.pem"
KEY="$CERT_DIR/dev-key.pem"

if [ -f "$CA_CERT" ] && [ -f "$CERT" ] && [ -f "$KEY" ]; then
  # Self-heal legacy keys minted before umask 077 (pre-2026-10-15 checkouts).
  chmod 600 "$KEY" "$CA_KEY" 2>/dev/null || true
  echo "[gen_dev_cert] reusing existing $CERT"
  exit 0
fi

mkdir -p "$CERT_DIR"

# 1. root CA
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CA_KEY" -out "$CA_CERT" \
  -subj "/CN=smalt-dev-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign" >/dev/null 2>&1

# 2. server leaf signed by the CA
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$KEY" -out "$CERT_DIR/dev-csr.pem" \
  -subj "/CN=localhost" >/dev/null 2>&1
openssl x509 -req -sha256 -days 800 \
  -in "$CERT_DIR/dev-csr.pem" \
  -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$CERT" \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n") >/dev/null 2>&1

chmod 600 "$KEY" "$CA_KEY"
echo "[gen_dev_cert] minted $CERT (+ CA at $CA_CERT)"

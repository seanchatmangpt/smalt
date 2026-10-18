#!/usr/bin/env bash
# Linux (alpine/musl) equivalent of scripts/gen_dev_cert.sh, for in-image mint
# during `docker build` (the host script is macOS-specific in its comments and
# lock hygiene; the emitted .smalt/tls layout is identical):
#   .smalt/tls/ca-cert.pem      self-signed root CA (CA:TRUE, 10y)
#   .smalt/tls/dev-cert.pem     server leaf (CA:FALSE, 800d, serverAuth,
#                               SAN DNS:localhost + 127.0.0.1 + wire hostnames)
#   .smalt/tls/dev-key.pem      leaf key
#
# Deliberate divergences from the macOS script (disclosed):
#   - no flock section: this variant runs exactly once inside a docker build
#     layer; the concurrent-lane mint lock is a host-shared-tree concern.
#   - no Apple strict-evaluator commentary; the SKI/AKI extensions are kept
#     anyway so the output chain is byte-compatible in shape with the host
#     minter's (same CA:TRUE anchor + CA:FALSE leaf contract).
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${SMALT_CERT_DIR:-${SMALT_ROOT:-$ROOT}/.smalt/tls}"
CA_CERT="$CERT_DIR/ca-cert.pem"
CA_KEY="$CERT_DIR/ca-key.pem"
CERT="$CERT_DIR/dev-cert.pem"
KEY="$CERT_DIR/dev-key.pem"

mkdir -p "$CERT_DIR"

if [ -f "$CA_CERT" ] && [ -f "$CERT" ] && [ -f "$KEY" ]; then
  if openssl x509 -checkend 2592000 -noout -in "$CERT" 2>/dev/null &&
     openssl verify -CAfile "$CA_CERT" "$CERT" >/dev/null 2>&1; then
    echo "[gen_dev_cert] reusing existing $CERT"
    exit 0
  fi
  echo "[gen_dev_cert] leaf expired/chained-broken — reminting" >&2
fi

# 1. root CA (CA:TRUE anchor, SKI required for strict chain linking)
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$CA_KEY" -out "$CA_CERT" \
  -subj "/CN=smalt-dev-ca" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1

# 2. server leaf signed by the CA (CA:FALSE end-entity, <=825 days, serverAuth)
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$KEY" -out "$CERT_DIR/dev-csr.pem" \
  -subj "/CN=localhost" >/dev/null 2>&1
openssl x509 -req -sha256 -days 800 \
  -in "$CERT_DIR/dev-csr.pem" \
  -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$CERT" \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:management.azure.com,DNS:login.microsoftonline.com\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n") >/dev/null 2>&1

chmod 600 "$KEY" "$CA_KEY"
echo "[gen_dev_cert] minted $CERT (+ CA at $CA_CERT)"

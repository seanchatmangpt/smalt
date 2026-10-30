#!/usr/bin/env bash
# P09 lane (v26.10.30) — mint the r30 in-cluster TLS leaf from the substrate's
# own CA and distribute it as the r30-ca Secret (namespace smalt).
#
# Why a new leaf: .smalt/tls/dev-cert.pem carries SANs for
# localhost/127.0.0.1/login.microsoftonline.com only (witnessed
# openssl x509 -ext subjectAltName) — node's production validator correctly
# rejects it for idp.smalt.svc.cluster.local. The lawful chain is:
# consumers trust .smalt/tls/ca-cert.pem; the r30 leaf is issued by that same
# CA with the in-cluster SANs. The CA private key NEVER enters the cluster.
#
# Key-on-disk law (gen_dev_cert.sh F4): umask 077; the leaf key exists only in
# a 0700 mktemp dir and is destroyed on exit.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="smalt"
CA_CERT="$ROOT/.smalt/tls/ca-cert.pem"
CA_KEY="$ROOT/.smalt/tls/ca-key.pem"
DEV_CERT="$ROOT/.smalt/tls/dev-cert.pem"
DEV_KEY="$ROOT/.smalt/tls/dev-key.pem"

for f in "$CA_CERT" "$CA_KEY" "$DEV_CERT" "$DEV_KEY"; do
  if [ ! -f "$f" ]; then
    echo "[r30-mint] REFUSED: missing substrate TLS material: $f" >&2
    exit 1
  fi
done

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  kubectl apply -f "$ROOT/k8s/r30-00-namespace.yaml"
fi

WORK="$(mktemp -d /tmp/r30-tls.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Serial via -set_serial: -CAcreateserial would write .smalt/tls/ca-cert.srl,
# a file this lane does not own.
SERIAL="0x$(openssl rand -hex 16)"

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$WORK/r30-idp-leaf-key.pem" \
  -out "$WORK/r30-leaf.csr" \
  -subj "/CN=idp.smalt.svc.cluster.local" >/dev/null 2>&1

cat > "$WORK/r30-leaf.ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:idp.smalt.svc.cluster.local,DNS:oidc.smalt.svc.cluster.local,DNS:idp.smalt.svc,DNS:oidc.smalt.svc,DNS:idp.smalt,DNS:oidc.smalt,DNS:localhost,IP:127.0.0.1
EOF

openssl x509 -req \
  -in "$WORK/r30-leaf.csr" \
  -CA "$CA_CERT" -CAkey "$CA_KEY" \
  -set_serial "$SERIAL" \
  -days 90 -sha256 \
  -extfile "$WORK/r30-leaf.ext" \
  -out "$WORK/r30-idp-leaf-cert.pem" >/dev/null 2>&1

# Gate: the minted leaf must verify against the substrate CA, fail-closed.
if ! openssl verify -CAfile "$CA_CERT" "$WORK/r30-idp-leaf-cert.pem" | grep -q ": OK"; then
  echo "[r30-mint] FAIL: leaf does not verify against the substrate CA" >&2
  exit 1
fi

kubectl -n "$NS" create secret generic r30-ca \
  --from-file=ca-cert.pem="$CA_CERT" \
  --from-file=dev-cert.pem="$DEV_CERT" \
  --from-file=dev-key.pem="$DEV_KEY" \
  --from-file=r30-idp-leaf-cert.pem="$WORK/r30-idp-leaf-cert.pem" \
  --from-file=r30-idp-leaf-key.pem="$WORK/r30-idp-leaf-key.pem" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[r30-mint] OK: r30-ca Secret refreshed in ns $NS (CA-key excluded; leaf verified against substrate CA)"

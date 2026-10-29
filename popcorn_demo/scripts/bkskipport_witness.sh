#!/usr/bin/env bash
# bkskipport_witness.sh — BK-SKIPPORT lane: atomic substrate boot + CORS seed
# + browser smoke capture.
#
# Why atomic: on this box, canonical-port beams get reaped by concurrent
# lanes' orphan sweeps between separate commands; a boot that survives the
# run is not required, only the captured receipt is. Boot #3 also moved the
# Kafka listener to 19092 because an unrelated 3h23m-old beam holds 9092 with
# a live LISTEN (port_sweep-protected, not ours to kill).
#
# Usage: bash scripts/bkskipport_witness.sh   (writes /tmp/bkskipport-smoke.txt)
set -uo pipefail
REPO="${REPO:-/Users/sac/smalt}"
DEMO="$REPO/popcorn_demo"
cd "$REPO"

export SMALT_TLS_CERTFILE="$REPO/.smalt/tls/dev-cert.pem"
export SMALT_TLS_KEYFILE="$REPO/.smalt/tls/dev-key.pem"
export SSL_CERT_FILE="$REPO/.smalt/tls/ca-cert.pem"
SB_KEY="$(printf '%s' "$(hostname)smalt-dev-sb" | openssl dgst -sha256 -binary | base64)"

( exec 9>/tmp/smalt-substrate.lock
  flock -w 120 9 || exit 3
  nohup mix run --no-start --no-halt -e 'Application.put_env(:smalt, :auth_mode, :enforce); Application.put_env(:smalt, :sb_shared_key, "'"${SB_KEY}"'"); Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:5672"); Application.put_env(:smalt, :amqp_port, 5672); Application.put_env(:smalt, :event_hubs_port, 5673); Application.put_env(:smalt, :arm_port, 9443); Application.put_env(:smalt, :egress_port, 8443); Application.put_env(:smalt, :arm_tls_port, 9444); Application.put_env(:smalt, :kafka_port, 19092); {:ok, _} = Application.ensure_all_started(:smalt)' \
    9>&- </dev/null >>/tmp/witness-all-substrate.log 2>&1 &
  echo $! > /tmp/witness-all-substrate.pid )

UP=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 http://127.0.0.1:9443/metadata/endpoints >/dev/null 2>&1; then UP=1; break; fi
  sleep 2 # SLEEP-CLASS: POLL-STEP (bounded readiness poll)
done
if [ "$UP" -ne 1 ]; then echo "SUBSTRATE-BOOT-FAIL" ; exit 2; fi
echo "substrate up (pid $(cat /tmp/witness-all-substrate.pid), kafka 19092)"

cd "$DEMO"
node scripts/seed_blob_cors.mjs || exit 1
node scripts/browser_smoke.mjs 2>&1 | tee /tmp/bkskipport-smoke.txt
exit "${pipestatus[1]}"

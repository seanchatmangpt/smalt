#!/usr/bin/env bash
# scripts/courtroom_entra_identity_court.sh — r16 lane S3 court (v26.10.29).
# Entra identity plane end-to-end on smalt, zero cloud, ZERO writes into the
# consumer repo (git archive -> /tmp scratch; the T03
# courtroom_consumer_court.sh pattern with this lane's own scratch root and
# private ports).
#
# Legs:
#   1. Consumer materialize + npm ci + api build (node 22).
#   2. smalt substrate: MIX_BUILD_ROOT=_build-laneS3, private ports
#      redis 26380 / saml-idp 39445 / entra-saml 39446 / aca-identity 37001;
#      the STS mint pinned to a court RSA key (node verifies the JWTs).
#   3. Claims leg: api-A (group+role policy) full SAML sign-in through
#      EntraSaml; /api/auth/me EXACT claims.ts contract assertions.
#   4. MSI leg: ACA 17001-form token + node-crypto JWT verify; that same
#      token feeds leg 5 (workload identity -> cache auth chain).
#   5. redis AAD leg: node-redis AUTH <oid> <token> -> SET/GET/DEL, negative
#      WRONGPASS refusal, raw 1-arg AUTH user=token form.
#   6. Tenant-fence leg: api-B (FOREIGN ENTRA_TENANT_ID) -> tenant_mismatch.
#
# Exit: 0 pass / 1 assert fail / 2 substrate never up / 3 loud skip.
# Receipt: tmp/courtroom-entra-identity-receipt.json
set -uo pipefail

SMALT=${SMALT_ROOT:-/Users/sac/smalt}
CONSUMER=/Users/sac/cai/courtroom-platform-az
SCRATCH_ROOT=/tmp/courtroom-void-s3
REDIS_PORT=26380
SAML_IDP_PORT=39445
ENTRA_SAML_PORT=39446
ACA_IDENTITY_PORT=37001
API_PORT=38080
APIB_PORT=38081
APILOG=/tmp/smalt-substrate-state/s3-api.log
APIBLOG=/tmp/smalt-substrate-state/s3-apib.log
TID=11111111-1111-4111-8111-111111111111
OID=22222222-2222-4222-8222-222222222222
G1=33333333-3333-4333-8333-333333333331
G2=33333333-3333-4333-8333-333333333332
RECEIPT="$SMALT/tmp/courtroom-entra-identity-receipt.json"
mkdir -p "$(dirname "$RECEIPT")"
: > "$RECEIPT.raw"

say() { echo "[S3] $*"; }
note() { echo "$*" >> "$RECEIPT.raw"; }
stage() { say "stage $1 rc=$2"; note "\"rc_$1\": $2,"; }
fail1() { say "FAIL: $*"; note "\"verdict\": \"FAIL\", \"reason\": \"$*\""; finish 1; }
skip3() { say "SKIP: $*"; note "\"verdict\": \"SKIP\", \"reason\": \"$*\""; finish 3; }

finish() {
  {
    echo "{"
    cat "$RECEIPT.raw"
    echo "\"_end\": true"
    echo "}"
  } > "$RECEIPT"
  exit "$1"
}

# -- Leg 1: consumer materialize + npm ci + api build -------------------------
say "leg 1: materializing consumer repo (read-only git archive)"
CONSUMER_SHA=$(git -C "$CONSUMER" rev-parse HEAD) || fail1 "cannot rev-parse consumer repo"
SCRATCH="$SCRATCH_ROOT/$CONSUMER_SHA"
note "\"consumer_sha\": \"$CONSUMER_SHA\","
note "\"scratch\": \"$SCRATCH\","

if [ ! -f "$SCRATCH/apps/api/dist/server.js" ]; then
  rm -rf "$SCRATCH"
  mkdir -p "$SCRATCH"
  git -C "$CONSUMER" archive HEAD | tar -x -C "$SCRATCH" || fail1 "git archive failed"
  say "leg 1: npm ci + api build (node 22)"
  bash -lc "source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && cd '$SCRATCH' && npm ci --no-audit --no-fund && npm run build --workspace @courtroom/api" >>/tmp/s3-leg1.log 2>&1
  LEG1=$?
  stage leg1_materialize_build $LEG1
  tail -3 /tmp/s3-leg1.log | sed 's/^/[S3]   leg1: /'
  [ "$LEG1" -eq 0 ] || fail1 "npm ci/build failed (see /tmp/s3-leg1.log)"
else
  say "leg 1: warm scratch reused (dist present)"
  note "\"rc_leg1_materialize_build\": 0,"
fi

# -- Leg 2: substrate boot ------------------------------------------------------
say "leg 2: pre-flight port check (loud skip on double-bind)"
for p in "$REDIS_PORT" "$SAML_IDP_PORT" "$ENTRA_SAML_PORT" "$ACA_IDENTITY_PORT" "$API_PORT" "$APIB_PORT" 9443; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    skip3 "port $p already LISTENing - would double-bind (no pattern-kill; loud skip)"
  fi
done
note "\"ports\": \"redis=$REDIS_PORT samlidp=$SAML_IDP_PORT entra=$ENTRA_SAML_PORT aca=$ACA_IDENTITY_PORT api=$API_PORT apib=$APIB_PORT\","

tls="$SMALT/.smalt/tls"
SAML_CERT=$(cat "$tls/dev-cert.pem")
SESSION_SECRET=$(openssl rand -hex 32)
SESSION_SECRET_B=$(openssl rand -hex 32)

# Pin the STS mint to a court RSA key so the node leg can verify the JWTs.
COURT_KEY_PEM=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)
printf '%s' "$COURT_KEY_PEM" > /tmp/s3-court-sts.pem
COURT_KEY_B64=$(printf '%s' "$COURT_KEY_PEM" | base64 | tr -d '\n')

ENV_LINE="Application.put_env(:smalt, :redis_port, $REDIS_PORT); Application.put_env(:smalt, :saml_idp_port, $SAML_IDP_PORT); Application.put_env(:smalt, :entra_saml_port, $ENTRA_SAML_PORT); Application.put_env(:smalt, :aca_identity_port, $ACA_IDENTITY_PORT); Application.put_env(:smalt, :sts_signing_pem, Base.decode64!(\"$COURT_KEY_B64\")); {:ok, _} = Application.ensure_all_started(:smalt); {:ok, _} = Bandit.start_link(plug: {Smalt.Identity.EntraSaml, []}, scheme: :http, port: $ENTRA_SAML_PORT, ip: {127,0,0,1}); {:ok, _} = Bandit.start_link(plug: {Smalt.Identity.AcaIdentity, []}, scheme: :http, port: $ACA_IDENTITY_PORT, ip: {127,0,0,1}"

say "leg 2: acquiring the per-WINDOW flock and spawning the private-port beam (lock fd closed)"
LOCK=/tmp/smalt-substrate.lock
export SMALT_TLS_CERTFILE="$tls/dev-cert.pem"
export SMALT_TLS_KEYFILE="$tls/dev-key.pem"
export SSL_CERT_FILE="$tls/ca-cert.pem"
export PATH="$HOME/.asdf/shims:$PATH"
export MIX_BUILD_ROOT=_build-laneS3
exec 9>"$LOCK"
flock -w 300 9 || skip3 "could not acquire $LOCK within 300s"
set -m
cd "$SMALT" || skip3 "cannot cd $SMALT"
mix run --no-start --no-halt -e "$ENV_LINE" 9>&- </dev/null >>/tmp/s3-beam.log 2>&1 &
SPAWN_PID=$!
set +m
note "\"beam_pid\": $SPAWN_PID,"

say "leg 2: polling (deadline 180s) for listeners redis/entra/aca"
up=0
deadline=$((SECONDS + 180))
while [ "$SECONDS" -lt "$deadline" ]; do
  if lsof -nP -iTCP:"$REDIS_PORT" -sTCP:LISTEN >/dev/null 2>&1 && \
     lsof -nP -iTCP:"$ENTRA_SAML_PORT" -sTCP:LISTEN >/dev/null 2>&1 && \
     lsof -nP -iTCP:"$ACA_IDENTITY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    up=1
    break
  fi
  kill -0 "$SPAWN_PID" 2>/dev/null || break
  sleep 1 # SLEEP-CLASS: POLL-STEP
done
if [ "$up" -ne 1 ]; then
  tail -25 /tmp/s3-beam.log | sed 's/^/[S3]   beam: /'
  kill -TERM "$SPAWN_PID" 2>/dev/null || true
  note "\"verdict\": \"SUBSTRATE_DOWN\","
  finish 2
fi
stage leg2_substrate 0

# -- shared SSO flow helper (steps A-D) ------------------------------------------
sso_flow() { # sso_flow <api_port> <jar> -> echoes final ACS redirect Location
  local api_port="$1" jar="$2"

  local start_url="http://127.0.0.1:$api_port/api/sso/start"
  A_HDRS=$(curl -sS -o /tmp/s3-start-body -D - -c "$jar" "$start_url") || return 9
  A_LOC=$(printf '%s' "$A_HDRS" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')

  B_HTML=$(curl -sS -c "$jar" -b "$jar" "$A_LOC") || return 9
  B_RESP=$(printf '%s' "$B_HTML" | grep -oE 'name="SAMLResponse" value="[^"]+"' | head -1 | sed 's/.*value="//;s/"$//')
  B_ACTION=$(printf '%s' "$B_HTML" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//')
  [ -n "$B_RESP" ] || return 8
  [ -n "$B_ACTION" ] || return 7

  C_HDRS=$(curl -sS -o /tmp/s3-acs-body -D - -c "$jar" -b "$jar" \
    --data-urlencode "SAMLResponse=$B_RESP" "$B_ACTION") || return 9
  C_LOC=$(printf '%s' "$C_HDRS" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
  printf '%s' "$C_LOC"
}

# -- Leg 3: claims parity (api-A, group+role policy) ------------------------------
say "leg 3: booting api-A (group+role policy) on :$API_PORT"
bash -lc "source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && cd '$SCRATCH/apps/api' && \
  REDIS_URL=redis://127.0.0.1:$REDIS_PORT \
  PORT=$API_PORT \
  APP_ORIGIN=http://127.0.0.1:$API_PORT \
  SAML_ENTRY_POINT=http://127.0.0.1:$ENTRA_SAML_PORT/sso \
  SAML_IDP_ISSUER=https://sts.windows.net/$TID/ \
  SAML_ISSUER=http://127.0.0.1:$API_PORT \
  SAML_IDP_CERT=\"${SAML_CERT}\" \
  ENTRA_TENANT_ID=$TID \
  AUTH_ALLOWED_GROUP_IDS=$G1,$G2 \
  AUTH_ALLOWED_ROLES=Admin \
  AUTH_GROUP_LABELS=$G1:Owners,$G2:Members \
  SESSION_SECRET='$SESSION_SECRET' \
  node dist/server.js" 9>&- </dev/null >"$APILOG" 2>&1 &
API_PID=$!

say "leg 3: polling api-A :$API_PORT (deadline 60s) + asserting store=redis"
api_up=0
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
  if lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN >/dev/null 2>&1; then api_up=1; break; fi
  kill -0 "$API_PID" 2>/dev/null || break
  sleep 1 # SLEEP-CLASS: POLL-STEP
done
STORE_LINE=$(grep -o '"store":"[a-z]*"' "$APILOG" | head -1)
[ "$STORE_LINE" = '"store":"redis"' ] || fail1 "api-A did not report redis store (got: ${STORE_LINE:-NONE})"
[ "$api_up" -eq 1 ] || fail1 "api-A not listening on :$API_PORT"
stage leg3_apiA_up 0

say "leg 3: driving SSO flow A->D"
C_LOC=$(sso_flow $API_PORT /tmp/s3-jarA) || fail1 "SSO flow failed rc=$?"
say "leg 3: ACS -> $C_LOC"
case "$C_LOC" in */dashboard*) : ;; *) fail1 "expected /dashboard redirect, got $C_LOC" ;; esac

ME_CODE=$(curl -sS -o /tmp/s3-me.json -w '%{http_code}' -b /tmp/s3-jarA "http://127.0.0.1:$API_PORT/api/auth/me")
[ "$ME_CODE" = "200" ] || fail1 "/api/auth/me not 200 (got $ME_CODE)"

say "leg 3: node asserts the exact claims.ts contract"
bash -lc "source ~/.nvm/nvm.sh && nvm use 22 >/dev/null" && node "$SMALT/scripts/courtroom_entra_assert_me.mjs" /tmp/s3-me.json "$TID" "$G1" "$G2" \
  || fail1 "claims.ts contract assertions failed"
note "\"rc_leg3_claims\": 0,"
note "\"me_head\": $(head -c 400 /tmp/s3-me.json),"

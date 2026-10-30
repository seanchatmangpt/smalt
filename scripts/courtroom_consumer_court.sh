#!/usr/bin/env bash
# scripts/courtroom_consumer_court.sh — T03 consumer court: prove
# courtroom-platform-az (consumer, ZERO writes to that repo) runs on smalt
# with zero cloud.
#
# Legs:
#   1. Consumer materialize (git archive HEAD -> /tmp/courtroom-void/<sha>)
#      + node 22 npm ci + npm run check (rc-captured).
#   2. Substrate leg — GATED on the concurrent lanes' files existing:
#      lib/smalt/data_plane/redis_wire.ex + lib/smalt/identity/saml_idp.ex.
#      Waits (bounded poll, 25 min max), then boots smalt faces and polls
#      redis 16380 + saml idp 19445. Config wiring is read from the landed
#      modules' Application.get_env keys; if config/config.exs does not wire
#      env overrides and a private-port beam cannot be lawfully started, the
#      leg is SKIPPED LOUDLY (exit 3) — never a silent skip.
#   3. Consumer-on-smalt leg: boot apps/api from the scratch materialization
#      against the smalt redis wire + saml idp, and drive the real sign-in
#      flow: /api/sso/start -> IdP /sso -> auto-POST form (SAMLResponse) ->
#      ACS -> cookie -> GET /api/auth/me == 200.
#
# Exit contract: 0 pass / 1 assert fail / 2 substrate never up / 3 loud skip.
# Receipt: tmp/courtroom-court-receipt.json
set -uo pipefail

SMALT=/Users/sac/smalt
CONSUMER=/Users/sac/cai/courtroom-platform-az
SCRATCH_ROOT=/tmp/courtroom-void
REDIS_PORT=16380
SAML_PORT=19445
API_PORT=18080
GATE_WAIT_SECS=${T03_GATE_WAIT_SECS:-1500}   # 25 min
RECEIPT="$SMALT/tmp/courtroom-court-receipt.json"

mkdir -p "$(dirname "$RECEIPT")"
: > "$RECEIPT.raw"

say() { echo "[T03] $*"; }
note() { echo "$*" >> "$RECEIPT.raw"; }
fail1() { say "FAIL: $*"; note "\"verdict\": \"FAIL\", \"reason\": \"$*\""; finish 1; }
skip3() { say "SKIP: $*"; note "\"verdict\": \"SKIP\", \"reason\": \"$*\""; finish 3; }

finish() {
  {
    echo "{"
    cat "$RECEIPT.raw"
    echo "}"
  } > "$RECEIPT"
  exit "$1"
}

stage() { # stage <name> <rc> — rc-captured, never silent
  local name="$1" rc="$2"
  note "\"rc_$name\": $rc,"
  say "stage $name rc=$rc"
}

################################################################################
# Leg 1 — consumer materialize + check (FIRST, independent of smalt)
################################################################################
say "leg 1: materializing consumer repo (read-only archive)"
CONSUMER_SHA=$(git -C "$CONSUMER" rev-parse HEAD) || fail1 "cannot rev-parse consumer repo"
SCRATCH="$SCRATCH_ROOT/$CONSUMER_SHA"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
git -C "$CONSUMER" archive HEAD | tar -x -C "$SCRATCH" || fail1 "git archive failed"
note "\"consumer_sha\": \"$CONSUMER_SHA\","
note "\"scratch\": \"$SCRATCH\","

say "leg 1: npm ci (node 22)"
bash -lc "source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && cd '$SCRATCH' && npm ci --no-audit --no-fund" >>"$RECEIPT.raw.log" 2>&1
LEG1_CI=$?
stage leg1_npm_ci $LEG1_CI
tail -3 "$RECEIPT.raw.log" | sed 's/^/[T03]   ci: /'

if [ "$LEG1_CI" -ne 0 ]; then
  fail1 "npm ci failed on node 22 (see $RECEIPT.raw.log)"
fi

say "leg 1: npm run check"
bash -lc "source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && cd '$SCRATCH' && npm run check" >>"$RECEIPT.raw.log" 2>&1
LEG1_CHECK=$?
stage leg1_check $LEG1_CHECK
tail -6 "$RECEIPT.raw.log" | sed 's/^/[T03]   check: /'
if [ "$LEG1_CHECK" -ne 0 ]; then
  fail1 "npm run check failed (see $RECEIPT.raw.log)"
fi

# apps/api must be built for leg 3 (npm run check builds workspaces).
[ -f "$SCRATCH/apps/api/dist/server.js" ] || fail1 "apps/api/dist/server.js missing after check"

################################################################################
# Leg 2 — substrate leg, gated on the two concurrent lane files
################################################################################
say "leg 2: waiting (bounded ${GATE_WAIT_SECS}s) for lane files redis_wire.ex + saml_idp.ex"
deadline=$((SECONDS + GATE_WAIT_SECS))
until [ -f "$SMALT/lib/smalt/data_plane/redis_wire.ex" ] && [ -f "$SMALT/lib/smalt/identity/saml_idp.ex" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    skip3 "gate timeout: redis_wire.ex/saml_idp.ex not landed within ${GATE_WAIT_SECS}s"
  fi
  sleep 5 # SLEEP-CLASS: POLL-STEP (bounded gate poll)
done
say "leg 2: lane files present; reading their config keys"

# Read the ACTUAL config keys from the landed modules (no invented env vars).
REDIS_KEY_HINT=$(grep -oE 'Application\.get_env\(:smalt, :[a-z_]+' "$SMALT/lib/smalt/data_plane/redis_wire.ex" | sort -u | tr '\n' ' ')
SAML_KEY_HINT=$(grep -oE 'Application\.get_env\(:smalt, :[a-z_]+' "$SMALT/lib/smalt/identity/saml_idp.ex" | sort -u | tr '\n' ' ')
note "\"redis_wire_env_keys\": \"$REDIS_KEY_HINT\","
note "\"saml_idp_env_keys\": \"$SAML_KEY_HINT\","
say "leg 2: redis_wire keys: $REDIS_KEY_HINT"
say "leg 2: saml_idp keys: $SAML_KEY_HINT"

ENV_WIRED=$(grep -c "System.get_env" "$SMALT/config/config.exs" 2>/dev/null || true)
note "\"config_exs_System_get_env_count\": $ENV_WIRED,"

# Lawful private-port boot: the substrate.sh-identical pattern (mix run
# --no-start --no-halt -e 'Application.put_env(...); ensure_all_started').
# No smalt config/ file is created or edited.
PORT_LINE="Application.put_env(:smalt, :redis_port, $REDIS_PORT); Application.put_env(:smalt, :saml_idp_port, $SAML_PORT)"
tls="$SMALT/.smalt/tls"
export SMALT_TLS_CERTFILE="$tls/dev-cert.pem"
export SMALT_TLS_KEYFILE="$tls/dev-key.pem"
export SSL_CERT_FILE="$tls/ca-cert.pem"
export PATH="$HOME/.asdf/shims:$PATH"
LOCK=/tmp/smalt-substrate.lock
T03LOG=/tmp/smalt-substrate-state/t03-court.log
mkdir -p /tmp/smalt-substrate-state

say "leg 2: acquiring per-WINDOW flock and spawning private-port beam (lock fd closed)"
exec 9>"$LOCK"
if ! flock -w 300 9; then
  skip3 "could not acquire $LOCK within 300s"
fi
set -m
cd "$SMALT" || skip3 "cannot cd $SMALT"
mix run --no-start --no-halt -e "$PORT_LINE; {:ok, _} = Application.ensure_all_started(:smalt)" \
  9>&- </dev/null >>"$T03LOG" 2>&1 &
SPAWN_PID=$!
set +m

say "leg 2: polling (deadline 90s) for listeners $REDIS_PORT + $SAML_PORT"
up=0
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
  if lsof -nP -iTCP:"$REDIS_PORT" -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:"$SAML_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    up=1
    break
  fi
  kill -0 "$SPAWN_PID" 2>/dev/null || break
  sleep 1 # SLEEP-CLASS: POLL-STEP (bounded listener poll)
done

if [ "$up" -ne 1 ]; then
  tail -25 "$T03LOG" | sed 's/^/[T03]   beam: /'
  kill -TERM "$SPAWN_PID" 2>/dev/null || true
  note "\"verdict\": \"SUBSTRATE_DOWN\","
  finish 2
fi
stage leg2_substrate 0
note "\"beam_pid\": $SPAWN_PID,"
say "leg 2: substrate faces UP (redis :$REDIS_PORT, saml idp :$SAML_PORT, beam $SPAWN_PID)"

################################################################################
# Leg 3 — consumer-on-smalt: real sign-in flow through the consumer's
# @node-saml code against the smalt faces.
################################################################################
SAML_CERT=$(cat "$tls/dev-cert.pem")
SESSION_SECRET=$(openssl rand -hex 32)
APILOG=/tmp/smalt-substrate-state/t03-api.log
: > "$APILOG"
say "leg 3: booting apps/api from scratch on :$API_PORT"
bash -lc "source ~/.nvm/nvm.sh && nvm use 22 >/dev/null && cd '$SCRATCH/apps/api' && \
  REDIS_URL=redis://127.0.0.1:$REDIS_PORT \
  PORT=$API_PORT \
  APP_ORIGIN=http://127.0.0.1:$API_PORT \
  SAML_ENTRY_POINT=http://127.0.0.1:$SAML_PORT/sso \
  SAML_IDP_ISSUER=urn:smalt:identity:saml \
  SAML_ISSUER=http://127.0.0.1:$API_PORT \
  SAML_IDP_CERT=\"${SAML_CERT}\" \
  AUTH_ALLOW_ALL_ASSIGNED_USERS=true \
  SESSION_SECRET='$SESSION_SECRET' \
  node dist/server.js" 9>&- </dev/null >"$APILOG" 2>&1 &
API_PID=$!

say "leg 3: polling for API on :$API_PORT (deadline 60s) + asserting store=redis"
api_up=0
deadline=$((SECONDS + 60))
while [ "$SECONDS" -lt "$deadline" ]; do
  if lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN >/dev/null 2>&1; then api_up=1; break; fi
  kill -0 "$API_PID" 2>/dev/null || break
  sleep 1 # SLEEP-CLASS: POLL-STEP
done
grep -o '"store":"[a-z]*"' "$APILOG" | head -1 >>"$RECEIPT.raw" || true
sed 's/^/[T03]   api: /' "$APILOG" | tail -10
STORE_LINE=$(grep -o '"store":"[a-z]*"' "$APILOG" | head -1)
note "\"api_store_line\": \"${STORE_LINE:-NONE}\","
[ "$STORE_LINE" = '"store":"redis"' ] || fail1 "api did not report redis store (got: ${STORE_LINE:-NONE})"
[ "$api_up" -eq 1 ] || fail1 "api not listening on $API_PORT"
say "leg 3: API UP with redis store; driving SAML sign-in flow"

JAR=/tmp/t03-cookies.jar
rm -f "$JAR"

# Step A: /api/sso/start -> expect redirect to the smalt IdP /sso.
START_URL="http://127.0.0.1:$API_PORT/api/sso/start"
A_HDRS=$(curl -sS -o /tmp/t03-start-body -D - -c "$JAR" "$START_URL") || fail1 "sso/start curl failed"
A_LOC=$(printf '%s' "$A_HDRS" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
note "\"sso_start_location\": \"$A_LOC\","
say "leg 3 A: sso/start -> $A_LOC"
case "$A_LOC" in
  http://127.0.0.1:$SAML_PORT/sso*) : ;;
  *) fail1 "sso/start did not redirect to smalt IdP (got: $A_LOC)" ;;
esac

# Step B: GET the IdP /sso with the SAMLRequest; extract the auto-POST form.
B_HTML=$(curl -sS -L -c "$JAR" -b "$JAR" "$A_LOC") || fail1 "IdP /sso fetch failed"
B_ACTION=$(printf '%s' "$B_HTML" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//')
B_RESP=$(printf '%s' "$B_HTML" | grep -oE 'name="SAMLResponse" value="[^"]+"' | head -1 | sed 's/.*value="//;s/"$//')
note "\"idp_form_action\": \"$B_ACTION\","
note "\"saml_response_len\": ${#B_RESP},"
say "leg 3 B: IdP form action=$B_ACTION SAMLResponse len=${#B_RESP}"
[ -n "$B_ACTION" ] || fail1 "no auto-POST form action from IdP /sso"
[ -n "$B_RESP" ] || fail1 "no SAMLResponse in IdP /sso form"

# Step C: POST the form to the ACS with the cookie jar; expect redirect.
C_HDRS=$(curl -sS -o /tmp/t03-acs-body -D - -c "$JAR" -b "$JAR" \
  --data-urlencode "SAMLResponse=$B_RESP" "$B_ACTION") || fail1 "ACS POST failed"
C_LOC=$(printf '%s' "$C_HDRS" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')
C_CODE=$(printf '%s' "$C_HDRS" | head -1 | awk '{print $2}')
note "\"acs_status\": $C_CODE,"
note "\"acs_location\": \"$C_LOC\","
say "leg 3 C: ACS POST -> $C_CODE $C_LOC"
case "$C_LOC" in
  */dashboard*) : ;;
  *) fail1 "ACS did not redirect to dashboard (got $C_CODE $C_LOC)" ;;
esac

# Step D: GET /api/auth/me with the session cookie; expect 200 + user JSON.
ME_CODE=$(curl -sS -o /tmp/t03-me.json -w '%{http_code}' -b "$JAR" \
  "http://127.0.0.1:$API_PORT/api/auth/me") || fail1 "auth/me curl failed"
ME_BODY=$(head -c 300 /tmp/t03-me.json)
note "\"auth_me_status\": $ME_CODE,"
note "\"auth_me_body\": \"$ME_BODY\","
say "leg 3 D: /api/auth/me -> $ME_CODE $ME_BODY"
[ "$ME_CODE" = "200" ] || fail1 "/api/auth/me not 200 (got $ME_CODE)"
printf '%s' "$ME_BODY" | grep -q 'name\|user\|email' || fail1 "auth/me body is not a user JSON: $ME_BODY"

note "\"verdict\": \"ALIVE\""
say "PASS: full consumer sign-in flow validated through the consumer's own @node-saml code on smalt faces"
kill -TERM "$API_PID" 2>/dev/null || true
kill -TERM "$SPAWN_PID" 2>/dev/null || true
sleep 0.5 # SLEEP-CLASS: POLL-STEP
finish 0

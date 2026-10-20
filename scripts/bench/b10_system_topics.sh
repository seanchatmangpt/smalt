#!/usr/bin/env bash
# scripts/bench/b10_system_topics.sh — lane b10 witness: the systemTopics ARM
# family (PUT 201 -> GET 200 -> LIST -> DELETE -> 404) plus the
# eventSubscriptions child face (in-proc admitted, WebHook destination
# typed-refused per KD-101).
#
# Auth: :enforce (default config.exs mode — NOT the MIX_ENV=test anonymous
# bench boot); the bearer is minted from the emulator STS at
# /{tid}/oauth2/v2.0/token.
#
# Port law: lane b10 -> 39100..39105 (39000 + 10*10).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/bench/lib.sh"

BENCH_RESULTS_DIR="$REPO/docs/jira/v26.10.20/bench"
mkdir -p "$BENCH_RESULTS_DIR"
RESULT_FILE="$BENCH_RESULTS_DIR/b10-system-topics.jsonl"
LANE_ROOT="$REPO/_build-lane-w4j"

trap 'bench_down "${BENCH_BOOT_PID:-}"' EXIT INT TERM

read -r ARM DATA AMQP EHUB ATLS MCP <<<"$(bench_lane_ports b10)"
BASE="http://localhost:$ARM"
TID="00000000-0000-0000-0000-000000000000"
RG="rg-b10"
ST="sysb10"
API="api-version=2021-04-01"

# -- Boot (enforce mode: default env, no MIX_ENV=test override) --------------
for p in $ARM $DATA $AMQP $EHUB $ATLS $MCP; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[b10] port $p already held — refusing to boot (collision)" >&2
    exit 1
  fi
done

LOG="$REPO/tmp/bench-substrate-b10.log"
mkdir -p "$(dirname "$LOG")"

EVAL_CODE="Application.put_env(:smalt, :arm_port, ${ARM}); Application.put_env(:smalt, :egress_port, ${DATA}); Application.put_env(:smalt, :amqp_port, ${AMQP}); Application.put_env(:smalt, :event_hubs_port, ${EHUB}); Application.put_env(:smalt, :arm_tls_port, ${ATLS}); Application.put_env(:smalt, :mcp_port, ${MCP}); {:ok, _} = Application.ensure_all_started(:smalt); Process.sleep(:infinity)"

MIX_BUILD_ROOT="$LANE_ROOT" \
SMALT_TEST_ARM_PORT=$ARM SMALT_TEST_EGRESS_PORT=$DATA \
SMALT_TEST_AMQP_PORT=$AMQP SMALT_TEST_EVENT_HUBS_PORT=$EHUB \
mix run --no-start -e "$EVAL_CODE" --no-halt \
  >"$LOG" 2>&1 </dev/null 9>&- &
BENCH_BOOT_PID=$!

for i in $(seq 1 120); do
  if lsof -nP -iTCP:"$ARM" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
  kill -0 "$BENCH_BOOT_PID" 2>/dev/null || { echo "[b10] substrate died; log: $LOG" >&2; exit 2; }
  # SLEEP-CLASS: POLL-STEP — bounded readiness poll on a real observable.
  sleep 1
done
lsof -nP -iTCP:"$ARM" -sTCP:LISTEN >/dev/null 2>&1 || { echo "[b10] TYPED-TIMEOUT(124)" >&2; exit 124; }

# -- Mint bearer from the emulator STS ---------------------------------------
TOKEN=$(curl -sS -X POST "$BASE/$TID/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=b10&client_secret=b10&resource=https://management.azure.com" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
AUTH="Authorization: Bearer $TOKEN"
CT="Content-Type: application/json"

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS $1 (expected $2, got $3)"
  else
    echo "FAIL $1 (expected $2, got $3)" >&2
    exit 1
  fi
}

# -- 1. PUT systemTopic -> 201 ------------------------------------------------
PUT_CODE=$(curl -sS -o /tmp/b10-put.json -w '%{http_code}' -X PUT \
  "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST?$API" \
  -H "$AUTH" -H "$CT" \
  -d "{\"location\":\"eastus\",\"properties\":{\"source\":\"/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.Storage/storageaccounts/accb10\",\"topicType\":\"Microsoft.EventGrid.BlobCreated\"}}")
check "PUT systemTopic" 201 "$PUT_CODE"

# -- 2. GET -> 200 with topicType + source echo -------------------------------
GET_CODE=$(curl -sS -o /tmp/b10-get.json -w '%{http_code}' \
  "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST?$API" -H "$AUTH")
check "GET systemTopic" 200 "$GET_CODE"
python3 - <<'PY'
import json
rec = json.load(open("/tmp/b10-get.json"))
props = rec["properties"]
assert props["topicType"] == "Microsoft.EventGrid.BlobCreated", props
assert "storageaccounts" in props["source"], props
assert props["provisioningState"] == "Succeeded", props
print("PASS GET body (topicType + source echoed, provisioningState Succeeded)")
PY

# -- 3. LIST -> contains the topic --------------------------------------------
LIST_COUNT=$(curl -sS "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics?$API" -H "$AUTH" \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["value"]))')
check "LIST systemTopics contains 1" 1 "$LIST_COUNT"

# -- 4. eventSubscriptions child face -----------------------------------------
ES="es-b10"
PUT_ES_CODE=$(curl -sS -o /tmp/b10-es-put.json -w '%{http_code}' -X PUT \
  "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST/eventSubscriptions/$ES?$API" \
  -H "$AUTH" -H "$CT" -d '{}')
check "PUT eventSubscription (in-proc)" 201 "$PUT_ES_CODE"

LIST_ES_COUNT=$(curl -sS "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST/eventSubscriptions?$API" -H "$AUTH" \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["value"]))')
check "LIST eventSubscriptions" 1 "$LIST_ES_COUNT"

WH_CODE=$(curl -sS -o /tmp/b10-es-wh.json -w '%{http_code}' -X PUT \
  "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST/eventSubscriptions/es-webhook?$API" \
  -H "$AUTH" -H "$CT" \
  -d '{"properties":{"destination":{"endpointType":"WebHook","endpointUrl":"https://remote.example.com/hook"}}}')
check "PUT WebHook destination typed-refused" 400 "$WH_CODE"
grep -q "EventGridWebhookPushUnsupported" /tmp/b10-es-wh.json

# -- 5. DELETE cascade + 404 ---------------------------------------------------
DEL_CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
  "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST?$API" -H "$AUTH")
check "DELETE systemTopic" 200 "$DEL_CODE"

GET404=$(curl -sS -o /dev/null -w '%{http_code}' \
  "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST?$API" -H "$AUTH")
check "GET after DELETE" 404 "$GET404"

ES404=$(curl -sS -o /dev/null -w '%{http_code}' \
  "$BASE/subscriptions/s10/resourceGroups/$RG/providers/Microsoft.EventGrid/systemTopics/$ST/eventSubscriptions/$ES?$API" -H "$AUTH")
check "child eventSubscription cascade-deleted (GET 404)" 404 "$ES404"

BENCH_LANE=b10 bench_emit "$RESULT_FILE" arm_systemtopics crud_witness 1 0 0 0 0 0
echo "[b10] witness complete: $RESULT_FILE"

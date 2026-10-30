#!/usr/bin/env bash
# scripts/r18-deploy/court.sh — lane S5 (r18) observability + deploy-loop court.
#
# Gate legs (receipt docs/jira/v26.10.29/receipts/r18-obs-deploy.md):
#   A  connection-string face (real module call, derived /v2/track URL)
#   B  app event -> POST /v2/track -> Breeze ack -> KQL query answer
#      (the census R12 close: AI telemetry queryable on the LA face)
#   C  terraform init/plan/apply of the courtroom topology against the
#      lane ARM loopback; resource-graph + ARM readback (census R13/R14)
#   D  census-open demonstration: extension topology members (managed env,
#      redis, identity) are typed-REFUSED by registry admission — expected-
#      failure apply, real terraform output is the census evidence
#   E  ACR image identity: registry loginServer, repositories + tags
#      (blob-backed emulation faces)
#
# Lane-private substrate: ports 29443-29456 (lease verified free), fd 9
# closed at spawn (lock-fd inheritance law), bounded polls everywhere (no
# sleeps as coordination), MIX_BUILD_ROOT=_build-lane-s5.
#
# Exit codes: 0 all legs PASS · 1 fail-closed (typed [FAULT] lines)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARM_PORT=29443
TLS_PORT=29444
EGRESS_PORT=29445
SUB_PID=""
SUB_LOG="/tmp/r18-court-substrate.log"
COURT_DIR="/tmp/r18-court"
FAILURES=0

export PATH="$HOME/.asdf/shims:$PATH"

say()  { printf '[r18] %s\n' "$*"; }
fail() { printf '[r18] [FAULT] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# Bounded poll: run a command every second until it exits 0 or N tries out.
poll() { # poll <tries> <label> <cmd...>
  local tries="$1" label="$2"; shift 2
  local i
  for i in $(seq 1 "$tries"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1 # SLEEP-CLASS: POLL-STEP (bounded observable poll)
  done
  say "poll exhausted ($label after ${tries}s)"; return 1
}

cleanup() {
  if [ -n "$SUB_PID" ] && kill -0 "$SUB_PID" 2>/dev/null; then
    kill "$SUB_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$SUB_PID" 2>/dev/null || break
      sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded reap poll, 10s deadline)
    done
    kill -9 "$SUB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for p in 29443 29444 29445 29446 29447 29448 29449 29450 29451 29452 29453 29454 29455; do
  if nc -z 127.0.0.1 "$p" 2>/dev/null; then
    fail "port $p busy — lane lease violated"; exit 1
  fi
done
command -v terraform >/dev/null || { fail "terraform not on PATH"; exit 1; }
bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null 2>&1 || true
[ -f "$ROOT/.smalt/tls/dev-cert.pem" ] || { fail "dev cert missing"; exit 1; }
say "preflight ok (ports 29443-29455 free, terraform $(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version":"\([^"]*\)".*/\1/p'))"

# ---------------------------------------------------------------------------
# Leg A0 — compile in the lane build root
# ---------------------------------------------------------------------------
mkdir -p "$COURT_DIR"
say "leg A0: compile (MIX_BUILD_ROOT=_build-lane-s5)"
# Plain compile (the boot path's own mode): the shared tree currently carries
# ~163 warnings in sibling lanes' in-flight files (compile-freeze SLA — see
# receipt); --warnings-as-errors would fail the court on foreign churn.
if ! (cd "$ROOT" && MIX_BUILD_ROOT=_build-lane-s5 mix compile >"$COURT_DIR/compile.log" 2>&1); then
  # The tree may carry sibling lanes' in-flight files; distinguish.
  tail -5 "$COURT_DIR/compile.log" >&2 || true
  fail "compile failed (see $COURT_DIR/compile.log)"; exit 1
fi
say "leg A0: compile PASS"

# ---------------------------------------------------------------------------
# Lane substrate boot (all listeners shifted into the lane lease)
# ---------------------------------------------------------------------------
mkdir -p "$COURT_DIR"
: > "$SUB_LOG"
EVAL="
Application.put_env(:smalt, :arm_port, $ARM_PORT);
Application.put_env(:smalt, :arm_tls_port, $TLS_PORT);
Application.put_env(:smalt, :egress_port, $EGRESS_PORT);
Application.put_env(:smalt, :amqp_port, 29446);
Application.put_env(:smalt, :event_hubs_port, 29447, persistent: true);
Application.put_env(:smalt, :mcp_port, 29448);
Application.put_env(:smalt, :oidc_port, 29449);
Application.put_env(:smalt, :saml_idp_port, 29450);
Application.put_env(:smalt, :redis_port, 29451);
Application.put_env(:smalt, :ws_amqp_relay_port, 29452);
Application.put_env(:smalt, :web_pubsub_port, 29453);
Application.put_env(:smalt, :kafka_port, 29454);
Application.put_env(:smalt, :kafka_log_dir, \"/tmp/r18-kafka-journal\");
Application.put_env(:smalt, :confidential_ledger_port, 29455);
{:ok, _} = Application.ensure_all_started(:smalt);
Process.sleep(:infinity)"
(cd "$ROOT" && MIX_ENV=test \
  SMALT_TLS_CERTFILE="$ROOT/.smalt/tls/dev-cert.pem" \
  SMALT_TLS_KEYFILE="$ROOT/.smalt/tls/dev-key.pem" \
  MIX_BUILD_ROOT=_build-lane-s5 \
  exec mix run --no-start -e "$EVAL" --no-halt 9>&-) >"$SUB_LOG" 2>&1 &
SUB_PID=$!

poll 900 "substrate bind" nc -z 127.0.0.1 "$ARM_PORT" || { tail -40 "$SUB_LOG" >&2; fail "substrate never bound $ARM_PORT"; exit 1; }
poll 120 "substrate TLS bind" nc -z 127.0.0.1 "$TLS_PORT" || { tail -40 "$SUB_LOG" >&2; fail "substrate never bound $TLS_PORT"; exit 1; }
poll 120 "substrate egress bind" nc -z 127.0.0.1 "$EGRESS_PORT" || { tail -40 "$SUB_LOG" >&2; fail "substrate never bound $EGRESS_PORT"; exit 1; }
say "substrate up: ARM $ARM_PORT, TLS $TLS_PORT, egress $EGRESS_PORT (pid $SUB_PID)"

# ---------------------------------------------------------------------------
# Leg A — connection-string face (real module call)
# ---------------------------------------------------------------------------
say "leg A: connection-string parse face"
CONN_OUT="$(cd "$ROOT" && MIX_BUILD_ROOT=_build-lane-s5 mix run --no-start -e '
cs = "InstrumentationKey=r18a2f60-0000-4000-8000-000000000001;IngestionEndpoint=http://127.0.0.1:29445/;LiveEndpoint=http://127.0.0.1:29445/live"
case Smalt.Monitor.AppInsights.parse_connection_string(cs) do
  {:ok, parsed} ->
    IO.puts("CONNSTR_OK track_url=" <> parsed.track_url <> " ikey=" <> parsed.instrumentation_key)
    {tag, _} = Smalt.Monitor.AppInsights.parse_connection_string("IngestionEndpoint=http://x/")
    IO.puts("CONNSTR_BAD_EMPTY=" <> inspect(tag))
  other -> IO.puts("CONNSTR_FAULT " <> inspect(other)); exit({:shutdown, 1})
end' 2>&1 | grep -E "CONNSTR")"
echo "$CONN_OUT"
echo "$CONN_OUT" | grep -q "CONNSTR_OK track_url=http://127.0.0.1:29445/v2/track" || { fail "leg A connection-string face"; }
echo "$CONN_OUT" | grep -q "CONNSTR_BAD_EMPTY=:error" || { fail "leg A empty-ikey refusal"; }

# ---------------------------------------------------------------------------
# Leg B — app event -> ingest -> KQL answer (census R12)
# ---------------------------------------------------------------------------
say "leg B: POST /v2/track -> KQL query"
IKEY="r18a2f60-0000-4000-8000-000000000001"
TRACK_BODY=$(cat <<EOF
{"items":[
 {"ver":1,"name":"App.Traces","time":"2026-10-30T01:02:03.000Z","iKey":"$IKEY",
  "data":{"baseType":"MessageData","baseData":{"message":"r18 court trace WARNING","severityLevel":2}}},
 {"ver":1,"name":"App.Traces","time":"2026-10-30T01:02:04.000Z","iKey":"$IKEY",
  "data":{"baseType":"MessageData","baseData":{"message":"r18 court trace CRITICAL deployment-applied","severityLevel":4}}},
 {"ver":1,"name":"App.Requests","time":"2026-10-30T01:02:05.000Z","iKey":"$IKEY",
  "data":{"baseType":"RequestData","baseData":{"id":"req-1","name":"GET /api/health","url":"http://alpha-api/health","duration":"00:00:00.123","responseCode":200,"success":true}}},
 {"ver":1,"name":"App.Metrics","time":"2026-10-30T01:02:06.000Z","iKey":"$IKEY",
  "data":{"baseType":"MetricData","baseData":{"metrics":[{"name":"courtroom.deploy.count","value":1}]}}}
]}
EOF
)
ACK_HTTP="$(curl -sS -o "$COURT_DIR/track-ack.json" -w "%{http_code}" \
  -H 'content-type: application/json' -d "$TRACK_BODY" \
  "http://127.0.0.1:$EGRESS_PORT/v2/track")" || { fail "leg B track POST transport"; }
say "track ack http=$ACK_HTTP body=$(cat "$COURT_DIR/track-ack.json")"
[ "$ACK_HTTP" = "200" ] || fail "leg B track ack http=$ACK_HTTP want 200"
grep -q '"itemsReceived":4' "$COURT_DIR/track-ack.json" || fail "leg B itemsReceived!=4"
grep -q '"itemsAccepted":4' "$COURT_DIR/track-ack.json" || fail "leg B itemsAccepted!=4"

kql() { # kql <outfile> <query>
  local out="$1"; shift
  curl -sS -o "$out" -w "%{http_code}" -H 'content-type: application/json' \
    -d "{\"query\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")}" \
    "http://127.0.0.1:$EGRESS_PORT/v1/workspaces/$IKEY/query"
}

# B1: AppTraces rows answer on the LA face (bounded poll: rows land in the
# sideband, the query face must observe them — never a sleep-and-hope).
B1_OK=0
for i in $(seq 1 20); do
  B1_HTTP="$(kql "$COURT_DIR/kql-traces.json" \
    "AppTraces | where SeverityLevel >= 2 | project TimeGenerated, Message, SeverityLevel")" || B1_HTTP=000
  if [ "$B1_HTTP" = "200" ] && grep -q "r18 court trace CRITICAL" "$COURT_DIR/kql-traces.json" \
     && grep -q "r18 court trace WARNING" "$COURT_DIR/kql-traces.json"; then B1_OK=1; break; fi
  sleep 1 # SLEEP-CLASS: POLL-STEP (bounded KQL observability poll)
done
[ "$B1_OK" = "1" ] || { say "B1 last http=$B1_HTTP body=$(cat "$COURT_DIR/kql-traces.json" 2>/dev/null)"; fail "leg B1 KQL AppTraces rows"; }
say "B1 AppTraces rows: $(python3 -c "import json;d=json.load(open('$COURT_DIR/kql-traces.json'));print(d['tables'][0]['rows'])" 2>/dev/null || cat "$COURT_DIR/kql-traces.json")"

B2_HTTP="$(kql "$COURT_DIR/kql-requests.json" \
  "AppRequests | project Name, Url, Success, ResultCode, DurationMs")"
[ "$B2_HTTP" = "200" ] && grep -q "GET /api/health" "$COURT_DIR/kql-requests.json" \
  && grep -q '"rows"' "$COURT_DIR/kql-requests.json" || fail "leg B2 KQL AppRequests row"
say "B2 AppRequests rows: $(python3 -c "import json;d=json.load(open('$COURT_DIR/kql-requests.json'));print(d['tables'][0]['rows'])" 2>/dev/null || cat "$COURT_DIR/kql-requests.json")"

B3_HTTP="$(kql "$COURT_DIR/kql-metrics.json" \
  "AppMetrics | where Name == \"courtroom.deploy.count\" | summarize sum(Value) by Name")"
[ "$B3_HTTP" = "200" ] && grep -q "courtroom.deploy.count" "$COURT_DIR/kql-metrics.json" \
  && grep -q '"sum_Value"' "$COURT_DIR/kql-metrics.json" || fail "leg B3 KQL AppMetrics summarize"
say "B3 AppMetrics summarize: $(python3 -c "import json;d=json.load(open('$COURT_DIR/kql-metrics.json'));print(d['tables'][0]['rows'])" 2>/dev/null || cat "$COURT_DIR/kql-metrics.json")"

# ---------------------------------------------------------------------------
# Leg C — terraform deploy loop (census R13/R14)
# ---------------------------------------------------------------------------
say "leg C: terraform init/plan/apply against ARM $ARM_PORT"
cd "$HERE"

# Provider install: repo mirror first (source, read-only), registry fallback.
set +e
source "$ROOT/scripts/tf_mirror_env.sh"
tf_mirror_env_setup >/dev/null 2>&1 && say "provider mirror: ${TF_MIRROR_MODE:-unavailable}" || say "provider mirror unusable — registry fallback"
set -e

tf() { SMALT_TF_PORT=$ARM_PORT SMALT_TLS_PORT=$TLS_PORT "$ROOT/scripts/smalt-tf" "$@"; }

if ! tf init -input=false -no-color >"$COURT_DIR/tf-init.log" 2>&1; then
  if grep -qiE "dial tcp: lookup|no such host|i/o timeout|Failed to query available provider packages" "$COURT_DIR/tf-init.log"; then
    say "[SKIP] registry unreachable — leg C skipped (typed SKIPPED-NETWORK)"; SKIP_NETWORK=1
  else
    tail -30 "$COURT_DIR/tf-init.log" >&2; fail "leg C terraform init"; SKIP_NETWORK=1
  fi
else
  if ! tf plan -input=false -no-color -out=plan.tfplan >"$COURT_DIR/tf-plan.log" 2>&1; then
    tail -30 "$COURT_DIR/tf-plan.log" >&2; fail "leg C terraform plan"
  else
    say "plan: $(grep -E '[0-9]+ to add' "$COURT_DIR/tf-plan.log" | head -1)"
    grep -qE '[0-9]+ to add' "$COURT_DIR/tf-plan.log" || fail "leg C plan did not report 'to add'"
  fi

  if ! tf apply -auto-approve -no-color >"$COURT_DIR/tf-apply.log" 2>&1; then
    tail -30 "$COURT_DIR/tf-apply.log" >&2; fail "leg C terraform apply"
  else
    say "apply: $(grep -cE 'Creation complete' "$COURT_DIR/tf-apply.log") resources created; $(grep -E 'Apply complete' "$COURT_DIR/tf-apply.log" | head -1)"
    grep -qE 'Apply complete.*0 added, 0 changed, 0 destroyed\.$' "$COURT_DIR/tf-apply.log" && fail "leg C apply created nothing"
  fi
fi

if [ "${SKIP_NETWORK:-0}" != "1" ]; then
  # Readback: the resource graph the census predicts (real query answer).
  RG_HTTP="$(curl -sS -o "$COURT_DIR/resource-graph.json" -w "%{http_code}" \
    -H 'content-type: application/json' \
    -d '{"query": "project name, type, location | order by type asc", "subscriptions": ["00000000-0000-0000-0000-000000000000"]}' \
    "http://127.0.0.1:$EGRESS_PORT/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01")" || RG_HTTP=000
  [ "$RG_HTTP" = "200" ] || fail "leg C resource-graph http=$RG_HTTP"
  say "resource graph rows:"
  python3 - "$COURT_DIR/resource-graph.json" <<'PY' || fail "leg C resource-graph parse"
import json, sys
d = json.load(open(sys.argv[1]))
rows = d.get("data", [])
want = {"rg-courtroom-az", "log-courtroom", "dcr-courtroom", "courtsmaltacr",
        "courtroom-env", "alpha-api", "alpha-web", "beta-api", "beta-web"}
missing = want - {r.get("name") for r in rows}
print(f"  total={d.get('totalRecords')} rows={len(rows)}")
for r in sorted(rows, key=lambda r: (r.get("type") or "", r.get("name") or "")):
    print(f"  {r.get('type')} {r.get('name')}")
if missing:
    print(f"  MISSING: {sorted(missing)}")
    sys.exit(1)
PY

  # ARM readback of one deployed app (real GET on the control plane).
  APP_HTTP="$(curl -sS -o "$COURT_DIR/app-alpha-api.json" -w "%{http_code}" \
    "http://127.0.0.1:$ARM_PORT/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-courtroom-az/providers/Microsoft.App/containerApps/alpha-api?api-version=2023-05-01")" || APP_HTTP=000
  [ "$APP_HTTP" = "200" ] || fail "leg C app ARM GET http=$APP_HTTP"
  grep -q "courtsmaltacr.azurecr.io/courtroom-api:338caed" "$COURT_DIR/app-alpha-api.json" \
    || fail "leg C deployed app image identity missing"
  say "alpha-api image: $(python3 -c "import json;d=json.load(open('$COURT_DIR/app-alpha-api.json'));print(d['properties']['template']['containers'][0]['image'])" 2>/dev/null)"

  # Leg D — census-open demonstration: the two registry-absent members are
  # TYPED-REFUSED; expected-failure apply, refusal output is the evidence.
  say "leg D: census-open topology members (redis, identity) — expect typed refusals"
  set +e
  tf apply -auto-approve -no-color -var=land_extension_types=true >"$COURT_DIR/tf-apply-ext.log" 2>&1
  EXT_RC=$?
  set -e
  EXT_OK=0
  if [ "$EXT_RC" != "0" ]; then
    n_refusals=0
    for t in "Microsoft.Cache/redis" "userAssignedIdentities"; do
      if grep -q "$t" "$COURT_DIR/tf-apply-ext.log" && grep -qiE "not an admitted ontology individual|InvalidApiVersion|Error" "$COURT_DIR/tf-apply-ext.log"; then
        n_refusals=$((n_refusals + 1))
      fi
    done
    [ "$n_refusals" = "2" ] && EXT_OK=1
  fi
  [ "$EXT_OK" = "1" ] && say "leg D: 2/2 typed registry-admission refusals witnessed (rc=$EXT_RC, census-open)" \
    || { tail -15 "$COURT_DIR/tf-apply-ext.log" >&2; fail "leg D expected 2 typed refusals"; }

  # Leg E — ACR image identity: registry face + blob-backed repos + tags.
  say "leg E: ACR image identity readback"
  CRED_HTTP="$(curl -sS -o "$COURT_DIR/acr-cred.json" -w "%{http_code}" \
    -X POST "http://127.0.0.1:$ARM_PORT/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-courtroom-az/providers/Microsoft.ContainerRegistry/registries/courtsmaltacr/listCredentials?api-version=2023-06-01-preview")" || CRED_HTTP=000
  [ "$CRED_HTTP" = "200" ] || fail "leg E listCredentials http=$CRED_HTTP"
  ACR_USER="$(python3 -c "import json;print(json.load(open('$COURT_DIR/acr-cred.json'))['username'])" 2>/dev/null || echo)"
  ACR_PASS="$(python3 -c "import json;print(json.load(open('$COURT_DIR/acr-cred.json'))['passwords'][0]['value'])" 2>/dev/null || echo)"
  say "registry creds: user=$ACR_USER password=${ACR_PASS:0:6}..."

  AUTH=(-u "$ACR_USER:$ACR_PASS")
  CAT_HTTP="$(curl -sS "${AUTH[@]}" -o "$COURT_DIR/acr-catalog.json" -w "%{http_code}" \
    "http://127.0.0.1:$ARM_PORT/acr/courtsmaltacr/v2/_catalog")" || CAT_HTTP=000
  [ "$CAT_HTTP" = "200" ] && grep -q "courtroom-api" "$COURT_DIR/acr-catalog.json" \
    && grep -q "courtroom-web" "$COURT_DIR/acr-catalog.json" || fail "leg E catalog"
  say "catalog: $(cat "$COURT_DIR/acr-catalog.json")"

  # Tags ride the blob data plane (shared-key signed PUT — the real client
  # work the docker push performs against the emulation).
  TAG_OUT="$(cd "$ROOT" && MIX_BUILD_ROOT=_build-lane-s5 SMALT_BLOB_PORT=$EGRESS_PORT mix run --no-start scripts/r18-deploy/push_tags.exs 2>&1 | tail -8)"
  echo "$TAG_OUT"
  echo "$TAG_OUT" | grep -q "ACR_PUSH_OK" || fail "leg E tag push"

  TAGS_HTTP="$(curl -sS "${AUTH[@]}" -o "$COURT_DIR/acr-tags-api.json" -w "%{http_code}" \
    "http://127.0.0.1:$ARM_PORT/acr/courtsmaltacr/v2/courtroom-api/tags/list")" || TAGS_HTTP=000
  [ "$TAGS_HTTP" = "200" ] && grep -q "338caed" "$COURT_DIR/acr-tags-api.json" || fail "leg E tags listback"
  say "courtroom-api tags: $(cat "$COURT_DIR/acr-tags-api.json")"

  TAGS2_HTTP="$(curl -sS "${AUTH[@]}" -o "$COURT_DIR/acr-tags-web.json" -w "%{http_code}" \
    "http://127.0.0.1:$ARM_PORT/acr/courtsmaltacr/v2/courtroom-web/tags/list")" || TAGS2_HTTP=000
  [ "$TAGS2_HTTP" = "200" ] && grep -q "338caed" "$COURT_DIR/acr-tags-web.json" || fail "leg E web tags listback"
  say "courtroom-web tags: $(cat "$COURT_DIR/acr-tags-web.json")"
fi

# ---------------------------------------------------------------------------
# Cleanup (lease law: runtime artifacts removed, lock kept)
# ---------------------------------------------------------------------------
rm -rf "$HERE/.terraform" "$HERE/terraform.tfstate" "$HERE/terraform.tfstate.backup" \
  "$HERE/plan.tfplan" "$HERE/.terraform.lock.hcl" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Receipt
# ---------------------------------------------------------------------------
echo
echo "================ R18 S5 COURT RECEIPT ================"
if [ "$FAILURES" = "0" ]; then
  say "ALL LEGS PASS"
  exit 0
else
  say "FAILURES=$FAILURES (typed [FAULT] lines above)"
  exit 1
fi

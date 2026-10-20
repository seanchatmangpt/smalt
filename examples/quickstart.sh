#!/usr/bin/env bash
# examples/quickstart.sh — tour every smalt plane over real wire surfaces.
#
# Boots (or reuses) a lane-private substrate (block `c50`, anonymous
# auth), exercises control/data/identity planes over real HTTP, and tears
# down unless SMALT_KEEP=1.
#
# Exit contract: 0 all steps green / nonzero at the first failing step.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BLOCK="${SMALT_BLOCK:-c50}"
ARM="${SMALT_ARM:-}"
EGRESS="${SMALT_EGRESS:-}"
MCP="${SMALT_MCP:-}"
API="2022-09-01"

step() { printf '\n== %s ==\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

own="0"
cleanup() {
  if [ "$own" = "1" ]; then
    "$REPO/scripts/substrate-ctl" down --block "$BLOCK" --mode owner >/dev/null 2>&1 \
      || "$REPO/scripts/substrate-ctl" down --block "$BLOCK" --mode sweep >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# 0. Reuse-else-boot a lane-private substrate. Lane blocks listen on
#    per-block ephemeral ports (role order amqp eh arm egress tls mcp);
#    the boot receipt carries the map. SMALT_ARM/SMALT_EGRESS/SMALT_MCP
#    override and skip booting.
if [ -z "${SMALT_ARM:-}${SMALT_EGRESS:-}" ]; then
  echo "booting substrate (block=$BLOCK, anonymous auth)..."
  receipt=$("$REPO/scripts/substrate-ctl" up --block "$BLOCK" --auth anonymous) \
    || fail "substrate-ctl up"
  echo "$receipt"
  own="1"
  ports=$(printf '%s' "$receipt" | python3 -c 'import json,sys;print(*json.load(sys.stdin)["ports"])')
  read -r _p_amqp _p_eh ARM EGRESS _p_tls MCP <<<"$ports"
  ARM="http://127.0.0.1:${ARM}"; EGRESS="http://127.0.0.1:${EGRESS}"; MCP="http://127.0.0.1:${MCP}"
  echo "arm=$ARM egress=$EGRESS mcp=$MCP"
fi

curl_json() { # METHOD URL [DATA]
  local m="$1" u="$2" d="${3:-}"
  if [ -n "$d" ]; then
    curl -sS -X "$m" -H "Content-Type: application/json" -d "$d" "$u"
  else
    curl -sS -X "$m" "$u"
  fi
}
expect_contains() { # LABEL HAYSTACK NEEDLE
  case "$2" in *"$3"*) echo "ok: $1" ;; *) fail "$1 — missing '$3' in: ${2:0:300}" ;; esac
}

# 1. Control plane: bootstrap/discovery.
step "1. control plane: GET /metadata/endpoints"
md=$(curl_json GET "$ARM/metadata/endpoints") || fail "curl metadata"
expect_contains "metadata doc" "$md" '"resourceManager"'

# 2. STS token mint (client_credentials).
step "2. STS token mint"
tok=$(curl -sS -X POST "$ARM/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=examples&client_secret=examples-secret" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])') \
  || fail "STS mint"
[ -n "$tok" ] || fail "empty STS token"
echo "ok: minted token (len=${#tok})"

# 3. ARM: subscriptions.
step "3. ARM subscriptions"
subs=$(curl_json GET "$ARM/subscriptions?api-version=$API") || fail "subscriptions"
expect_contains "subscriptions list" "$subs" '"subscriptionId"'

# 4. ARM: resource-group lifecycle.
step "4. resource-group lifecycle"
rg="examples-rg-$$"
rg_url="$ARM/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/$rg?api-version=$API"
put=$(curl_json PUT "$rg_url" '{"location":"westus2"}') || fail "rg put"
expect_contains "rg create" "$put" '"provisioningState"'

step "5. rg list"
lst=$(curl_json GET "$ARM/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups?api-version=$API") || fail "rg list"
expect_contains "rg list" "$lst" '"provisioningState"'
case "$lst" in *"$rg"*) echo "ok: created rg appears in list" ;; *) fail "created rg missing from list" ;; esac

step "6. rg delete + verify-gone"
curl_json DELETE "$rg_url" >/dev/null || fail "rg delete"
if curl_json GET "$rg_url" | grep -q provisioningState; then
  fail "rg still present after delete"
else
  echo "ok: rg deleted"
fi

# 7. Data plane: Cosmos DB create + list (x-ms-version required).
step "7. Cosmos DB create + list"
db="examplesdb"
curl -sS -X POST -H "x-ms-version: 2020-07-07" -H "Content-Type: application/json" \
  -d "{\"id\":\"$db\"}" "$EGRESS/dbs" >/dev/null || fail "db create"
curl -sS -H "x-ms-version: 2020-07-07" "$EGRESS/dbs" | grep -q "\"id\":\"$db\"" || fail "db not in list"
echo "ok: cosmos db create+list"

# 8. Blob: container create, blob put/get round-trip.
step "8. blob round-trip"
acct="examplesacct$$"
container="examples"
curl -sS -o /dev/null -X PUT -H "x-ms-version: 2020-07-07" \
  "$EGRESS/$acct/$container?restype=container" || fail "container create"
url="$EGRESS/$acct/$container/example-blob"
body="hello from smalt examples at $(date -u +%FT%TZ)"
curl -sS -o /dev/null -X PUT -H "x-ms-version: 2020-07-07" -H "x-ms-blob-type: BlockBlob" \
  --data-binary "$body" "$url" || fail "blob put"
got=$(curl -sS -H "x-ms-version: 2020-07-07" "$url") || fail "blob get"
[ "$got" = "$body" ] >/dev/null || fail "blob round-trip mismatch: '$got'"
echo "ok: blob round-trip"

# 9. Queue plane: create queue, send, receive.
step "9. queue send/receive"
qacct="examplesq$$"
qurl="$EGRESS/$qacct/examplequeue"
curl -sS -o /dev/null -X PUT -H "x-ms-version: 2020-07-07" "$qurl?restype=queue" || fail "queue create"
curl -sS -o /dev/null -X POST -H "x-ms-version: 2020-07-07" \
  --data-binary '<QueueMessage><MessageText>hi</MessageText></QueueMessage>' \
  "$qurl/messages?visibilitytimeout=1" || fail "queue send"
# Receive is GET (Azure parity): dequeues up to numofmessages (makes them
# invisible for visibilitytimeout).
msg=$(curl -sS -X GET -H "x-ms-version: 2020-07-07" "$qurl/messages?numofmessages=1") \
  || fail "queue receive"
case "$msg" in *"<QueueMessage>"*) echo "ok: queue send/receive" ;; *) fail "queue receive: $msg" ;; esac

# 10. MCP surface.
step "10. MCP tools/list"
mcp=$(curl_json POST "$MCP" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}') || fail "mcp tools/list"
case "$mcp" in
  *'"tools"'*) echo "ok: mcp tools/list" ;;
  *) fail "mcp: $mcp" ;;
esac

echo
echo "GREEN: all quickstart steps passed (block=$BLOCK)"

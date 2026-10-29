#!/usr/bin/env bash
# scripts/emulators.sh — fail-closed emulator manager for differential lanes
# (W30-N, b90/b13 private-port precedent).
#
# Manages three third-party emulators in ISOLATED private port blocks,
# never touching shared-substrate ports (9443/9444/5672/5673/8443/9545):
#   - Azurite     blob/queue/table 10100-10102
#   - SB emulator service bus + mgmt 5300 (shifted +k to 5310..5319 on collision)
#   - Cosmos vNext 8080
#
# Subcommands: start|stop|status
# Fail-closed: Docker absent => typed exit EMULATORS-DOCKER-ABSENT (never
# partial boot), and start refuses if ANY emulator port is already held.
#
# State: /tmp/smalt-emulators-state/ (pid files, logs, resolved ports).
set -uo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || dirname "$(cd "$(dirname "$0")" && pwd)")"
STATE=/tmp/smalt-emulators-state
NET=smalt-emulators
# Azurite private block (b90 precedent: 10100-10102)
AZ_BLOB=10100; AZ_QUEUE=10101; AZ_TABLE=10102
# Cosmos vNext
COSMOS_PORT=8080
# SB emulator base; shifts up in SB_MGMT_SCAN on collision
SB_BASE=5300
SB_MGMT_SCAN="5300 5301 5302 5303 5304 5305"
SB_SQL_SCAN="14330 14331 14332"
IMG_SB="mcr.microsoft.com/azure-messaging/servicebus-emulator:latest"
IMG_SQL="mcr.microsoft.com/azure-sql-edge:latest"
IMG_COSMOS="mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview"

mkdir -p "$STATE"

fail() { echo "EMULATORS-ERROR: $*" >&2; exit 1; }
typed_absent() { echo "EMULATORS-DOCKER-ABSENT: docker CLI not found; emulator lanes fail closed, no partial boot" >&2; exit 3; }

require_docker() {
  command -v docker >/dev/null 2>&1 || typed_absent
  docker info >/dev/null 2>&1 || {
    echo "EMULATORS-ERROR: docker CLI present but daemon unreachable" >&2
    exit 4
  }
}

port_held() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

ctr_up() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

resolve_sb_ports() {
  local m s
  for m in $SB_MGMT_SCAN; do port_held "$m" || break; done
  port_held "$m" && fail "no free SB mgmt port in [$SB_MGMT_SCAN]"
  for s in $SB_SQL_SCAN; do port_held "$s" || break; done
  port_held "$s" && fail "no free SB sql port in [$SB_SQL_SCAN]"
  SB_MGMT="$m"; SB_SQL="$s"
}

sb_config() {
  mkdir -p "$STATE/sb"
  cat > "$STATE/sb/Config.json" <<'JSON'
{
  "UserConfig": {
    "Namespaces": [
      {
        "Name": "sbemulator",
        "Queues": [ { "Name": "queue.1", "Properties": { "DeadLetteringOnMessageExpiration": false, "DefaultMessageTimeToLive": "PT1H", "LockDuration": "PT1M", "MaxDeliveryCount": 10, "RequiresSession": false } } ],
        "Topics": [ { "Name": "topic.1", "Properties": { "DefaultMessageTimeToLive": "PT1H" }, "Subscriptions": [ { "Name": "sub.1", "Properties": { "DeadLetteringOnMessageExpiration": false, "DefaultMessageTimeToLive": "PT1H", "LockDuration": "PT1M", "MaxDeliveryCount": 10 } } ] } ]
      }
    ],
    "Logging": { "Type": "File" }
  }
}
JSON
}

do_start() {
  require_docker
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

  # Fail closed BEFORE any boot if any target port is held.
  local held=""
  for p in "$AZ_BLOB" "$AZ_QUEUE" "$AZ_TABLE" "$COSMOS_PORT"; do
    port_held "$p" && held="$held $p"
  done
  # SB ports resolved first so collisions are detected pre-boot too.
  resolve_sb_ports
  for p in "$SB_MGMT" "$SB_SQL"; do port_held "$p" && held="$held $p"; done
  [ -n "$held" ] && fail "refusing partial boot: port(s)$held already held"

  # --- Azurite (isolated private block) ---
  if ctr_up smalt-azurite; then
    echo "azurite: already up (blob=$AZ_BLOB queue=$AZ_QUEUE table=$AZ_TABLE)"
  else
    docker rm -f smalt-azurite >/dev/null 2>&1 || true
    docker run -d --name smalt-azurite --network "$NET" \
      -p "127.0.0.1:$AZ_BLOB:10000" -p "127.0.0.1:$AZ_QUEUE:10001" -p "127.0.0.1:$AZ_TABLE:10002" \
      mcr.microsoft.com/azure-storage/azurite \
      azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0 \
      --location /data > "$STATE/azurite.log" 2>&1 || fail "azurite container failed to start (see $STATE/azurite.log)"
    echo "azurite: started (blob=$AZ_BLOB queue=$AZ_QUEUE table=$AZ_TABLE)"
  fi

  # --- SB emulator (+ sql-edge backing store) ---
  if ctr_up smalt-sb-emulator; then
    echo "sb-emulator: already up (mgmt=$SB_MGMT sql=$SB_SQL)"
  else
    docker rm -f smalt-sb-emulator smalt-sb-sql >/dev/null 2>&1 || true
    sb_config
    docker run -d --name smalt-sb-sql --network "$NET" \
      -e "MSSQL_SA_PASSWORD=${SB_SQL_PASSWORD:-SA_PASSWORD_1PLACEHOLDER}" \
      -e ACCEPT_EULA=Y -e MSSQL_PID=Developer \
      -p "127.0.0.1:$SB_SQL:1433" "$IMG_SQL" > "$STATE/sb-sql.log" 2>&1 \
      || fail "sb sql-edge failed to start (see $STATE/sb-sql.log)"
    docker run -d --name smalt-sb-emulator --network "$NET" \
      -p "127.0.0.1:$SB_MGMT:5300" \
      -e "SQL_SERVER=smalt-sb-sql" \
      -e "MSSQL_SA_PASSWORD=${SB_SQL_PASSWORD:-SA_PASSWORD_1PLACEHOLDER}" \
      -e ACCEPT_EULA=Y -e "SQL_WAIT_FOR_INSTANCES=1" \
      -v "$STATE/sb/Config.json":/ServiceBusEmulator/Config.json:ro \
      "$IMG_SB" > "$STATE/sb-emulator.log" 2>&1 \
      || fail "sb-emulator container failed to start (see $STATE/sb-emulator.log)"
    echo "sb-emulator: started (mgmt=$SB_MGMT sql=$SB_SQL)"
  fi

  # --- Cosmos vNext ---
  if ctr_up smalt-cosmos-vnext; then
    echo "cosmos-vnext: already up (port=$COSMOS_PORT)"
  else
    docker rm -f smalt-cosmos-vnext >/dev/null 2>&1 || true
    docker run -d --name smalt-cosmos-vnext --network "$NET" \
      -p "127.0.0.1:$COSMOS_PORT:8080" "$IMG_COSMOS" \
      > "$STATE/cosmos.log" 2>&1 || fail "cosmos vnext failed to start (see $STATE/cosmos.log)"
    echo "cosmos-vnext: started (port=$COSMOS_PORT)"
  fi

  echo "$SB_MGMT" > "$STATE/sb-mgmt.port"; echo "$SB_SQL" > "$STATE/sb-sql.port"
  echo "EMULATORS-STARTED"
}

do_stop() {
  require_docker
  for c in smalt-sb-emulator smalt-sb-sql smalt-cosmos-vnext smalt-azurite; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  # Port sweep: private block only — never shared-substrate ports.
  local p
  for p in "$AZ_BLOB" "$AZ_QUEUE" "$AZ_TABLE" "$COSMOS_PORT" $SB_MGMT_SCAN $SB_SQL_SCAN; do
    local holders
    holders=$(lsof -nP -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | sort -u)
    [ -n "$holders" ] && kill $holders 2>/dev/null
  done
  echo "EMULATORS-STOPPED"
}

do_status() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "EMULATORS-DOCKER-ABSENT: docker CLI not found"
    echo "azurite: absent"; echo "sb-emulator: absent"; echo "cosmos-vnext: absent"
    exit 3
  fi
  local line pid
  for pair in "azurite:smalt-azurite:$AZ_BLOB,$AZ_QUEUE,$AZ_TABLE" \
              "sb-emulator:smalt-sb-emulator:$SB_BASE" \
              "cosmos-vnext:smalt-cosmos-vnext:$COSMOS_PORT"; do
    name=${pair%%:*}; rest=${pair#*:}; ctr=${rest%%:*}
    if ctr_up "$ctr"; then state=up; else state=down; fi
    echo "$name: $state ($ctr; ports ${rest#*:})"
  done
  docker ps --filter "name=smalt-" --format '{{.Names}} {{.Status}} {{.Ports}}'
  echo "EMULATORS-STATUS-OK"
}

case "${1:-}" in
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac

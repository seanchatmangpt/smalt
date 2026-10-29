#!/usr/bin/env bash
# APEX-4 telemetry fan-out bench lane — private-block substrate on 39950-39955.
set -uo pipefail
ROOT=/Users/sac/smalt
PD=/Users/sac/smalt/popcorn_demo
WORK=$(mktemp -d /tmp/apex4.XXXXXX)
SUB_LOG="$WORK/substrate.log"
PID_FILE="$WORK/sub.pid"
ARM=39950; ATLS=39951; EG=39952; AMQP=39953; EHUB=39954; MCP=39955
KEY="apex4-lane-key-$(openssl rand -hex 16)"
LANE_PORTS="$ARM $ATLS $EG $AMQP $EHUB $MCP"

port_holders() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u; }
cleanup() {
  local p b pid
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  for _ in $(seq 1 30); do
    h=0; for p in $LANE_PORTS; do [ -n "$(port_holders "$p")" ] && h=1; done
    [ "$h" = 0 ] && break; sleep 0.5
  done
  for p in $LANE_PORTS; do
    for b in $(port_holders "$p"); do kill -9 "$b" 2>/dev/null || true; done
  done
  cp "$SUB_LOG" "/Users/sac/smalt/popcorn_demo/bench/out/apex4-substrate-$(date +%H%M%S).log" 2>/dev/null || true; rm -rf "$WORK"
}
mkdir -p /Users/sac/smalt/popcorn_demo/bench/out
trap cleanup EXIT

for p in $LANE_PORTS; do
  if [ -n "$(port_holders "$p")" ]; then
    echo "APEX4 BLOCKED: port $p held"; exit 2
  fi
done

EVAL="Application.put_env(:smalt, :arm_port, $ARM); \
Application.put_env(:smalt, :egress_port, $EG); \
Application.put_env(:smalt, :amqp_port, $AMQP); \
Application.put_env(:smalt, :event_hubs_port, $EHUB, persistent: true); \
Application.put_env(:smalt, :mcp_port, $MCP); \
Application.put_env(:smalt, :arm_tls_port, $ATLS); \
Application.put_env(:smalt, :sb_endpoint, \"sb://127.0.0.1:$AMQP\"); \
Application.put_env(:smalt, :sb_shared_key, \"$KEY\"); \
{:ok, _} = Application.ensure_all_started(:smalt); \
Process.sleep(:infinity)"

(
  cd "$ROOT" || exit 1
  exec 9>&-
  exec env MIX_ENV=test \
    MIX_BUILD_ROOT=_build-laneapex4 \
    SMALT_SB_SHARED_KEY="$KEY" \
    mix run --no-start -e "$EVAL" --no-halt
) >"$SUB_LOG" 2>&1 &
SUB_PID=$!
echo "$SUB_PID" > "$PID_FILE"

up=0
for _ in $(seq 1 180); do
  lsof -nP -iTCP:"$AMQP" -sTCP:LISTEN >/dev/null 2>&1 && { up=1; break; }
  kill -0 "$SUB_PID" 2>/dev/null || { echo "APEX4 substrate died"; tail -30 "$SUB_LOG"; exit 2; }
  sleep 1
done
[ "$up" = 1 ] || { echo "APEX4 substrate never bound $AMQP"; tail -30 "$SUB_LOG"; exit 2; }
echo "[apex4] substrate up: arm=$ARM amqp=$AMQP pid=$SUB_PID"

cd "$PD"
export SMALT_SB_SHARED_KEY="$KEY" APEX_ARM_PORT=$ARM APEX_SB_AMQP_PORT=$AMQP APEX_DEBUG=
MIX_BUILD_ROOT=_build-apex4 timeout 300 asdf exec mix run --no-start -e '
case PopcornDemo.Apex4Telem.run() do
  {:ok, s} ->
    row = %{
      lane: "apex4-telemetry", surface: "sb-topic-telemetry", op: "emit_collect",
      n: s.n, events_per_sec: s.collect_eps, publish_eps: s.publish_eps,
      collect_lag_p50_ms: s.lag_p50_ms, collect_lag_p95_ms: s.lag_p95_ms, collect_lag_max_ms: s.lag_max_ms,
      publish_ms: s.publish_ms, drain_ms: s.drain_ms, loss: s.loss, errors: s.loss,
      topic: s.topic,
      machine: "darwin-" <> (:erlang.system_info(:system_architecture) |> Kernel.to_string() |> String.split() |> List.first())
    }
    File.mkdir_p!("bench")
    File.write!("bench/apex4-telemetry.jsonl", Jason.encode!(row) <> "\\n", [:append])
    IO.puts(PopcornDemo.Apex4Telem.format({:ok, s}))
    IO.puts(Jason.encode!(row))
  other ->
    IO.puts("RESULT: " <> inspect(other, limit: 8))
    System.halt(3)
end'
RC=$?
echo "[apex4] bench exit=$RC"
exit $RC

#!/usr/bin/env zsh
# r3_amqp — adversarial AMQP 1.0 wire redteam against a live smalt broker.
#
# Owns the substrate lifecycle:
#   1. mints a hostile-frame corpus CLIENT-SIDE with Smalt.Amqp.FrameCodec /
#      PrimitiveCodec (the pinned wire codecs) into /tmp/r3_amqp_corpus.json;
#   2. boots the broker (MIX_ENV=test) on 5672/5673;
#   3. runs node --test on the adversary;
#   4. post-checks: connection-supervisor leak count, beam memory, crash dumps.
#
# Exit codes: 0 pass / 1 findings or test failure / 2 substrate never came up.
set -u
cd "$(dirname "$0")/../../.."

# Shifted substrate ports (pattern from r2_state): a live smalt instance or a
# sibling lane's substrate may hold the defaults.
SB_PORT=${SMALT_SB_PORT:-45672}
EH_PORT=${SMALT_EH_PORT:-45673}
ARM_PORT=49443
EGRESS_PORT=48443
LOG=/tmp/smalt-r3-amqp-substrate.log
CORPUS=/tmp/r3_amqp_corpus.json
GEN=/tmp/r3_amqp_corpus_gen.exs

try_connect() {
  node -e '
    const net = require("net");
    const s = net.connect({ host: "127.0.0.1", port: Number(process.argv[1]), timeout: 1500 });
    s.once("connect", () => { s.destroy(); process.exit(0); });
    s.once("timeout", () => { s.destroy(); process.exit(1); });
    s.once("error", () => process.exit(1));
  ' "$1"
}

for p in $SB_PORT $EH_PORT; do
  if try_connect $p; then
    echo "port $p occupied — kill the running broker first (lsof -ti tcp:$p | xargs kill)" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Step 1: client-side corpus mint (Smalt.Amqp.FrameCodec + PrimitiveCodec)
# ---------------------------------------------------------------------------
cat > "$GEN" <<'EXS'
alias Smalt.Amqp.FrameCodec

hex = fn iodata -> IO.iodata_to_binary(iodata) |> Base.encode16() end
f = fn type, ch, perf -> hex.(FrameCodec.encode_frame(type, ch, perf)) end

corpus = %{
  "amqp_header" => Base.encode16("AMQP\x00\x01\x00\x00"),
  "sasl_header" => Base.encode16("AMQP\x03\x01\x00\x00"),
  "open" => f.(:amqp, 0, {:open, %{container_id: "r3-corpus", hostname: "sb://localhost", max_frame_size: 1_048_576, channel_max: 65_535}}),
  "begin" => f.(:amqp, 0, {:begin, %{remote_channel: 0, next_outgoing_id: 1, incoming_window: 1000, outgoing_window: 1000, handle_max: 1000}}),
  "begin_remote_channel_999" => f.(:amqp, 0, {:begin, %{remote_channel: 999, next_outgoing_id: 1, incoming_window: 1000, outgoing_window: 1000}}),
  "attach_cbs_snd" => f.(:amqp, 0, {:attach, %{name: "cbs-snd", handle: 0, role: false, source: nil, target: %{address: "$cbs"}}}),
  "attach_cbs_rcv" => f.(:amqp, 0, {:attach, %{name: "cbs-rcv", handle: 1, role: true, source: %{address: "$cbs"}, target: nil}}),
  "attach_mgmt_snd" => f.(:amqp, 0, {:attach, %{name: "mgmt-snd", handle: 2, role: false, source: nil, target: %{address: "$management"}}}),
  "attach_mgmt_rcv" => f.(:amqp, 0, {:attach, %{name: "mgmt-rcv", handle: 3, role: true, source: %{address: "$management"}, target: nil}}),
  "transfer_cbs_puttoken" => f.(:amqp, 0, {:transfer, %{handle: 0, delivery_id: 1, delivery_tag: "t", message_format: 0, settled: true, more: false},
    {:sections, [
      {:properties, %{message_id: "pt-1", reply_to: "cbs-rcv", correlation_id: "c-pt-1"}},
      {:application_properties, %{"operation" => "put-token", "name" => "adv-corpus", "type" => "servicebus.cc:none", "expiration" => 4102444800000}},
      {:body_amqp_value, "TOKEN"}
    ]}}),
  "transfer_cbs_deletetoken" => f.(:amqp, 0, {:transfer, %{handle: 0, delivery_id: 2, delivery_tag: "t", message_format: 0, settled: true, more: false},
    {:sections, [
      {:properties, %{message_id: "dt-1", reply_to: "cbs-rcv", correlation_id: "c-dt-1"}},
      {:application_properties, %{"operation" => "delete-token", "name" => "adv-corpus"}},
      {:body_amqp_value, %{"expiration" => 0}}
    ]}}),
  "transfer_mgmt_renewlock" => f.(:amqp, 0, {:transfer, %{handle: 2, delivery_id: 3, delivery_tag: "m", message_format: 0, settled: true, more: false},
    {:sections, [
      {:properties, %{message_id: "m-1", reply_to: "mgmt-rcv", correlation_id: "c-m-1"}},
      {:application_properties, %{"operation" => "com.microsoft:renew-lock"}},
      {:body_amqp_value, %{"lock-tokens" => [{:uuid, :binary.copy(<<1>>, 16)}]}}
    ]}}),
  "transfer_mgmt_peek0" => f.(:amqp, 0, {:transfer, %{handle: 2, delivery_id: 4, delivery_tag: "m", message_format: 0, settled: true, more: false},
    {:sections, [
      {:properties, %{message_id: "m-2", reply_to: "mgmt-rcv", correlation_id: "c-m-2"}},
      {:application_properties, %{"operation" => "com.microsoft:peek-message"}},
      {:body_amqp_value, %{"queue" => "adv-corpus", "from-sequence-number" => 0}}
    ]}}),
  "transfer_queue_msg" => f.(:amqp, 0, {:transfer, %{handle: 4, delivery_id: 5, delivery_tag: "q", message_format: 0, settled: true, more: false},
    {:sections, [{:body_data, "corpus-payload"}]}}),
  "attach_queue_snd" => f.(:amqp, 0, {:attach, %{name: "q-snd", handle: 4, role: false, source: nil, target: %{address: "adv-corpus"}}}),
  "disposition_accepted" => f.(:amqp, 0, {:disposition, %{role: true, first: 1, settled: true, state: :accepted}}),
  "flow_credit_rcv" => f.(:amqp, 0, {:flow, %{next_incoming_id: 1, incoming_window: 10_000, next_outgoing_id: 1, outgoing_window: 10_000, handle: 5, delivery_count: 0, link_credit: 10}}),
  "sasl_init_anon" => f.(:sasl, 0, {:sasl_init, %{mechanism: {:symbol, "ANONYMOUS"}}}),
  "sasl_init_plain" => f.(:sasl, 0, {:sasl_init, %{mechanism: {:symbol, "PLAIN"}, initial_response: "a"}}),
  "end" => f.(:amqp, 0, {:end, %{error: nil}}),
  "close" => f.(:amqp, 0, {:close, %{error: nil}})
}

File.write!("/tmp/r3_amqp_corpus.json", Jason.encode!(corpus))
IO.puts("corpus minted: #{map_size(corpus)} frames")
EXS

echo "== minting FrameCodec corpus =="
MIX_ENV=test mix run --no-start "$GEN" || { echo "corpus mint failed" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Step 2: boot the broker on OUR shifted ports
# ---------------------------------------------------------------------------
BOOT_EVAL='Application.put_env(:smalt, :amqp_port, '"$SB_PORT"'); Application.put_env(:smalt, :event_hubs_port, '"$EH_PORT"'); Application.put_env(:smalt, :arm_port, '"$ARM_PORT"'); Application.put_env(:smalt, :arm_tls_port, 49444); Application.put_env(:smalt, :egress_port, '"$EGRESS_PORT"'); {:ok, _} = Application.ensure_all_started(:smalt); IO.puts("r3 broker ready"); Process.sleep(:infinity)'
boot_broker() {
  MIX_ENV=test mix run --no-start --eval "$BOOT_EVAL" >> "$LOG" 2>&1 &
  SUB_PID=$!
}

: > "$LOG"
boot_broker
trap 'kill -9 $SUB_PID $WATCHDOG_PID 2>/dev/null; wait $SUB_PID $WATCHDOG_PID 2>/dev/null' EXIT INT TERM

# Watchdog: sibling lanes on the shared checkout pkill "mix run" substrates
# mid-flight; keep OUR broker up for the duration of the adversary run.
(
  while :; do
    sleep 10
    try_connect $SB_PORT || { echo "[wd] broker down — rebooting" >> "$LOG"; boot_broker; }
  done
) &
WATCHDOG_PID=$!

up=0
for i in $(seq 1 120); do
  if try_connect $SB_PORT && try_connect $EH_PORT; then up=1; break; fi
  sleep 0.5
done
if [ "$up" -ne 1 ]; then
  echo "broker did not come up; log: $LOG" >&2
  tail -40 "$LOG" >&2
  exit 2
fi
echo "broker up (pid $SUB_PID) on $SB_PORT/$EH_PORT"

# ---------------------------------------------------------------------------
# Step 3: adversary
# ---------------------------------------------------------------------------
SMALT_SB_PORT=$SB_PORT SMALT_EH_PORT=$EH_PORT node --test test/redteam/r3_amqp/amqp_adversary.test.cjs
rc=$?

# ---------------------------------------------------------------------------
# Step 4: post-checks — connection leak count against the broker listener,
# plus crash-dump check (a fresh dump during the run is a crash receipt).
# ---------------------------------------------------------------------------
sleep 2
BEAM_PID=$(lsof -ti tcp:$SB_PORT -sTCP:LISTEN | head -1)
established=$(lsof -nP -iTCP:$SB_PORT 2>/dev/null | grep -c ESTABLISHED || true)
echo "POSTCHECK broker_pid=$BEAM_PID established_conns_on_sb=$established"
if [ -n "$BEAM_PID" ]; then
  echo "POSTCHECK rss_kb=$(ps -o rss= -p $BEAM_PID | tr -d ' ')"
fi
if ls erl_crash.dump* >/dev/null 2>&1; then
  newest=$(ls -t erl_crash.dump* | head -1)
  age_days=$(( ( $(date +%s) - $(stat -f %m "$newest") ) / 86400 ))
  echo "POSTCHECK newest_crash_dump=$newest age_days=$age_days (pre-existing if >0)"
fi

kill -9 $SUB_PID 2>/dev/null
for p in $SB_PORT $EH_PORT; do
  lsof -ti tcp:$p | xargs kill -9 2>/dev/null
done
wait $SUB_PID 2>/dev/null
trap - EXIT INT TERM
echo "substrate log: $LOG"
echo "results: /tmp/r3_amqp_results.json"
exit $rc

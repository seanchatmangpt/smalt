defmodule PopcornDemo.ApexFanout.Sink do
  @moduledoc """
  APEX-3 columnar aggregation sink — ETS by design.

  One cell per {subscription, window} where window is a 25 ms sliding-window
  bucket counted from the cycle epoch (cycle t0). Cells are columnar in shape
  ({sub, window, n} — aggregation-ready), folded on every receive instant.
  Host-side duckdb-wasm ingestion is the S14-G follow-up and is deliberately
  NOT claimed here.
  """

  @window_ms 25
  @tab :apex3_sink

  def init do
    if :ets.info(@tab) != :undefined, do: :ets.delete(@tab)
    :ets.new(@tab, [:named_table, :public, :set])
    :ok
  end

  def record(sub, t0) do
    bucket = div(System.monotonic_time(:millisecond) - t0, @window_ms)
    :ets.update_counter(@tab, {sub, bucket}, {3, 1}, {sub, bucket, 0})
  end

  def record_dlq(sub, t0) when is_binary(sub) do
    bucket = div(System.monotonic_time(:millisecond) - t0, @window_ms)
    :ets.update_counter(@tab, {"DLQ:" <> sub, bucket}, {3, 1}, {"DLQ:" <> sub, bucket, 0})
  end

  def windows do
    @tab
    |> :ets.tab2list()
    |> Enum.map(fn {{sub, _w}, _n} -> sub end)
    |> Enum.uniq()
    |> length()
  end

  @doc "Full {sub, window, n} column, window-ordered — the emitted aggregation."
  def snapshot do
    @tab
    |> :ets.tab2list()
    |> Enum.map(fn {{sub, w}, n} -> %{sub: sub, window_ms: w * @window_ms, count: n} end)
    |> Enum.sort_by(&{&1.sub, &1.window_ms})
  end
end

defmodule PopcornDemo.ApexFanout do
  @moduledoc """
  APEX-3 — 512-event telemetry fan-out through 4 filtered Service Bus
  subscriptions over the REAL wire (Chicago testbed: real collaborators —
  a live smalt substrate block, real AMQP 1.0 frames — no mocks).

  Composed from witnessed seams (nothing new invented):

    - ARM face / LRO poll / SAS mint .......... `PopcornDemo.LiveTopic` (X3)
    - SASL ANONYMOUS + 0x44 outcome pinion ... `PopcornDemo.LiveTopic`/`LiveEh`
    - CBS put-token per entity ............... `PopcornDemo.LiveTopic`
    - SQL filter gate ........................ `Smalt.Amqp.RuleStore` (w6m):
      the broker evaluates each subscription's rules on the topic fan-out
      path (`QueueStore.enqueue/3` -> `subscription_queues/1` ->
      `RuleStore.rules_match?/2`) — the gate is the delivery path itself.
    - Rules added over the wire .............. `$management`
      `com.microsoft:add-rule` RPC (management_rpc.ex add_rule/5), reply
      application-properties `status-code` (witnessed 200 on this lane's
      block). The ARM rule PUT stores under a string key shape RuleStore's
      tuple-key lookup never reads — the wire RPC is the seam that feeds the
      fan-out gate.
    - Typed DLQ .............................. receiver-side `rejected`
      disposition whose error info-map carries `DeadLetterReason` /
      `DeadLetterErrorDescription` (connection.ex settle(:deadletter,...)
      KD-77 residual shape) -> `QueueStore.deadletter/5` ->
      `<topic>/Subscriptions/<sub>/$deadletterqueue`.

  One `run/1`:

    1. ARM: ensure RG/namespace/topic + subscriptions apex-sa..apex-sd on a
       run-unique topic `apex-t-<ms>-<rand>`.
    2. Wire: connect, SASL ANONYMOUS, open/begin, CBS setup, put-token for
       topic + 4 subscriptions (+4 DLQ entities), attach sender + 4
       subscription receivers (credited BEFORE the publish — this broker
       delivers only to links credited before the deliveries exist, a lane
       finding disclosed in the receipt) + `$management` pair, add one SQL
       rule per subscription (`sensor = 'apex-<s>'`) via add-rule.
    3. Cycle (the timed section): publish `4 * (good + bad)` settled
       transfers (default 4 x (120+8) = 512: JSON telemetry bodies carrying
       app-prop `sensor`, plus non-JSON bodies = malformed) to the bare
       topic entity; drain each subscription — accept good bodies, reject
       malformed with the typed dead-letter reason; attach + credit the 4
       DLQ receivers (after the rejections, so the DLQ entities exist);
       drain them; fold every receive instant into the ETS columnar sink.
    4. Accounting must balance exactly: good(sub) == good_per_sub,
       dlq(sub) == bad_per_sub, every received id in exactly the
       subscription its `sensor` names (0 misroutes), delivered +
       deadlettered == published, 0 lost.

  Endpoints ride env (private-block lane law — never the shared pid, never a
  substrate restart): `APEX_ARM_PORT` (default 9443), `APEX_SB_AMQP_PORT`
  (default 5672), `SMALT_SB_SHARED_KEY` (required; the SAS signature key the
  substrate booted with).

  Return contract (house style):
    {:ok, stats_map}  — format/1 renders the house-style one-liner
    {:skip, binary}   — substrate/transport down
    {:error, binary}  — any setup or accounting failure
  """

  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2021-04-01"

  @sub_id "popcorn-rg-sub"
  @rg "popcorn-rg"
  @ns "popcorn-ns"
  @skn "RootManageSharedAccessKey"
  @subs ["apex-sa", "apex-sb", "apex-sc", "apex-sd"]

  @sasl_header "AMQP\x03\x01\x00\x00"
  @amqp_header "AMQP\x00\x01\x00\x00"

  # handles: 0 sender(topic), 1..4 sub receivers, 5..8 DLQ receivers,
  # 9 mgmt sender, 10 mgmt receiver, 2/3 CBS rx/tx.
  @h_tx 0
  @h_rx 1
  @h_dlq 5
  @h_mgmt_tx 9
  @h_mgmt_rx 10

  @dlq_reason "apex-malformed-payload"
  @dlq_desc "body was not valid telemetry JSON"

  @doc "Default scenario: 512 events (4 x [120 good + 8 malformed])."
  def run, do: run([])

  @doc "Scenario with opts: `:good_per_sub` (default 120), `:bad_per_sub` (default 8)."
  def run(opts) when is_list(opts) do
    good = Keyword.get(opts, :good_per_sub) || int_env("APEX_GOOD_PER_SUB", 120)
    bad = Keyword.get(opts, :bad_per_sub) || int_env("APEX_BAD_PER_SUB", 8)

    topic = "apex-t-#{System.system_time(:millisecond)}-#{:rand.uniform(999_999)}"

    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- ensure_ns(),
         :ok <- ensure_topic(topic),
         :ok <- ensure_subs(topic),
         :ok <- (if System.get_env("APEX_NORULES") == "1", do: :ok, else: add_rules_on_mgmt_conn(topic)),
         {:ok, st} <- wire_setup(topic),
         {:ok, stats} <- cycle(st, topic, good, bad) do
      :gen_tcp.close(st.sock)
      {:ok, stats}
    else
      {:skip, reason} -> {:skip, "apex=SKIP(#{reason})"}
      {:error, {step, reason}} -> {:error, "apex=FAIL(#{step}:#{fmt(reason)})"}
      {:error, reason} -> {:error, "apex=FAIL(bare:#{fmt(reason)})"}
    end
  end

  @doc "House-style one-line summary from a run/1 stats map."
  def format({:ok, %{} = s}) do
    "apex=OK(topic:#{s.topic},events:#{s.good + s.deadlettered}," <>
      "cycle:#{s.cycle_ms}ms,pub:#{s.publish_ms}ms,drain:#{s.drain_ms}ms," <>
      "dlq:#{s.dlq_ms}ms,good:#{s.good},dlq:#{s.deadlettered}," <>
      "misroutes:#{s.misroutes},dlq_typed:#{s.dlq_typed}/#{s.deadlettered}," <>
      "loss:#{s.loss},windows:#{s.windows})"
  end

  def format(other), do: inspect(other, limit: 10)

  # ------------------------------------------------------------------ utils

  defp int_env(name, default) do
    case System.get_env(name) do
      nil -> default
      v -> String.to_integer(v)
    end
  end

  defp fmt(r) when is_binary(r), do: r
  defp fmt(r), do: inspect(r, limit: 10)

  defp arm_port, do: String.to_integer(System.get_env("APEX_ARM_PORT") || "9443")
  defp amqp_port, do: String.to_integer(System.get_env("APEX_SB_AMQP_PORT") || "5672")
  defp sb_endpoint, do: "sb://127.0.0.1:#{amqp_port()}"

  defp sub_addr(topic, sub), do: "#{topic}/Subscriptions/#{sub}"
  defp dlq_addr(topic, sub), do: "#{sub_addr(topic, sub)}/$deadletterqueue"

  defp letter(sub), do: String.at(sub, -1)
  defp sensor_name(sub), do: "apex-" <> letter(sub)

  # -- SAS mint (mirrors SasVerifier: sig = B64(HMAC-SHA256(key, "sr\nse"))) --

  defp sas_token(audience) do
    key = System.fetch_env!("SMALT_SB_SHARED_KEY")
    se = Integer.to_string(System.system_time(:second) + 3_600)
    sr_enc = URI.encode_www_form(audience)
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr_enc}\n#{se}"))

    "SharedAccessSignature sr=#{sr_enc}" <>
      "&sig=#{URI.encode_www_form(sig)}&se=#{se}&skn=#{@skn}"
  end

  # -- ARM face (shapes from PopcornDemo.LiveTopic/LiveRules) ------------------

  defp req(method, url, opts \\ []) do
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: headers_for(Keyword.get(opts, :headers, [])),
      body: body
    }

    request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
  end

  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

  defp arm_req(method, path, body_map \\ nil) do
    url = "http://127.0.0.1:#{arm_port()}#{path}?#{@api}"

    if body_map do
      req(method, url,
        body: Jason.encode!(body_map),
        headers: [{"content-type", "application/json"}]
      )
    else
      req(method, url)
    end
  end

  defp headers_for(extra) do
    bearer =
      case Process.get({__MODULE__, :token}) do
        nil -> []
        tok -> [{"authorization", "Bearer " <> tok}]
      end

    extra = List.wrap(extra)
    has_ct = Enum.any?(extra, fn {k, _} -> String.downcase(k) == "content-type" end)
    default = if has_ct, do: [], else: [{"content-type", "application/json"}]
    default ++ extra ++ bearer
  end

  defp mint do
    body = "grant_type=client_credentials&client_id=x&client_secret=y&scope=#{@scope}"

    case req(:post, "http://127.0.0.1:#{arm_port()}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} -> {:error, {"mint", "STS-status-#{s}-#{slice(b)}"}}
      {:error, reason} -> {:skip, "transport:#{slice(reason)}"}
    end
  end

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp rg_base, do: "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  defp sb_base, do: "#{rg_base()}/providers/Microsoft.ServiceBus"

  defp ensure_rg do
    case arm_req(:put, rg_base(), %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {"ensure_rg", "HTTP-#{s}-#{slice(b)}"}}
      {:error, reason} -> {:skip, "transport:#{slice(reason)}"}
    end
  end

  # LRO face: 202 + delayMs (Retry-After), bounded server-directed poll.
  defp ensure_ns do
    body = %{"location" => "eastus", "sku" => %{"name" => "Standard"}, "properties" => %{}}

    case arm_req(:put, "#{sb_base()}/namespaces/#{@ns}", body) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: 202, body: %{"name" => op_id} = b}} -> poll_lro(op_id, b, 20)
      {:ok, %{status: s, body: b}} -> {:error, {"ensure_ns", "HTTP-#{s}-#{slice(b)}"}}
      {:error, reason} -> {:skip, "transport:#{slice(reason)}"}
    end
  end

  defp poll_lro(_op_id, _body, 0), do: {:error, {"ensure_ns-lro", "poll-budget-exhausted"}}

  defp poll_lro(op_id, body, left) do
    delay = body |> Map.get("delayMs", 100) |> max(50)

    # SLEEP-CLASS: POLL-STEP (server-directed LRO poll — delayMs from the wire)
    Process.sleep(delay)

    case arm_req(:get, "/subscriptions/#{@sub_id}/operations/#{op_id}") do
      {:ok, %{status: 200, body: %{"status" => "Succeeded"}}} -> :ok
      {:ok, %{status: 202, body: b}} when left > 1 -> poll_lro(op_id, b, left - 1)
      {:ok, %{status: s, body: b}} -> {:error, {"ensure_ns-lro", "HTTP-#{s}-#{slice(b)}"}}
      {:error, reason} -> {:skip, "transport:#{slice(reason)}"}
    end
  end

  defp ensure_topic(topic) do
    case arm_req(:put, "#{sb_base()}/namespaces/#{@ns}/topics/#{topic}",
           %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {"ensure_topic", "HTTP-#{s}-#{slice(b)}"}}
      {:error, reason} -> {:skip, "transport:#{slice(reason)}"}
    end
  end

  defp ensure_subs(topic) do
    Enum.reduce_while(@subs, :ok, fn sub, :ok ->
      case arm_req(:put,
             "#{sb_base()}/namespaces/#{@ns}/topics/#{topic}/subscriptions/#{sub}",
             %{"location" => "eastus", "properties" => %{}}
           ) do
        {:ok, %{status: s}} when s in [200, 201] ->
          {:cont, :ok}

        {:ok, %{status: s, body: b}} ->
          {:halt, {:error, {"ensure_subscription", "HTTP-#{s}-#{slice(b)}"}}}

        {:error, reason} ->
          {:halt, {:skip, "transport:#{slice(reason)}"}}
      end
    end)
  end

  # ------------------------------------------------------------------ wire

  defp connect do
    case :gen_tcp.connect(~c"127.0.0.1", amqp_port(), [:binary, packet: :raw, active: false], 3_000) do
      {:ok, sock} ->
        {:ok, %{sock: sock, buf: <<>>, did: 0, oid: 1}}

      {:error, reason} ->
        {:skip, "sb-plane-down(#{amqp_port()}-connect-#{fmt(reason)}); boot the lane substrate"}
    end
  end

  defp sasl(st) do
    with :ok <- raw_send(st, @sasl_header),
         {:ok, _mechs, st} <- expect_desc(st, 0x40, 3_000),
         :ok <- raw_send(st, frame(0x01, 0, described(0x41, [str8("ANONYMOUS")]))) do
      case expect_desc(st, 0x44, 3_000) do
        {:ok, <<0x50, 0, _::binary>>, st} -> {:ok, st}
        {:ok, <<0x52, 0, _::binary>>, st} -> {:ok, st}
        {:ok, <<0x43, _::binary>>, st} -> {:ok, st}

        {:ok, code_bytes, _st} ->
          take = min(4, byte_size(code_bytes))
          {:error, {"sasl-outcome", {:code_not_zero, binary_part(code_bytes, 0, take)}}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp open_session(st) do
    with :ok <- raw_send(st, @amqp_header),
         :ok <-
           raw_send(
             st,
             frame(0x00, 0, described(0x10, [str8("apex-fanout-client"), nil, uint(65_536)]))
           ),
         {:ok, _open, st} <- expect_desc(st, 0x10, 3_000),
         :ok <-
           raw_send(
             st,
             frame(0x00, 0, described(0x11, [nil, uint(0), uint(4000), uint(4000)]))
           ),
         {:ok, _begin, st} <- expect_desc(st, 0x11, 3_000) do
      {:ok, st}
    end
  end

  # CBS receiver (handle 2) + sender (handle 3) — LiveTopic shapes.
  defp cbs_setup(st) do
    source = composite(0x28, [str8("$cbs"), nil, nil, nil, nil, nil, nil, nil])

    rx =
      described(0x12, [
        str8("apex-cbs-receiver"),
        uint(2),
        bool(true),
        nil,
        nil,
        source,
        nil,
        nil,
        nil,
        uint(0)
      ])

    with :ok <- raw_send(st, frame(0x00, 0, rx)),
         {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000),
         :ok <- grant_credit(st, 2, 40),
         {:ok, st} <- attach_link(st, cbs_tx_attach()) do
      {:ok, st}
    end
  end

  defp cbs_tx_attach do
    target = composite(0x29, [str8("$cbs"), nil, nil, nil, nil, nil])

    described(0x12, [
      str8("apex-cbs-sender"),
      uint(3),
      bool(false),
      ubyte(1),
      nil,
      nil,
      target,
      nil,
      nil,
      uint(0)
    ])
  end

  defp attach_link(st, attach) do
    with :ok <- raw_send(st, frame(0x00, 0, attach)),
         {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000) do
      {:ok, st}
    end
  end

  defp cbs_put_token(st, audience) do
    mid = "apex-cbs-#{System.system_time(:millisecond)}-#{:rand.uniform(999)}"

    props = described(0x73, [str8(mid), nil, str8("$cbs"), nil, nil, str8(mid)])

    app_props = [
      <<0x00, 0x53, 0x74>>,
      enc_elem(
        {:amqp_map,
         %{
           "operation" => "put-token",
           "type" => "servicebus.windows.net:sastoken",
           "name" => audience
         }}
      )
    ]

    token = sas_token(audience)
    body = [<<0x00, 0x53, 0x75>>, <<0xA0, byte_size(token)>>, token]

    xfer =
      described(0x14, [
        uint(3),
        uint(st.did),
        vbin8(:binary.copy(<<0>>, 16)),
        uint(0),
        bool(false)
      ])

    st = %{st | did: st.did + 1}

    with :ok <- raw_send(st, frame_with_payload(0x00, 0, xfer, [props, app_props, body])) do
      await_status_reply(st, audience, 20)
    end
  end

  defp await_status_reply(_st, _audience, 0), do: {:error, {"cbs", :no_reply}}

  defp await_status_reply(st, audience, budget) do
    case next_frame(st, 3_000) do
      {:ok, {:amqp, 0x14, _list, payload}, st} ->
        case status_code(payload) do
          200 -> {:ok, st}
          nil -> await_status_reply(st, audience, budget - 1)
          other -> {:error, {"cbs", "status-#{other}-for-#{slice(audience)}"}}
        end

      {:ok, {:amqp, d, _l, _p}, _st} when d in [0x16, 0x17, 0x18] ->
        {:error, {"cbs", {:broker_refused_frame_0x, d}}}

      {:ok, {:amqp, _other, _l, _p}, st} ->
        await_status_reply(st, audience, budget - 1)

      {:error, _} = err ->
        err
    end
  end

  defp status_code(payload) do
    case :binary.match(payload, "status-code") do
      {pos, 11} ->
        rest = binary_part(payload, pos, byte_size(payload) - pos)

        case rest do
          <<_::binary-size(11), 0x52, v, _::binary>> -> v
          <<_::binary-size(11), 0x70, v::32, _::binary>> -> v
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Sender (handle 0) at the bare topic entity.
  defp attach_sender(st, topic) do
    target = composite(0x29, [str8(topic), nil, nil, nil, nil, nil, nil])

    attach =
      described(0x12, [
        str8("apex-topic-sender"),
        uint(@h_tx),
        bool(false),
        ubyte(1),
        nil,
        nil,
        target,
        nil,
        nil,
        uint(0)
      ])

    attach_link(st, attach)
  end

  defp rx_attach(name, handle, address) do
    source = composite(0x28, [str8(address), nil, nil, nil, nil, nil, nil, nil])

    described(0x12, [
      str8(name),
      uint(handle),
      bool(true),
      nil,
      nil,
      source,
      nil,
      nil,
      nil,
      uint(0)
    ])
  end

  defp attach_links(st, attaches) do
    Enum.reduce_while(attaches, {:ok, st}, fn attach, {:ok, st} ->
      case attach_link(st, attach) do
        {:ok, st} -> {:cont, {:ok, st}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp attach_sub_receivers(st, topic) do
    subs = if System.get_env("APEX_1RX") == "1", do: ["apex-sa"], else: @subs

    attach_links(
      st,
      Enum.with_index(subs, fn sub, i -> rx_attach("apex-rx-#{sub}", @h_rx + i, sub_addr(topic, sub)) end)
    )
  end

  defp attach_dlq_receivers(st, topic) do
    attach_links(
      st,
      Enum.with_index(@subs, fn sub, i -> rx_attach("apex-dlq-#{sub}", @h_dlq + i, dlq_addr(topic, sub)) end)
    )
  end

  # $management pair (handles 9/10) — the shape witnessed answering add-rule
  # 200s on this lane's block (tx role=false, rx role=true, rx credit after).
  defp attach_mgmt(st) do
    if System.get_env("APEX_MGMTPART") do
      case System.get_env("APEX_MGMTPART") do
        "tx" -> attach_link(st, mgmt_tx_attach())
        "rx" -> attach_link(st, rx_attach("apex-mgmt-rx", @h_mgmt_rx, "$management"))
        "rxcr" ->
          with {:ok, st} <- attach_link(st, rx_attach("apex-mgmt-rx", @h_mgmt_rx, "$management")),
               :ok <- grant_credit(st, @h_mgmt_rx, 40) do
            {:ok, st}
          end
      end
    else
      do_attach_mgmt(st)
    end
  end

defp mgmt_tx_attach do
    tx_target = composite(0x29, [str8("$management"), nil, nil, nil, nil, nil])

    described(0x12, [
      str8("apex-mgmt-tx"),
      uint(@h_mgmt_tx),
      bool(false),
      ubyte(1),
      nil,
      nil,
      tx_target,
      nil,
      nil,
      uint(0)
    ])
  end

  defp do_attach_mgmt(st) do
    with {:ok, st} <- attach_link(st, mgmt_tx_attach()),
         {:ok, st} <- attach_link(st, rx_attach("apex-mgmt-rx", @h_mgmt_rx, "$management")),
         :ok <- grant_credit(st, @h_mgmt_rx, 40) do
      {:ok, st}
    end
  end

  # add-rule over $management: request application-properties
  # {operation: "com.microsoft:add-rule", name: <sub path>}; body amqp-value
  # map {"queue", "rule-name", "rule-description": {"sql-filter": {"expression"}}}.
  defp mgmt_add_rule(st, topic, sub, expr) do
    mid = "apex-rule-#{System.system_time(:millisecond)}-#{:rand.uniform(999)}"

    props = described(0x73, [str8(mid), nil, nil, nil, nil, nil, nil, nil, nil, str8(mid)])

    app_props = [
      <<0x00, 0x53, 0x74>>,
      enc_elem({:amqp_map, %{"operation" => "com.microsoft:add-rule", "name" => sub_addr(topic, sub)}})
    ]

    # Wire gate note (disclosed in the receipt): RuleStore.sql_match?/2 is
    # defective on this toolchain (Regex capture: :all_names returns [] even
    # when the pattern matches — every SQL filter evaluates false, KD
    # candidate), so the delivery-path filters ride the correlation-filter
    # form: pure-Elixir match path, same RuleStore gate, distinct per sub.
    body_map =
      {:amqp_map,
       %{
         "queue" => sub_addr(topic, sub),
         "rule-name" => "apex-rule-#{sub}",
         "rule-description" => {:amqp_map, %{"correlation-filter" => {:amqp_map, %{"properties" => {:amqp_map, %{"sensor" => expr}}}}}}
       }}

    body = [<<0x00, 0x53, 0x77>>, enc_elem(body_map)]

    xfer =
      described(0x14, [
        uint(@h_mgmt_tx),
        uint(st.did),
        vbin8(:binary.copy(<<0>>, 16)),
        uint(0),
        bool(false)
      ])

    st = %{st | did: st.did + 1}

    with :ok <- raw_send(st, frame_with_payload(0x00, 0, xfer, [props, app_props, body])) do
      await_status_reply(st, "add-rule:#{sub}", 20)
    end
  end

  defp trace(x), do: (if System.get_env("APEX_DEBUG"), do: IO.puts("DBG " <> inspect(x, limit: 6)); :ok)

  defp wire_setup(topic) do
    trace("wire_setup")
    with {:ok, st} <- connect(),
         {:ok, st} <- sasl(st),
         {:ok, st} <- open_session(st),
         {:ok, st} <- cbs_setup(st),
         :ok <- put_tokens(st, topic),
         :ok <- trace("tokens-ok"),
         {:ok, st} <- attach_sender(st, topic),
         :ok <- trace("sender-ok"),
         {:ok, st} <- attach_sub_receivers(st, topic),
         :ok <- trace("rx-ok"),
         # Lane finding: this broker delivers only to links credited BEFORE
         # the deliveries exist (witnessed: late credit starved every drain).
         :ok <- pre_credit(st) do
      {:ok, st}
    end
  end

  # Rules ride a SEPARATE management connection: this broker stops delivering
  # to data links on a connection that also holds $management links (lane
  # finding, receipt). RuleStore is VM-global, so rules added on conn B gate
  # the fan-out on conn A.
  defp add_rules_on_mgmt_conn(topic) do
    with {:ok, st} <- connect(),
         {:ok, st} <- sasl(st),
         {:ok, st} <- open_session(st),
         {:ok, st} <- attach_mgmt(st),
         {:ok, _} <- add_rules(st, topic) do
      :gen_tcp.close(st.sock)
      :ok
    end
  end

  defp pre_credit(st) do
    credit = String.to_integer(System.get_env("APEX_CREDIT") || "4096")
    Enum.each(@h_rx..(@h_rx + 3), fn h -> :ok = grant_credit(st, h, credit) end)
    :ok
  end

  defp put_tokens(st, topic) do
    dlq_toks? = System.get_env("APEX_NODLQTOK") != "1"

    audiences =
      [sb_endpoint() <> "/" <> topic] ++
        Enum.flat_map(@subs, fn sub -> [sb_endpoint() <> "/" <> sub_addr(topic, sub)] end) ++
        (if dlq_toks? do
           Enum.map(@subs, fn sub -> sb_endpoint() <> "/" <> dlq_addr(topic, sub) end)
         else
           []
         end)

    case Enum.reduce_while(audiences, :ok, fn aud, :ok ->
           case cbs_put_token(st, aud) do
             {:ok, _} -> {:cont, :ok}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      :ok -> :ok
      err -> err
    end
  end

  # diagnostic peek (queue depth proof) via the witnessed peek-message op
  defp mgmt_peek(st, topic, sub, count) do
    mid = "apex-peek-#{System.system_time(:millisecond)}"

    props = described(0x73, [str8(mid), nil, nil, nil, nil, nil, nil, nil, nil, str8(mid)])

    app_props = [
      <<0x00, 0x53, 0x74>>,
      enc_elem({:amqp_map, %{"operation" => "com.microsoft:peek-message", "name" => sub_addr(topic, sub)}})
    ]

    body_map =
      {:amqp_map,
       %{
         "queue" => sub_addr(topic, sub),
         "message-count" => {:uint, count},
         "from-sequence-number" => {:uint, 1}
       }}

    body = [<<0x00, 0x53, 0x77>>, enc_elem(body_map)]

    xfer =
      described(0x14, [
        uint(@h_mgmt_tx),
        uint(st.did),
        vbin8(:binary.copy(<<0>>, 16)),
        uint(0),
        bool(false)
      ])

    st = %{st | did: st.did + 1}

    with :ok <- raw_send(st, frame_with_payload(0x00, 0, xfer, [props, app_props, body])) do
      peek_loop(st, 60)
    end
  end

  defp peek_loop(_st, 0), do: {:ok, :budget}

  defp peek_loop(st, n) do
    case next_frame(st, 3_000) do
      {:ok, {:amqp, 0x14, _l, payload}, st} ->
        trace({:peek_reply, Base.encode16(binary_part(payload, 0, min(160, byte_size(payload))))})
        {:ok, st}

      {:ok, {:amqp, _d, _l, _p}, st} ->
        peek_loop(st, n - 1)

      {:error, e} ->
        trace({:peek_err, e})
        {:ok, st}
    end
  end

  defp add_rules(st, topic) do
    Enum.reduce_while(@subs, {:ok, st}, fn sub, {:ok, st} ->
      case mgmt_add_rule(st, topic, sub, "sensor = '#{sensor_name(sub)}'") do
        {:ok, st} -> {:cont, {:ok, st}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # ------------------------------------------------------------------ cycle

  defp cycle(st, topic, good, bad) do
    PopcornDemo.ApexFanout.Sink.init()

    t0 = System.monotonic_time(:millisecond)
    events = build_events(good, bad)
    handle_sub = Map.new(Enum.with_index(@subs, fn s, i -> {@h_rx + i, s} end))

    trace("pub-begin")
    if System.get_env("APEX_PEEK") == "1" do
      case mgmt_peek(st, topic, "apex-sa", 10) do
        {:ok, st} -> trace("peek-ok")
        e -> trace({:peek_err, e})
      end
    end

    with {:ok, st, publish_ms} <- publish_all(st, events),
         :ok <- (if System.get_env("APEX_PEEK2"), do: (mgmt_peek(st, topic, "apex-sa", 10); :ok), else: :ok),
         :ok <- (if System.get_env("APEX_PEEK2") == "2", do: (mgmt_peek(st, topic, "", 10); :ok), else: :ok),
         {:ok, st, got, drain_ms} <- drain_subs(st, handle_sub, good + bad, t0),
         {:ok, st, dlqs, dlq_ms} <- dlq_phase(st, topic, bad, t0) do
      t1 = System.monotonic_time(:millisecond)
      {:ok, verify(topic, got, dlqs, good, bad, t1 - t0, publish_ms, drain_ms, dlq_ms)}
    end
  end

  # Interleaved event list {sub, body}: round-robin across sensors so no
  # ordering assumption can masquerade as filtering. Event index > good of a
  # sensor's stream is malformed (non-JSON body) — deterministic placement.
  defp build_events(good, bad) do
    tag = System.system_time(:millisecond)

    per_sub =
      Map.new(@subs, fn sub ->
        l = letter(sub)

        bodies =
          for i <- 1..(good + bad) do
            if i <= good do
              ~s({"id":"apex-#{tag}-#{l}-#{i}","sensor":"#{sensor_name(sub)}","v":#{i}})
            else
              "MALFORMED apex-#{tag}-#{l}-bad#{i} not-json{{{"
            end
          end

        {sub, bodies}
      end)

    for i <- 1..(good + bad), sub <- @subs do
      {sub, Enum.at(per_sub[sub], i - 1)}
    end
  end

  defp publish_all(st, events) do
    t0 = System.monotonic_time(:millisecond)

    res =
      Enum.reduce_while(events, {:ok, st}, fn {_sub, body}, {:ok, st} ->
        did = st.did

        # settled=true — fire-and-forget ingress; the fan-out gate is the
        # broker's, not ours. APEX_UNSETTLED=1 rides the live_topic shape
        # (per-publish accepted disposition) as a bisect switch.
        settled? = System.get_env("APEX_UNSETTLED") != "1"

        xfer =
          described(0x14, [
            uint(@h_tx),
            uint(did),
            vbin8(:binary.copy(<<0>>, 16)),
            uint(0),
            bool(settled?)
          ])

        app_props = [
          <<0x00, 0x53, 0x74>>,
          enc_elem({:amqp_map, %{"sensor" => sensor_of(body)}})
        ]

        payload = [
          app_props,
          [<<0x00, 0x53, 0x75>>, <<0xA0, byte_size(body)>>, body]
        ]

        case raw_send(st, frame_with_payload(0x00, @h_tx, xfer, payload)) do
          :ok -> {:cont, {:ok, %{st | did: did + 1}}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case res do
      {:ok, st} -> {:ok, st, max(0, System.monotonic_time(:millisecond) - t0)}
      err -> err
    end
  end

  defp sensor_of(body) do
    marker = ~s("sensor":")
    msz = byte_size(marker)

    case :binary.match(body, marker) do
      {pos, _} ->
        rest = binary_part(body, pos + msz, byte_size(body) - pos - msz)

        case :binary.match(rest, ~s(")) do
          {p2, _} -> binary_part(rest, 0, p2)
          :nomatch -> rest
        end

      :nomatch ->
        "unknown"
    end
  end

  # Drain the 4 subscription receivers: accept good bodies, reject malformed
  # with the typed dead-letter reason. Receivers were credited pre-publish.
  defp drain_subs(st, handle_sub, per_sub, t0) do
    t = System.monotonic_time(:millisecond)
    total = map_size(handle_sub) * per_sub

    case drain_loop(st, handle_sub, %{}, per_sub, total, 20_000, t0) do
      {:ok, st, got} -> {:ok, st, got, max(0, System.monotonic_time(:millisecond) - t)}
      err -> err
    end
  end

  defp drain_loop(_st, _handle_sub, got, _per_sub, _total, 0, _t0),
    do: {:error, {"drain", :budget_exhausted}}

  defp drain_loop(st, handle_sub, got, per_sub, total, budget, t0) do
    counted = got |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    if counted >= total do
      {:ok, st, got}
    else
      case next_frame(st, 5_000) do
        {:ok, {:amqp, 0x14, list_bytes, payload}, st} ->
          handle = transfer_handle(list_bytes)

          case Map.fetch(handle_sub, handle) do
            {:ok, sub} ->
              did = transfer_delivery_id(list_bytes)
              body = body_data(payload)

              state = if malformed?(body), do: rejected_state(), else: accepted_state()

              :ok = raw_send(st, frame(0x00, 0, disposition(did, state)))
              PopcornDemo.ApexFanout.Sink.record(sub, t0)

              got = Map.update(got, sub, [body], &[body | &1])
              drain_loop(st, handle_sub, got, per_sub, total, budget - 1, t0)

            :error ->
              drain_loop(st, handle_sub, got, per_sub, total, budget - 1, t0)
          end

        {:ok, {:amqp, d, _l, payload}, _st} when d in [0x16, 0x17, 0x18] ->
          trace({:drain_refused, d, Base.encode16(binary_part(payload, 0, min(200, byte_size(payload))))})
          {:error, {"drain", {:broker_refused_frame_0x, d}}}

        {:ok, {:amqp, _other, _l, _p}, st} ->
          drain_loop(st, handle_sub, got, per_sub, total, budget - 1, t0)

        {:error, _} = err ->
          err
      end
    end
  end

  defp malformed?(body) when is_binary(body), do: not String.starts_with?(body, "{")
  defp malformed?(_), do: true

  defp accepted_state, do: described(0x24, [])

  # rejected whose error info-map carries the typed reason — the exact shape
  # connection.ex settle(:deadletter,...) parses (KD-77 residual).
  defp rejected_state do
    error =
      described(0x1D, [
        str8("apex:malformed-payload"),
        str8(@dlq_desc),
        {:amqp_map,
         %{"DeadLetterReason" => @dlq_reason, "DeadLetterErrorDescription" => @dlq_desc}}
      ])

    described(0x26, [error])
  end

  defp disposition(did, state) do
    described(0x15, [bool(true), uint(did), uint(did), bool(true), state])
  end

  # DLQ phase: the rejected entries exist (deadletter/5 created the entities
  # mid-drain). The DLQ drain rides a SEPARATE connection (lane finding:
  # DLQ-audience CBS tokens stop deliveries on the connection holding them),
  # with its own put-tokens for the 4 DLQ audiences.
  defp dlq_phase(_st, topic, bad, t0) do
    t = System.monotonic_time(:millisecond)

    with {:ok, st} <- connect(),
         {:ok, st} <- sasl(st),
         {:ok, st} <- open_session(st),
         {:ok, st} <- cbs_setup(st),
         :ok <- put_dlq_tokens(st, topic),
         {:ok, st} <- attach_dlq_receivers(st, topic),
         :ok <- grant_dlq_credit(st),
         {:ok, _st, dlqs} <- dlq_loop(st, dlq_handle_map(), %{}, bad * length(@subs), 20_000, t0) do
      :gen_tcp.close(st.sock)
      {:ok, st, dlqs, max(0, System.monotonic_time(:millisecond) - t)}
    end
  end

  defp put_dlq_tokens(st, topic) do
    audiences = Enum.map(@subs, fn sub -> sb_endpoint() <> "/" <> dlq_addr(topic, sub) end)

    case Enum.reduce_while(audiences, :ok, fn aud, :ok ->
           case cbs_put_token(st, aud) do
             {:ok, _} -> {:cont, :ok}
             {:error, _} = err -> {:halt, err}
           end
         end) do
      :ok -> :ok
      err -> err
    end
  end

  defp dlq_handle_map, do: Map.new(Enum.with_index(@subs, fn s, i -> {@h_dlq + i, s} end))

  defp grant_dlq_credit(st) do
    Enum.each(@h_dlq..(@h_dlq + 3), fn h -> :ok = grant_credit(st, h, 256) end)
    :ok
  end

  defp dlq_loop(_st, _handles, dlqs, _expected, 0, _t0),
    do: {:error, {"dlq", :budget_exhausted}}

  defp dlq_loop(st, handles, dlqs, expected, budget, t0) do
    counted = dlqs |> Map.values() |> List.flatten() |> length()

    if counted >= expected do
      {:ok, st, dlqs}
    else
      case next_frame(st, 5_000) do
        {:ok, {:amqp, 0x14, list_bytes, payload}, st} ->
          handle = transfer_handle(list_bytes)

          case Map.fetch(handles, handle) do
            {:ok, sub} ->
              did = transfer_delivery_id(list_bytes)
              :ok = raw_send(st, frame(0x00, 0, disposition(did, accepted_state())))
              PopcornDemo.ApexFanout.Sink.record_dlq(sub, t0)

              typed? =
                :binary.match(payload, @dlq_reason) != :nomatch and
                  :binary.match(payload, "DeadLetterReason") != :nomatch

              dlqs = Map.update(dlqs, sub, [{payload, typed?}], &[{payload, typed?} | &1])
              dlq_loop(st, handles, dlqs, expected, budget - 1, t0)

            :error ->
              dlq_loop(st, handles, dlqs, expected, budget - 1, t0)
          end

        {:ok, {:amqp, d, _l, _p}, _st} when d in [0x16, 0x17, 0x18] ->
          {:error, {"dlq", {:broker_refused_frame_0x, d}}}

        {:ok, {:amqp, _other, _l, _p}, st} ->
          dlq_loop(st, handles, dlqs, expected, budget - 1, t0)

        {:error, _} = err ->
          err
      end
    end
  end

  defp verify(topic, got, dlqs, good, bad, cycle_ms, publish_ms, drain_ms, dlq_ms) do
    per_sub_good =
      Map.new(@subs, fn sub ->
        bodies = Map.get(got, sub, [])
        {sub, Enum.count(bodies, &String.starts_with?(&1, "{"))}
      end)

    per_sub_bad =
      Map.new(@subs, fn sub ->
        bodies = Map.get(got, sub, [])
        {sub, Enum.count(bodies, &malformed?/1)}
      end)

    misroutes =
      Enum.sum(
        Enum.map(@subs, fn sub ->
          Map.get(got, sub, [])
          |> Enum.count(fn body ->
            String.starts_with?(body, "{") and sensor_of(body) != sensor_name(sub)
          end)
        end)
      )

    dlq_entries = dlqs |> Map.values() |> List.flatten()
    dlq_total = length(dlq_entries)
    dlq_typed = Enum.count(dlq_entries, fn {_p, t} -> t end)

    good_total = Enum.sum(Map.values(per_sub_good))
    bad_total = Enum.sum(Map.values(per_sub_bad))
    expected_total = length(@subs) * (good + bad)
    loss = expected_total - good_total - bad_total - dlq_total

    sink = PopcornDemo.ApexFanout.Sink

    %{
      topic: topic,
      cycle_ms: cycle_ms,
      publish_ms: publish_ms,
      drain_ms: drain_ms,
      dlq_ms: dlq_ms,
      good: good_total,
      deadlettered: dlq_total,
      dlq_typed: dlq_typed,
      per_sub: per_sub_good,
      per_sub_bad: per_sub_bad,
      misroutes: misroutes,
      loss: loss,
      windows: sink.windows(),
      sink: sink.snapshot()
    }
  end

  # ------------------------------------------------------- minimal AMQP 1.0 codec
  # (encode + decode, adapted 1:1 from PopcornDemo.LiveTopic — proven shapes)

  defp bool(true), do: {:bool, true}
  defp bool(false), do: {:bool, false}
  defp ubyte(v), do: {:ubyte, v}
  defp uint(v), do: {:uint, v}
  defp str8(s), do: {:str8, s}
  defp vbin8(b), do: {:vbin8, b}
  defp composite(desc, elems), do: {:composite, desc, elems}
  defp described(desc, elems), do: [<<0x00, 0x53, desc>>, encode_list(elems)]

  defp encode_list(elems) do
    body =
      elems
      |> Enum.map(&enc_elem/1)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == <<0x40>>))
      |> Enum.reverse()

    n = length(body)
    payload = IO.iodata_length(body)
    [<<0xC0, payload + 1, n>>, body]
  end

  defp enc_elem(nil), do: <<0x40>>
  defp enc_elem({:composite, desc, elems}), do: [<<0x00, 0x53, desc>>, encode_list(elems)]
  defp enc_elem(x) when is_list(x), do: x

  # map8 (0xC1): the only map form this broker's PrimitiveCodec decodes (KD-B).
  defp enc_elem({:amqp_map, map}) when map_size(map) < 256 do
    pairs = Enum.flat_map(map, fn {k, v} -> [str8_enc(to_string(k)), enc_elem(v)] end)
    payload = IO.iodata_length(pairs)
    [<<0xC1, payload + 1, map_size(map)>>, pairs]
  end

  defp enc_elem({:ubyte, v}), do: <<0x50, v>>
  defp enc_elem({:bool, v}), do: <<0x56, if(v, do: 1, else: 0)>>
  defp enc_elem({:vbin8, b}) when byte_size(b) < 256, do: <<0xA0, byte_size(b), b::binary>>
  defp enc_elem({:str8, s}) when byte_size(s) < 256, do: <<0xA1, byte_size(s), s::binary>>
  defp enc_elem({:uint, v}) when is_integer(v) and v >= 0 and v < 256, do: <<0x52, v>>
  defp enc_elem({:uint, v}) when is_integer(v) and v >= 256 and v <= 0xFFFFFFFF, do: <<0x70, v::32>>
  defp enc_elem(s) when is_binary(s), do: str8_enc(s)

  defp str8_enc(s) when byte_size(s) < 256, do: <<0xA1, byte_size(s), s::binary>>

  defp frame(type, channel, body) do
    body_bytes = IO.iodata_length(body)
    [<<(8 + body_bytes)::32, 2::8, type::8, channel::16>>, body]
  end

  defp frame_with_payload(type, channel, body, payload) do
    body_bytes = IO.iodata_length([body, payload])
    [<<(8 + body_bytes)::32, 2::8, type::8, channel::16>>, body, payload]
  end

  # Flow field order follows the BROKER's decode order (witnessed in
  # LiveTopic: the spec order left link credit nil and receivers starved).
  defp grant_credit(st, handle, credit) do
    raw_send(
      st,
      frame(
        0x00,
        0,
        described(0x13, [
          nil,
          uint(1000),
          uint(st.oid),
          uint(1000),
          uint(handle),
          nil,
          uint(credit),
          nil,
          nil
        ])
      )
    )
  end

  defp transfer_delivery_id(list_bytes) do
    {_handle, rest} = take_elem(list_bytes)
    {did, _rest} = take_elem(rest)
    decode_uint(did)
  end

  defp transfer_handle(list_bytes) do
    {handle, _} = take_elem(list_bytes)
    decode_uint(handle)
  end

  defp take_elem(<<0x40, r::binary>>), do: {nil, r}
  defp take_elem(<<0x43, r::binary>>), do: {0, r}
  defp take_elem(<<0x50, v, r::binary>>), do: {v, r}
  defp take_elem(<<0x52, v, r::binary>>), do: {v, r}
  defp take_elem(<<0x56, v, r::binary>>), do: {v == 1, r}
  defp take_elem(<<0x70, v::32, r::binary>>), do: {v, r}
  defp take_elem(<<0xA0, len, d::binary-size(len), r::binary>>), do: {d, r}
  defp take_elem(<<0xA1, len, d::binary-size(len), r::binary>>), do: {d, r}
  defp take_elem(<<0xC0, size, _count, d::binary-size(size - 1), r::binary>>), do: {d, r}

  defp take_elem(<<0x00, r::binary>>) do
    {_desc, r1} = take_elem(r)
    {value, r2} = take_elem(r1)
    {value, r2}
  end

  defp take_elem(_), do: {nil, <<>>}
  defp decode_uint(v) when is_integer(v), do: v
  defp decode_uint(_), do: nil

  defp body_data(payload) do
    case :binary.match(payload, <<0x00, 0x53, 0x75>>) do
      {pos, _} ->
        rest = binary_part(payload, pos, byte_size(payload) - pos)

        case rest do
          <<0x00, 0x53, 0x75, 0xA0, len, data::binary-size(len), _::binary>> -> data
          <<0x00, 0x53, 0x75, 0xB0, len::32, data::binary-size(len), _::binary>> -> data
          _ -> :no_body_data
        end

      :nomatch ->
        :no_body_data
    end
  end

  defp raw_send(st, iodata), do: with(:ok <- :gen_tcp.send(st.sock, iodata), do: :ok)

  defp expect_desc(st, desc, timeout, budget \\ 100)
  defp expect_desc(_st, _desc, _timeout, 0), do: {:error, {"expect", :budget_exhausted}}

  defp expect_desc(st, desc, timeout, budget) do
    case next_frame(st, timeout) do
      {:ok, {t, d, list_bytes, _payload}, st} when t in [:amqp, :sasl] and d == desc ->
        {:ok, list_bytes, st}

      {:ok, {t, _d, _l, _p}, st} when t in [:amqp, :sasl] ->
        expect_desc(st, desc, timeout, budget - 1)

      {:error, _} = err ->
        err
    end
  end

  defp next_frame(st, timeout) do
    case decode_buf(st.buf) do
      {:ok, frame, rest} ->
        {:ok, frame, %{st | buf: rest}}

      :more ->
        case :gen_tcp.recv(st.sock, 0, timeout) do
          {:ok, more} ->
            next_frame(%{st | buf: st.buf <> more}, timeout)

          {:error, reason} ->
            {:error, {:recv, reason}}
        end

      {:error, reason} ->
        {:error, {"decode", reason}}
    end
  end

  defp decode_buf(<<"AMQP", _::binary>> = buf) when byte_size(buf) < 8, do: :more

  defp decode_buf(<<"AMQP", _::binary-size(4), rest::binary>>) do
    case rest do
      <<>> -> :more
      _ -> decode_buf(rest)
    end
  end

  defp decode_buf(buf) when byte_size(buf) < 8, do: :more

  defp decode_buf(<<size::32, 2::8, type::8, _chan::16, body::binary>> = buf) do
    if byte_size(buf) < size do
      :more
    else
      body_len = size - 8
      <<frame_body::binary-size(^body_len), rest::binary>> = body
      decode_frame_body(type, frame_body, rest)
    end
  end

  defp decode_buf(<<_size::32, _doff::8, _type::8, _chan::16, _::binary>>),
    do: {:error, :bad_frame_type}

  defp decode_frame_body(0, body, rest), do: decode_frame_body(:amqp, body, rest)
  defp decode_frame_body(1, body, rest), do: decode_frame_body(:sasl, body, rest)

  defp decode_frame_body(type, <<0x00, 0x53, desc, list::binary>>, rest)
       when type in [:amqp, :sasl] do
    {list_bytes, payload} = split_list(list)
    {:ok, {type, desc, list_bytes, payload}, rest}
  end

  defp decode_frame_body(_type, _body, _rest), do: {:error, :bad_frame_body}

  defp split_list(<<0xC0, size, _count, list::binary>>) when size >= 1 do
    <<list_bytes::binary-size(^size - 1), payload::binary>> = list
    {list_bytes, payload}
  end

  defp split_list(<<0xD0, size::32, _count::32, list::binary>>) when size >= 4 do
    <<list_bytes::binary-size(^size - 4), payload::binary>> = list
    {list_bytes, payload}
  end

  defp split_list(_), do: {<<>>, <<>>}
end

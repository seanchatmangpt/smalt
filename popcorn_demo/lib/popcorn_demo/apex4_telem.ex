defmodule PopcornDemo.Apex4Telem do
  @moduledoc """
  APEX-4 telemetry emit/collect bench — minimal 256-event shape over the REAL
  AMQP 1.0 wire, composed 1:1 from PopcornDemo.LiveTopic's proven shapes
  (SASL ANONYMOUS, CBS put-token, single receiver credited pre-publish).

  Measures per run (default 256 events):
    - publish throughput (events/s, settled transfers)
    - collection lag per event (recv instant - publish instant, ETS keyed by
      event id; p50/p95/max)
    - loss accounting (published == collected, 0 lost)
  """

  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2021-04-01"
  @sub_id "popcorn-rg-sub"
  @rg "popcorn-rg"
  @ns "popcorn-ns"
  @skn "RootManageSharedAccessKey"

  @sasl_header "AMQP\x03\x01\x00\x00"
  @amqp_header "AMQP\x00\x01\x00\x00"

  # handles: 0 tx, 1 rx, 2 cbs rx, 3 cbs tx
  @h_tx 0
  @h_rx 1

  @default_n 256

  def run, do: run([])

  def run(opts) when is_list(opts) do
    n = Keyword.get(opts, :n) || int_env("APEX4_N", @default_n)
    topic = "apex4-t-#{System.system_time(:millisecond)}-#{:rand.uniform(999_999)}"

    if :ets.info(:apex4_emit) != :undefined, do: :ets.delete(:apex4_emit)
    :ets.new(:apex4_emit, [:named_table, :public, :set])

    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- ensure_ns(),
         :ok <- ensure_queue(topic),
         {:ok, st} <- wire_setup(topic) do
      stats = cycle(st, topic, n)
      :gen_tcp.close(st.sock)
      {:ok, Map.put(stats, :topic, topic)}
    else
      {:skip, r} -> {:skip, "apex4=SKIP(#{r})"}
      {:error, r} -> {:error, "apex4=FAIL(#{inspect(r, limit: 6)})"}
    end
  end

  def format({:ok, s}) do
    "apex4=OK(events:#{s.n},pub_eps:#{s.publish_eps},collect_eps:#{s.collect_eps}," <>
      "lag_p50_ms:#{s.lag_p50_ms},lag_p95_ms:#{s.lag_p95_ms},lag_max_ms:#{s.lag_max_ms}," <>
      "loss:#{s.loss})"
  end

  def format(other), do: inspect(other, limit: 8)

  # --------------------------------------------------------------- setup

  defp int_env(name, d) do
    case System.get_env(name) do
      nil -> d
      v -> String.to_integer(v)
    end
  end

  defp arm_port, do: String.to_integer(System.get_env("APEX_ARM_PORT") || "9443")
  defp amqp_port, do: String.to_integer(System.get_env("APEX_SB_AMQP_PORT") || "5672")
  defp sb_endpoint, do: "sb://127.0.0.1:#{amqp_port()}"

  defp sas_token(audience) do
    key = System.fetch_env!("SMALT_SB_SHARED_KEY")
    se = Integer.to_string(System.system_time(:second) + 3_600)
    sr_enc = URI.encode_www_form(audience)
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr_enc}\n#{se}"))
    "SharedAccessSignature sr=#{sr_enc}&sig=#{URI.encode_www_form(sig)}&se=#{se}&skn=#{@skn}"
  end

  defp req(method, url, opts \\ []) do
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    bearer =
      case Process.get({__MODULE__, :token}) do
        nil -> []
        tok -> [{"authorization", "Bearer " <> tok}]
      end

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: bearer ++ Keyword.get(opts, :headers, [{"content-type", "application/json"}]),
      body: body
    }

    case PopcornDemo.Transport.Httpc.request(request) do
      {:ok, %{body: b} = resp} when is_binary(b) ->
        case Jason.decode(b) do
          {:ok, d} -> {:ok, %{resp | body: d}}
          _ -> {:ok, resp}
        end

      other ->
        other
    end
  end

  defp arm_req(method, path, body_map \\ nil) do
    url = "http://127.0.0.1:#{arm_port()}#{path}?#{@api}"

    if body_map do
      req(method, url, body: Jason.encode!(body_map), headers: [{"content-type", "application/json"}])
    else
      req(method, url)
    end
  end

  defp mint do
    body = "grant_type=client_credentials&client_id=x&client_secret=y&scope=#{@scope}"

    case req(:post, "http://127.0.0.1:#{arm_port()}/#{@tenant}/oauth2/v2.0/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} -> {:error, {:mint, s, b}}
      {:error, r} -> {:skip, "transport:#{inspect(r, limit: 3)}"}
    end
  end

  defp ensure_rg do
    case arm_req(:put, "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}", %{
           "location" => "eastus",
           "properties" => %{}
         }) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {:ensure_rg, s, b}}
      {:error, r} -> {:skip, "transport:#{inspect(r, limit: 3)}"}
    end
  end

  # LRO face: 202 + delayMs, bounded server-directed poll.
  defp ensure_ns do
    case arm_req(:put,
           "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}/providers/Microsoft.ServiceBus/namespaces/#{@ns}",
           %{"location" => "eastus", "sku" => %{"name" => "Standard"}, "properties" => %{}}
         ) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: 202, body: %{"name" => op_id}} = b} -> poll_lro(op_id, b, 20)
      {:ok, %{status: s, body: b}} -> {:error, {:ensure_ns, s, b}}
      {:error, r} -> {:skip, "transport:#{inspect(r, limit: 3)}"}
    end
  end

  defp poll_lro(_op_id, _body, 0), do: {:error, {:ensure_ns_lro, :poll_budget_exhausted}}

  defp poll_lro(op_id, body, left) do
    delay = body |> Map.get("delayMs", 100) |> max(50)

    # SLEEP-CLASS: POLL-STEP (server-directed LRO poll — delayMs from the wire)
    Process.sleep(delay)

    case arm_req(:get, "/subscriptions/#{@sub_id}/operations/#{op_id}") do
      {:ok, %{status: 200, body: %{"status" => "Succeeded"}}} -> :ok
      {:ok, %{status: 202, body: b}} when left > 1 -> poll_lro(op_id, b, left - 1)
      {:ok, %{status: s, body: b}} -> {:error, {:ensure_ns_lro, s, b}}
      {:error, r} -> {:skip, "transport:#{inspect(r, limit: 3)}"}
    end
  end

  defp ensure_queue(topic) do
    case arm_req(:put,
           "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}/providers/Microsoft.ServiceBus/namespaces/#{@ns}/queues/#{topic}",
           %{"location" => "eastus", "properties" => %{}}
         ) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {:ensure_topic, s, b}}
      {:error, r} -> {:skip, "transport:#{inspect(r, limit: 3)}"}
    end
  end

  # ------------------------------------------------------------------ wire
  # Shapes lifted 1:1 from PopcornDemo.LiveTopic (proven on this toolchain).

  defp connect do
    case :gen_tcp.connect(~c"127.0.0.1", amqp_port(), [:binary, packet: :raw, active: false], 3_000) do
      {:ok, sock} -> {:ok, %{sock: sock, buf: <<>>, did: 0}}
      {:error, r} -> {:skip, "sb-plane-down(#{inspect(r, limit: 3)})"}
    end
  end

  defp sasl(st) do
    with :ok <- raw_send(st, @sasl_header),
         {:ok, _mechs, st} <- expect_desc(st, 0x40, 3_000),
         :ok <- raw_send(st, frame(0x01, 0, described(0x41, [str8("ANONYMOUS")]))) do
      case expect_desc(st, 0x44, 3_000) do
        {:ok, _outcome, st} -> {:ok, st}
        {:error, _} = e -> e
      end
    end
  end

  defp open_session(st) do
    with :ok <- raw_send(st, @amqp_header),
         :ok <-
           raw_send(
             st,
             frame(0x00, 0, described(0x10, [str8("apex4-telem-client"), nil, uint(65_536)]))
           ),
         {:ok, _open, st} <- expect_desc(st, 0x10, 3_000),
         :ok <- raw_send(st, frame(0x00, 0, described(0x11, [nil, uint(0), uint(4000), uint(4000)]))),
         {:ok, _begin, st} <- expect_desc(st, 0x11, 3_000) do
      {:ok, st}
    end
  end

  defp cbs_setup(st) do
    source = composite(0x28, [str8("$cbs"), nil, nil, nil, nil, nil, nil, nil])

    rx =
      described(0x12, [
        str8("apex4-cbs-receiver"),
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

    target = composite(0x29, [str8("$cbs"), nil, nil, nil, nil, nil])

    tx =
      described(0x12, [
        str8("apex4-cbs-sender"),
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

    with :ok <- raw_send(st, frame(0x00, 0, rx)),
         {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000),
         :ok <- grant_credit(st, 2, 40),
         :ok <- raw_send(st, frame(0x00, 0, tx)),
         {:ok, _echo2, st} <- expect_desc(st, 0x12, 3_000) do
      {:ok, st}
    end
  end

  defp cbs_put_token(st, audience) do
    mid = "apex4-cbs-#{System.system_time(:millisecond)}-#{:rand.uniform(999)}"

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
      await_status_reply(st, 20)
    end
  end

  defp await_status_reply(_st, 0), do: {:error, {:cbs, :no_reply}}

  defp await_status_reply(st, budget) do
    case next_frame(st, 3_000) do
      {:ok, {:amqp, 0x14, _l, payload}, st} ->
        case status_code(payload) do
          200 -> {:ok, st}
          nil -> await_status_reply(st, budget - 1)
          other -> {:error, {:cbs, "status-#{other}"}}
        end

      {:ok, {:amqp, _d, _l, _p}, st} ->
        await_status_reply(st, budget - 1)

      {:error, _} = e ->
        e
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

  defp attach_sender(st, topic) do
    target = composite(0x29, [str8(topic), nil, nil, nil, nil, nil, nil])

    attach =
      described(0x12, [
        str8("apex4-topic-sender"),
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

    with :ok <- raw_send(st, frame(0x00, 0, attach)),
         {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000) do
      {:ok, st}
    end
  end

  defp attach_receiver(st, topic) do
    source = composite(0x28, [str8(topic), nil, nil, nil, nil, nil, nil, nil])

    attach =
      described(0x12, [
        str8("apex4-topic-receiver"),
        uint(@h_rx),
        bool(true),
        nil,
        nil,
        source,
        nil,
        nil,
        nil,
        uint(0)
      ])

    with :ok <- raw_send(st, frame(0x00, 0, attach)),
         {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000) do
      {:ok, st}
    end
  end

  # Flow field order follows the BROKER's decode order (LiveTopic witness:
  # the spec order left link credit nil and receivers starved).
  defp grant_credit(st, handle, credit) do
    raw_send(
      st,
      frame(
        0x00,
        0,
        described(0x13, [
          nil,
          uint(1000),
          uint(1000),
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

  defp wire_setup(topic) do
    with {:ok, st} <- connect(),
         {:ok, st} <- sasl(st),
         {:ok, st} <- open_session(st),
         {:ok, st} <- cbs_setup(st),
         :ok <- put_tokens(st, topic),
         {:ok, st} <- attach_sender(st, topic),
         {:ok, st} <- attach_receiver(st, topic),
         :ok <- grant_credit(st, @h_rx, String.to_integer(System.get_env("APEX4_CREDIT") || "4096")) do
      {:ok, st}
    end
  end

  defp put_tokens(st, topic) do
    case cbs_put_token(st, sb_endpoint() <> "/" <> topic) do
      {:ok, _} -> :ok
      {:error, _} = e -> e
    end
  end

  # ------------------------------------------------------------------ cycle

  defp cycle(st, topic, n) do
    {pub_ms, ids} = publish_all(st, topic, n)
    {drain_ms, lags, got} = drain(st, n)
    lag_list = Enum.sort(Map.values(lags))

    %{
      n: n,
      publish_ms: pub_ms,
      drain_ms: drain_ms,
      publish_eps: safe_eps(n, pub_ms),
      collect_eps: safe_eps(map_size(got), drain_ms),
      lag_p50_ms: pct(lag_list, 0.50),
      lag_p95_ms: pct(lag_list, 0.95),
      lag_max_ms: pct(lag_list, 1.0),
      loss: n - map_size(got)
    }
  end

  defp drain(st, n) do
    t0 = System.monotonic_time(:microsecond)
    {status, lags, got} = drain_loop(st, n, %{}, %{}, n * 200 + 20_000)
    drain_ms = if is_integer(status), do: max(0, System.monotonic_time(:microsecond) - t0) / 1000, else: 0.0
    {drain_ms, lags, got}
  end

  defp drain_loop(st, n, got, lags, budget) do
    cond do
      map_size(got) >= n ->
        {0, lags, got}

      budget <= 0 ->
        {:budget, lags, got}

      true ->
        case next_frame(st, 5_000) do
          {:ok, {:amqp, 0x14, list_bytes, payload}, st} ->
            case body_data(payload) do
              :no_body_data ->
                drain_loop(st, n, got, lags, budget - 1)

              body ->
                did = transfer_delivery_id(list_bytes)
                if System.get_env("APEX4_NOSETTLE") != "1" do
                  :ok = raw_send(st, frame(0x00, 0, disposition(did, described(0x24, []))))
                end

                {got, lags} =
                  case Jason.decode(body) do
                    {:ok, %{"id" => id}} ->
                      g = Map.put(got, id, true)

                      l =
                        case :ets.lookup(:apex4_emit, id) do
                          [{_, t}] -> Map.put(lags, id, now_ms() - t)
                          _ -> lags
                        end

                      {g, l}

                    _ ->
                      {got, lags}
                  end

                drain_loop(st, n, got, lags, budget - 1)
            end

          {:ok, {:amqp, d, _l, p}, st} ->
            if System.get_env("APEX4_DEBUG"),
              do:
                IO.puts(
                  "DBG drainframe 0x" <> Integer.to_string(d, 16) <> " list=" <>
                    Base.encode16(_l |> binary_part(0, min(260, byte_size(_l)))) <>
                    (if p == <<>>, do: "", else: " payload=" <> Base.encode16(binary_part(p, 0, min(160, byte_size(p)))))
                )
            drain_loop(st, n, got, lags, budget - 1)

          {:error, e} ->
            if System.get_env("APEX4_DEBUG"), do: IO.puts("DBG drainerr " <> inspect(e, limit: 4))
            {:error, lags, Map.put(got, :__error, e)}
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp safe_eps(_n, ms) when is_number(ms) and ms <= 0, do: nil
  defp safe_eps(n, ms) when is_number(ms), do: Float.round(n * 1000 / ms, 1)
  defp safe_eps(_n, _), do: nil

  defp pct([], _), do: nil

  defp pct(sorted, q) do
    idx = max(0, min(length(sorted) - 1, trunc(Float.ceil(q * length(sorted))) - 1))
    Enum.at(sorted, idx)
  end

  # Publish n settled JSON telemetry transfers to the bare topic entity,
  # stamping emit instants into ETS keyed by event id.
  defp publish_all(st, topic, n) do
    t0 = now_ms()

    {st, times} =
      Enum.reduce(1..n, {st, %{}}, fn i, {st, times} ->
        id = "apex4-#{System.system_time(:millisecond)}-#{i}"
        body = ~s({"id":"#{id}","sensor":"apex4","v":#{i}})
        :ets.insert(:apex4_emit, {id, now_ms()})

        xfer =
          described(0x14, [
            uint(@h_tx),
            uint(st.did),
            vbin8(:binary.copy(<<0>>, 16)),
            uint(0),
            bool(true)
          ])

        app_props = [<<0x00, 0x53, 0x74>>, enc_elem({:amqp_map, %{"sensor" => "apex4"}})]

        payload = [
          app_props,
          [<<0x00, 0x53, 0x75>>, <<0xA0, byte_size(body)>>, body]
        ]

        frame = frame_with_payload(0x00, @h_tx, xfer, payload)

        case raw_send(st, frame) do
          :ok -> {%{st | did: st.did + 1}, Map.put(times, id, true)}
          {:error, _} -> {st, times}
        end
      end)

    {max(0, now_ms() - t0), Map.keys(times)}
  end

  # Drain until n bodies seen or budget exhausted; lag = recv - emit instant.

  defp disposition(did, state), do: described(0x15, [bool(true), uint(did), uint(did), bool(true), state])

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

  defp enc_elem({:amqp_map, map}) when map_size(map) < 256 do
    pairs = Enum.flat_map(map, fn {k, v} -> [enc_elem(to_string(k)), enc_elem(v)] end)
    payload = IO.iodata_length(pairs)
    [<<0xC1, payload + 1, map_size(map)>>, pairs]
  end

  defp enc_elem({:ubyte, v}), do: <<0x50, v>>
  defp enc_elem({:bool, v}), do: <<0x56, if(v, do: 1, else: 0)>>
  defp enc_elem({:vbin8, b}) when byte_size(b) < 256, do: <<0xA0, byte_size(b), b::binary>>
  defp enc_elem({:str8, s}) when byte_size(s) < 256, do: <<0xA1, byte_size(s), s::binary>>
  defp enc_elem({:uint, v}) when is_integer(v) and v >= 0 and v < 256, do: <<0x52, v>>
  defp enc_elem({:uint, v}) when is_integer(v) and v >= 256 and v <= 0xFFFFFFFF, do: <<0x70, v::32>>
  defp enc_elem(s) when is_binary(s), do: <<0xA1, byte_size(s), s::binary>>

  defp frame(type, channel, body) do
    body_bytes = IO.iodata_length(body)
    [<<(8 + body_bytes)::32, 2::8, type::8, channel::16>>, body]
  end

  defp frame_with_payload(type, channel, body, payload) do
    body_bytes = IO.iodata_length([body, payload])
    [<<(8 + body_bytes)::32, 2::8, type::8, channel::16>>, body, payload]
  end

  defp transfer_delivery_id(list_bytes) do
    {_handle, rest} = take_elem(list_bytes)
    {did, _rest} = take_elem(rest)
    decode_uint(did)
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
  defp expect_desc(_st, _desc, _timeout, 0), do: {:error, {:expect, :budget_exhausted}}

  defp expect_desc(st, desc, timeout, budget) do
    case next_frame(st, timeout) do
      {:ok, {t, d, list_bytes, _payload}, st} when t in [:amqp, :sasl] and d == desc ->
        {:ok, list_bytes, st}

      {:ok, {t, _d, _l, _p}, st} when t in [:amqp, :sasl] ->
        expect_desc(st, desc, timeout, budget - 1)

      {:error, _} = e ->
        e
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
        {:error, {:decode, reason}}
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
  defp decode_frame_body(1, body, rest), do: decode_frame_body(:amqp, body, rest)

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

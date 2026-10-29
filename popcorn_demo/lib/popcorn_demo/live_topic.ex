defmodule PopcornDemo.LiveTopic do
  @moduledoc """
  X3 lane — Service Bus TOPIC publish/subscribe loop over the REAL wire
  (Chicago testbed: real collaborators, real substrate, no mocks).

  One `run/0`:

    1. ensure namespace/topic/subscription via the ARM rules-walk shapes
       (run-unique topic `popcorn-tx-<ms>-<rand>`, subscription `popcorn-sx`),
       LRO POLL-STEP pattern from `PopcornDemo.LiveRules` (server-directed
       delayMs poll, deadline 20). # SLEEP-CLASS: POLL-STEP
    2. authenticate the AMQP face with a real SAS token over `$cbs`
       (put-token, skn RootManageSharedAccessKey, sig =
       Base64(HMAC-SHA256(key, "sr\\nse")) signed for the per-entity audience
       `sb://127.0.0.1:<amqp>/<entity>`), then publish 2 uniquely-tagged
       messages to the topic over the real AMQP 1.0 wire, sender attached at
       the bare topic entity — SB topics attach at `<topic>` and
       subscriptions at `<topic>/Subscriptions/<sub>` per the SB AMQP mapping
       (lib/smalt/messaging/amqp/queue_store.ex:299 and connection.ex
       bare_entity/route -> :queue).
    3. receive on the subscription's address, assert BOTH messages arrive
       BYTE-EXACT in PUBLISH order (FIFO), settle each with an accepted
       disposition (receiver role, broker delivery-id echo), then prove
       settlement took by re-crediting and receiving to EMPTY.

  Endpoints ride env so the lane can target a private substrate block:
  `X3_ARM_PORT` (default 9443), `X3_SB_AMQP_PORT` (default 5672), and
  `SMALT_SB_SHARED_KEY` (the substrate's `:sb_shared_key` app-env value;
  `SasVerifier.shared_key/0` floors the app-env key at 32 bytes and
  otherwise falls back to a RANDOM per-boot dev key — witnessed: both
  anonymous attaches and foreign-key put-tokens are refused with an
  unauthorized detach on the shared canonical substrate).
  """

  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2021-04-01"

  @sub_id "popcorn-rg-sub"
  @rg "popcorn-rg"
  @ns "popcorn-ns"
  @sub "popcorn-sx"
  @skn "RootManageSharedAccessKey"

  @sasl_header "AMQP\x03\x01\x00\x00"
  @amqp_header "AMQP\x00\x01\x00\x00"

  @doc "Full topic walk on a run-unique topic. {:ok, frag} | {:skip, frag} | {:error, frag}."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    topic = "popcorn-tx-#{System.system_time(:millisecond)}-#{:rand.uniform(999_999)}"
    run(topic)
  end

  @doc "Topic walk on an explicit topic name (test seam)."
  def run(topic) when is_binary(topic) do
    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- ensure_ns(),
         :ok <- ensure_topic(topic),
         :ok <- ensure_subscription(topic),
         {:ok, st} <- connect(),
         {:ok, st} <- sasl(st),
         {:ok, st} <- open_session(st),
         {:ok, st} <- cbs_setup(st),
         {:ok, st} <- cbs_put_token(st, sb_endpoint() <> "/" <> topic),
         {:ok, st} <- cbs_put_token(st, sb_endpoint() <> "/" <> topic <> "/Subscriptions/" <> @sub),
         {:ok, st} <- attach_sender(st, topic),
         {:ok, st} <- attach_receiver(st, topic),
         {:ok, st, t1, t2} <- publish_two(st),
         {:ok, st, got} <- credit_and_drain(st, [t1, t2]),
         :ok <- settle_all(st, got),
         :ok <- assert_drained(st) do
      :gen_tcp.close(st.sock)
      {:ok, "topic=OK(#{topic}:2-delivered)"}
    else
      {:skip, reason} -> {:skip, "topic=SKIP(#{reason})"}
      {:error, {step, reason}} -> {:error, "topic=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  defp fmt(r) when is_binary(r), do: r
  defp fmt(r), do: inspect(r, limit: 10)

  defp arm_port, do: String.to_integer(System.get_env("X3_ARM_PORT") || "9443")
  defp amqp_port, do: String.to_integer(System.get_env("X3_SB_AMQP_PORT") || "5672")
  defp sb_endpoint, do: "sb://127.0.0.1:#{amqp_port()}"

  # -- SAS mint (mirrors SasVerifier: sig = B64(HMAC-SHA256(key, "sr\nse"))) --

  defp sas_token(audience) do
    key = System.fetch_env!("SMALT_SB_SHARED_KEY")
    se = Integer.to_string(System.system_time(:second) + 3_600)
    # string-to-sign uses the URL-ENCODED sr (SasVerifier check_signature
    # passes fields.sr RAW into the HMAC — witnessed 401 when signing decoded)
    sr_enc = URI.encode_www_form(audience)
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr_enc}\n#{se}"))

    "SharedAccessSignature sr=#{sr_enc}" <>
      "&sig=#{URI.encode_www_form(sig)}&se=#{se}&skn=#{@skn}"
  end

  # -- ARM face (shapes from PopcornDemo.LiveRules) ---------------------------

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=#{@scope}"

    case req(:post, "http://127.0.0.1:#{arm_port()}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]
          ) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, {"mint", "STS-status-#{s}-body=#{slice(b)}"}}

      {:error, reason} ->
        {:skip, "transport:#{slice(reason)}"}
    end
  end

  defp rg_base, do: "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  defp sb_base, do: "#{rg_base()}/providers/Microsoft.ServiceBus"

  defp ensure_rg do
    case arm_req(:put, rg_base(), %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, {"ensure_rg", "HTTP-#{s}-#{slice(b)}"}}

      {:error, reason} ->
        {:skip, "transport:#{slice(reason)}"}
    end
  end

  # LRO face: 202 + delayMs (Retry-After), poll the operation until 200.
  defp ensure_ns do
    body = %{"location" => "eastus", "sku" => %{"name" => "Standard"}, "properties" => %{}}

    case arm_req(:put, "#{sb_base()}/namespaces/#{@ns}", body) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: 202, body: %{"name" => op_id} = b}} ->
        poll_lro(op_id, b, 20)

      {:ok, %{status: s, body: b}} ->
        {:error, {"ensure_ns", "HTTP-#{s}-#{slice(b)}"}}

      {:error, reason} ->
        {:skip, "transport:#{slice(reason)}"}
    end
  end

  # Server-directed bounded LRO poll: interval = the wire's own delayMs
  # (Retry-After), deadline = 20 polls. # SLEEP-CLASS: POLL-STEP
  defp poll_lro(_op_id, _body, 0), do: {:error, {"ensure_ns-lro", "poll-budget-exhausted"}}

  defp poll_lro(op_id, body, left) do
    delay = body |> Map.get("delayMs", 100) |> max(50)

    # SLEEP-CLASS: POLL-STEP (server-directed LRO poll — delayMs from the wire)
    Process.sleep(delay)

    case arm_req(:get, "/subscriptions/#{@sub_id}/operations/#{op_id}") do
      {:ok, %{status: 200, body: %{"status" => "Succeeded"}}} ->
        :ok

      {:ok, %{status: 202, body: b}} when left > 1 ->
        poll_lro(op_id, b, left - 1)

      {:ok, %{status: s, body: b}} ->
        {:error, {"ensure_ns-lro", "HTTP-#{s}-#{slice(b)}"}}

      {:error, reason} ->
        {:skip, "transport:#{slice(reason)}"}
    end
  end

  defp ensure_topic(topic) do
    case arm_req(:put, "#{sb_base()}/namespaces/#{@ns}/topics/#{topic}", %{
           "location" => "eastus",
           "properties" => %{}
         }) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, {"ensure_topic", "HTTP-#{s}-#{slice(b)}"}}

      {:error, reason} ->
        {:skip, "transport:#{slice(reason)}"}
    end
  end

  defp ensure_subscription(topic) do
    path = "#{sb_base()}/namespaces/#{@ns}/topics/#{topic}/subscriptions/#{@sub}"

    case arm_req(:put, path, %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, {"ensure_subscription", "HTTP-#{s}-#{slice(b)}"}}

      {:error, reason} ->
        {:skip, "transport:#{slice(reason)}"}
    end
  end

  # -- ARM transport (Httpc via PopcornDemo.Transport; raw bodies decoded here) -

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

  # -- AMQP face (codec adapted from PopcornDemo.LiveEh, proven shapes) -------

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
        # outcome code 0 arrives as any uint-zero encoding
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

  # open + begin; links attach below (cbs handles 2/3, entity links 0/1).
  defp open_session(st) do
    with :ok <- raw_send(st, @amqp_header),
         :ok <-
           raw_send(
             st,
             frame(0x00, 0, described(0x10, [str8("popcorn-topic-client"), nil, uint(65_536)]))
           ),
         {:ok, _open, st} <- expect_desc(st, 0x10, 3_000),
         :ok <-
           raw_send(
             st,
             frame(0x00, 0, described(0x11, [nil, uint(0), uint(1000), uint(1000)]))
           ),
         {:ok, _begin, st} <- expect_desc(st, 0x11, 3_000) do
      {:ok, st}
    end
  end

  # CBS receiver (handle 2, source "$cbs") — the broker answers put-token on
  # this link (find_reply_link: kind :cbs, broker role sender). Credit is
  # granted so the reply transfer flows.
  defp cbs_setup(st) do
    source = composite(0x28, [str8("$cbs"), nil, nil, nil, nil, nil, nil, nil])

    rx =
      described(0x12, [
        str8("popcorn-cbs-receiver"),
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
         :ok <- grant_credit(st, 2, 10),
         {:ok, st} <- attach_cbs_sender(st) do
      {:ok, st}
    end
  end

  defp attach_cbs_sender(st) do
    target = composite(0x29, [str8("$cbs"), nil, nil, nil, nil, nil, nil])

    tx =
      described(0x12, [
        str8("popcorn-cbs-sender"),
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

    with :ok <- raw_send(st, frame(0x00, 0, tx)),
         {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000) do
      {:ok, st}
    end
  end

  # Real put-token over $cbs: app-props operation/type/name, body = the SAS
  # token string; the reply's application-properties "status-code" must be 200.
  defp cbs_put_token(st, audience) do
    mid = "x3-cbs-#{System.system_time(:millisecond)}"

    props =
      described(0x73, [
        str8(mid),
        nil,
        str8("$cbs"),
        nil,
        nil,
        str8(mid)
      ])

    # application-properties (0x74) carries a MAP value, not a list
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

    xfer =
      described(0x14, [
        uint(3),
        uint(st.did),
        vbin8(:binary.copy(<<0>>, 16)),
        uint(0),
        bool(false)
      ])

    payload = [
      props,
      app_props,
      [<<0x00, 0x53, 0x75>>, enc_elem({:vbin8, sas_token(audience)})]
    ]

    with :ok <- raw_send(st, frame_with_payload(0x00, 0, xfer, payload)) do
      await_cbs_reply(st, audience, 20)
    end
  end

  defp await_cbs_reply(_st, _audience, 0), do: {:error, {"cbs", :no_put_token_reply}}

  defp await_cbs_reply(st, audience, budget) do
    case next_frame(st, 3_000) do
      {:ok, {:amqp, 0x14, _list, payload}, st} ->
        case cbs_status(payload) do
          200 ->
            {:ok, st}

          nil ->
            await_cbs_reply(st, audience, budget - 1)

          other ->
            {:error, {"cbs", "put-token-status-#{other}-for-#{slice(audience)}"}}
        end

      {:ok, {:amqp, d, _l, _p}, _st} when d in [0x16, 0x17, 0x18] ->
        {:error, {"cbs", {:broker_refused_frame_0x, d}}}

      {:ok, {:amqp, _other, _l, _p}, st} ->
        await_cbs_reply(st, audience, budget - 1)

      {:error, _} = err ->
        err
    end
  end

  # Parse the put-token reply's application-properties "status-code" (uint)
  # straight off the transfer payload: find the "status-code" symbol key
  # bytes, then its uint value right behind them.
  defp cbs_status(payload) do
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

  # Sender link (handle 0) at the bare topic entity (target composite, 7 fields).
  defp attach_sender(st, topic) do
    target = composite(0x29, [str8(topic), nil, nil, nil, nil, nil, nil])

    attach =
      described(0x12, [
        str8("popcorn-topic-sender"),
        uint(0),
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

  # Receiver link (handle 1) at the subscription address
  # "<topic>/Subscriptions/<sub>" (source composite, 8 fields). Attached
  # BEFORE the publish; no credit until after, so the drain sees exactly
  # this run's two messages.
  defp attach_receiver(st, topic) do
    source =
      composite(0x28, [str8("#{topic}/Subscriptions/#{@sub}"), nil, nil, nil, nil, nil, nil, nil])

    attach =
      described(0x12, [
        str8("popcorn-topic-receiver"),
        uint(1),
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

  # Publish exactly two uniquely-tagged messages; distinct byte payloads for
  # the byte-order assert. Each publish awaits its accepted disposition.
  defp publish_two(st) do
    ms = System.system_time(:millisecond)
    t1 = "x3-a-#{ms}-first"
    t2 = "x3-b-#{ms}-second"

    with {:ok, st} <- publish(st, t1),
         {:ok, st} <- publish(st, t2) do
      {:ok, st, t1, t2}
    end
  end

  defp publish(st, token) do
    did = st.did

    xfer =
      described(0x14, [
        uint(0),
        uint(did),
        vbin8(:binary.copy(<<0>>, 16)),
        uint(0),
        bool(false)
      ])

    # data section: descriptor 0x75, vbin8 body
    body = [<<0x00, 0x53, 0x75>>, <<0xA0, byte_size(token), token::binary>>]

    with :ok <- raw_send(st, frame_with_payload(0x00, 0, xfer, body)) do
      case expect_desc(st, 0x15, 5_000) do
        {:ok, list_bytes, st} ->
          if accepted?(list_bytes) do
            {:ok, %{st | did: did + 1}}
          else
            take = min(8, byte_size(list_bytes))
            {:error, {"disposition", {:not_accepted, binary_part(list_bytes, 0, take)}}}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  # Grant credit (handle 1) AFTER the publishes, then drain until both tokens
  # arrived IN PUBLISH ORDER. Each accepted transfer's broker delivery-id is
  # captured for settlement.
  defp credit_and_drain(st, [t1, _] = tokens) do
    with :ok <- grant_credit(st, 1, 2) do
      drain(st, t1, [], tokens, 50)
    end
  end

  # Flow field order follows the BROKER's decode order (FrameCodec
  # @field_orders flow: next_incoming_id, incoming_window, next_outgoing_id,
  # outgoing_window, handle, delivery_count, link_credit, available, drain,
  # echo, properties) — NOT the spec's next-outgoing-first order; the
  # non-standard order left link credit nil and receivers starved
  # (witnessed: drain timeout with zero deliveries).
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

  defp drain(_st, _expect, _got, _tokens, 0) do
    {:error, {"receive", :exhausted_budget_without_both_tokens}}
  end

  defp drain(st, expect, got, tokens, budget) do
    case next_frame(st, 3_000) do
      {:ok, {:amqp, 0x14, list_bytes, payload}, st} ->
        case body_data(payload) do
          ^expect ->
            got = got ++ [{transfer_delivery_id(list_bytes), expect}]

            case tokens -- Enum.map(got, &elem(&1, 1)) do
              [] -> {:ok, st, got}
              [next | _] -> drain(st, next, got, tokens, budget - 1)
            end

          _other ->
            drain(st, expect, got, tokens, budget - 1)
        end

      {:ok, {:amqp, d, _l, _p}, _st} when d in [0x16, 0x17, 0x18] ->
        {:error, {"receive", {:broker_refused_frame_0x, d}}}

      {:ok, {:amqp, _other_desc, _l, _p}, st} ->
        drain(st, expect, got, tokens, budget - 1)

      {:error, _} = err ->
        err
    end
  end

  # Settle every delivered transfer with an accepted disposition (receiver
  # role=true, settled, state accepted 0x24).
  defp settle_all(st, got) do
    Enum.reduce_while(got, {:ok, st}, fn {id, _token}, {:ok, st} ->
      disp =
        described(0x15, [
          bool(true),
          uint(id),
          uint(id),
          bool(true),
          described(0x24, [])
        ])

      case raw_send(st, frame(0x00, 0, disp)) do
        :ok -> {:cont, {:ok, st}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # After accepted settlement the subscription must be EMPTY: re-grant credit
  # and assert NO transfer arrives within a bounded quiet window.
  defp assert_drained(st) do
    with :ok <- grant_credit(st, 1, 10) do
      assert_drained_loop(st, 20)
    end
  end

  defp assert_drained_loop(_st, 0), do: {:error, {"settle", :chatty_without_quiet_window}}

  defp assert_drained_loop(st, budget) do
    case next_frame(st, 1_200) do
      {:ok, {:amqp, 0x14, _list, _payload}, _st} ->
        {:error, {"settle", :transfer_after_accept}}

      {:ok, {:amqp, _other, _l, _p}, st} ->
        assert_drained_loop(st, budget - 1)

      # recv timeout = quiet wire = drained
      {:error, {:recv, :timeout}} ->
        :ok

      {:error, _} = err ->
        err
    end
  end

  # -- minimal AMQP 1.0 codec (encode) ---------------------------------------

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
      # AMQP lists may omit trailing null fields (spec §1.4.3)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == <<0x40>>))
      |> Enum.reverse()

    n = length(body)
    payload = IO.iodata_length(body)
    # list8 size INCLUDES the count octet (spec §1.6.12)
    [<<0xC0, payload + 1, n>>, body]
  end

  defp enc_elem(nil), do: <<0x40>>
  defp enc_elem({:composite, desc, elems}), do: [<<0x00, 0x53, desc>>, encode_list(elems)]

  # pre-encoded iodata (e.g. a nested described() accepted disposition)
  defp enc_elem(x) when is_list(x), do: x

  # map8 (0xC1) for application-properties: size INCLUDES the count octet.
  # NOTE: the broker's PrimitiveCodec fails {:error, :truncated} on map32
  # (0xD1) at any size semantics (probed against Smalt.Amqp.PrimitiveCodec,
  # 2026-10-20) — map8 is the only decode-supported map form.
  defp enc_elem({:amqp_map, map}) when map_size(map) < 256 do
    pairs = Enum.flat_map(map, fn {k, v} -> [str8_enc(k), enc_elem(v)] end)
    payload = IO.iodata_length(pairs)
    [<<0xC1, payload + 1, map_size(map)>>, pairs]
  end

  defp enc_elem({:ubyte, v}), do: <<0x50, v>>
  defp enc_elem({:bool, v}), do: <<0x56, if(v, do: 1, else: 0)>>

  defp enc_elem({:vbin8, b}) when byte_size(b) < 256, do: <<0xA0, byte_size(b), b::binary>>
  defp enc_elem({:str8, s}) when byte_size(s) < 256, do: <<0xA1, byte_size(s), s::binary>>

  defp enc_elem({:uint, v}) when is_integer(v) and v >= 0 and v < 256, do: <<0x52, v>>

  defp enc_elem({:uint, v}) when is_integer(v) and v >= 256 and v <= 0xFFFFFFFF,
    do: <<0x70, v::32>>

  # raw binaries encode as str8 (app-props values)
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

  # -- minimal AMQP 1.0 codec (decode) ---------------------------------------

  defp accepted?(bytes) do
    :binary.match(bytes, <<0x00, 0x53, 0x24>>) != :nomatch
  end

  # Broker transfer performative field 1 = delivery-id: decode the FIRST TWO
  # top-level list elements (handle@0, delivery-id@1 — both uints) positionally.
  defp transfer_delivery_id(list_bytes) do
    {_handle, rest} = take_elem(list_bytes)
    {did, _rest} = take_elem(rest)
    decode_uint(did)
  end

  defp take_elem(<<0x40, r::binary>>), do: {nil, r}
  defp take_elem(<<0x43, r::binary>>), do: {0, r}
  defp take_elem(<<0x50, v, r::binary>>), do: {v, r}
  defp take_elem(<<0x52, v, r::binary>>), do: {v, r}
  defp take_elem(<<0x70, v::32, r::binary>>), do: {v, r}

  defp take_elem(<<0xA0, len, d::binary-size(len), r::binary>>), do: {d, r}
  defp take_elem(<<0xA1, len, d::binary-size(len), r::binary>>), do: {d, r}

  defp take_elem(<<0xC0, size, _count, d::binary-size(size - 1), r::binary>>), do: {d, r}

  # described type: 0x00 <descriptor> <value> — the value carries
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

  defp raw_send(st, iodata) do
    with(:ok <- :gen_tcp.send(st.sock, iodata), do: :ok)
  end

  defp expect_desc(st, desc, timeout, budget \\ 20)

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

  defp decode_buf(<<_size::32, _doff::8, _type::8, _chan::16, _::binary>>) do
    {:error, :bad_frame_type}
  end

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

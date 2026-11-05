defmodule Smalt.PubSubGrpc.Wire do
  @moduledoc """
  Pure protobuf wire codec for the Pub/Sub gRPC subset (lane K-GC,
  v26.11.6). No I/O, no processes: binaries in, terms or typed errors out.

  ## Messages (pubsub.proto subset, field numbers pinned)

      PubsubMessage{ data = 1 (bytes),
                     attributes = 2 (map<string,string>),
                     message_id = 3 (string),
                     publish_time = 4 (Timestamp{seconds = 1 int64, nanos = 2 int32}),
                     ordering_key = 5 (string) }
      PublishRequest{ topic = 1, messages = 2 (repeated PubsubMessage) }
      PublishResponse{ message_ids = 1 (repeated string, unpacked) }
      PullRequest{ subscription = 1, max_messages = 2, return_immediately = 3 }
      PullResponse{ received_messages = 1 (repeated ReceivedMessage) }
      ReceivedMessage{ ack_id = 1, message = 2 }
      AcknowledgeRequest{ subscription = 1, ack_ids = 2 }
      ModifyAckDeadlineRequest{ subscription = 1, ack_ids = 2, ack_deadline_seconds = 3 }

  ## Wire laws

    * Varints up to 64 bit; truncated or overlong (>10-byte) varint →
      `{:error, :bad_varint}` — the pinned typed truncation refusal
      (F-P4: malformed input answers a typed gRPC error, never silence).
    * Unknown fields are SKIPPED by wire type (varint / 64-bit /
      length-delimited / 32-bit), never a refusal — forward-compat law.
    * Map entries (PubsubMessage attributes, field 2): each entry is a
      length-delimited message with key = 1, value = 2 (both strings).
    * PublishResponse.message_ids is UNPACKED repeated (each element its
      own length-delimited field 1).
  """

  import Bitwise

  @wt_varint 0
  @wt_64 1
  @wt_len 2
  @wt_32 5

  @type decode_error :: {:error, :bad_varint}

  # ── varint / tag primitives ─────────────────────────────────────────

  @doc "Encodes an unsigned integer as a base-128 varint."
  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(n) when is_integer(n) and n >= 0 do
    do_encode_varint(n, [])
    |> IO.iodata_to_binary()
  end

  defp do_encode_varint(n, acc) when n < 0x80 do
    Enum.reverse([<<n::size(8)>> | acc])
    |> IO.iodata_to_binary()
  end

  defp do_encode_varint(n, acc) do
    do_encode_varint(n >>> 7, [<<0x80 + band(n, 0x7F)::size(8)>> | acc])
  end

  @doc """
  Decodes one varint from the front of `bin`. `{:ok, value, rest}` or
  `{:error, :bad_varint}` on truncation or >10-byte overlong form.
  """
  @spec decode_varint(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, :bad_varint}
  def decode_varint(bin) when is_binary(bin), do: dv(bin, 0, 0)

  defp dv(<<>>, _, _), do: {:error, :bad_varint}

  defp dv(<<byte, rest::binary>>, shift, acc) when byte < 0x80 do
    if shift >= 70 do
      {:error, :bad_varint}
    else
      {:ok, acc + bsl(byte, shift), rest}
    end
  end

  defp dv(<<byte, rest::binary>>, shift, acc) do
    if shift >= 63 do
      {:error, :bad_varint}
    else
      dv(rest, shift + 7, acc + bsl(band(byte, 0x7F), shift))
    end
  end

  # ── field-level iteration ───────────────────────────────────────────

  @doc """
  Splits a message body into `{field, wt, value}` triples in wire order.
  Length-delimited values come back as `{:len, binary}`, varints as
  `{:v, n}`, fixed32/64 as `{:raw, binary}`. Unknown fields are skipped at
  the message-decoder level (each decoder simply ignores unknown field
  numbers). Truncation anywhere is `{:error, :bad_varint}`.
  """
  @spec split_fields(binary()) ::
          {:ok,
           [{non_neg_integer(), non_neg_integer(),
             {:len, binary()} | {:v, non_neg_integer()} | {:raw, binary()}}]}
          | {:error, :bad_varint}
  def split_fields(bin) when is_binary(bin), do: sf(bin, [])

  defp sf(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp sf(bin, acc) do
    with {:ok, tag, rest} <- decode_varint(bin),
         field = tag >>> 3,
         wt = band(tag, 7),
         {:ok, val, rest2} <- read_value(rest, wt) do
      sf(rest2, [{field, wt, val} | acc])
    end
  end

  defp read_value(bin, @wt_varint) do
    case decode_varint(bin) do
      {:ok, v, rest} -> {:ok, {:v, v}, rest}
      err -> err
    end
  end

  defp read_value(bin, @wt_64) do
    case bin do
      <<v::binary-size(8), rest::binary>> -> {:ok, {:raw, v}, rest}
      _ -> {:error, :bad_varint}
    end
  end

  defp read_value(bin, @wt_len) do
    with {:ok, len, rest} <- decode_varint(bin),
         <<val::binary-size(len), rest2::binary>> <- rest do
      {:ok, {:len, val}, rest2}
    else
      _ -> {:error, :bad_varint}
    end
  end

  defp read_value(bin, @wt_32) do
    case bin do
      <<v::binary-size(4), rest::binary>> -> {:ok, {:raw, v}, rest}
      _ -> {:error, :bad_varint}
    end
  end

  defp read_value(_, _), do: {:error, :bad_varint}

  # ── generic encode helpers ──────────────────────────────────────────

  @doc "Length-delimited field: tag + varint length + bytes."
  @spec enc_len(non_neg_integer(), binary()) :: binary()
  def enc_len(field, val) when is_binary(val) do
    <<encode_varint((field <<< 3) + @wt_len)::binary, encode_varint(byte_size(val))::binary,
      val::binary>>
  end

  @doc "Varint field, omitted when 0 (proto3 default)."
  @spec enc_varint(non_neg_integer(), non_neg_integer()) :: binary()
  def enc_varint(_field, 0), do: <<>>

  def enc_varint(field, n) when is_integer(n) and n >= 0 do
    <<encode_varint((field <<< 3) + @wt_varint)::binary, encode_varint(n)::binary>>
  end

  # ── PubsubMessage ───────────────────────────────────────────────────

  @doc "Encodes a `PubsubMessage` map (data/attributes/message_id/publish_time/ordering_key)."
  @spec encode_pubsub_message(map()) :: binary()
  def encode_pubsub_message(m) do
    [
      enc_len(1, m[:data] || <<>>),
      encode_attributes(m[:attributes] || %{}),
      opt_len(3, m[:message_id]),
      opt_len(4, ts_bin(m[:publish_time])),
      opt_len(5, m[:ordering_key])
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Decodes a `PubsubMessage`. `{:ok, map, rest}` or `{:error, :bad_varint}`."
  @spec decode_pubsub_message(binary()) :: {:ok, map(), binary()} | {:error, :bad_varint}
  def decode_pubsub_message(bin) when is_binary(bin) do
    case split_fields(bin) do
      {:ok, fields} ->
        msg =
          Enum.reduce(fields, %{data: <<>>, attributes: %{}}, fn
            {1, @wt_len, {:len, v}}, m -> Map.put(m, :data, v)
            {2, @wt_len, {:len, entry}}, m -> Map.update!(m, :attributes, &attr_entry(&1, entry))
            {3, @wt_len, {:len, v}}, m -> Map.put(m, :message_id, v)
            {4, @wt_len, {:len, v}}, m -> Map.put(m, :publish_time, ts(v))
            {5, @wt_len, {:len, v}}, m -> Map.put(m, :ordering_key, v)
            _unknown, m -> m
          end)

        {:ok, msg, <<>>}

      err ->
        err
    end
  end

  defp attr_entry(attrs, entry) do
    case split_fields(entry) do
      {:ok, fields} ->
        {k, v} =
          Enum.reduce(fields, {nil, ""}, fn
            {1, @wt_len, {:len, key}}, _acc -> {key, ""}
            {2, @wt_len, {:len, val}}, {key, _} -> {key, val}
            _f, acc -> acc
          end)

        Map.put(attrs, k || "", v)

      _ ->
        attrs
    end
  end

  defp encode_attributes(attrs) when is_map(attrs) do
    attrs
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> enc_len(2, enc_len(1, k) <> enc_len(2, v)) end)
    |> IO.iodata_to_binary()
  end

  defp opt_len(_field, nil), do: <<>>
  defp opt_len(field, bin) when is_binary(bin), do: enc_len(field, bin)

  defp ts_bin({secs, nanos}) when is_integer(secs) and is_integer(nanos),
    do: <<enc_varint(1, max(secs, 0))::binary, enc_varint(2, max(nanos, 0))::binary>>

  defp ts_bin(nil), do: nil

  defp ts(bin) do
    case split_fields(bin) do
      {:ok, fields} ->
        Enum.reduce(fields, {0, 0}, fn
          {1, @wt_varint, {:v, v}}, _ -> {v, 0}
          {2, @wt_varint, {:v, v}}, {s, _} -> {s, v}
          _, acc -> acc
        end)

      _ ->
        nil
    end
  end

  # ── request / response envelopes ────────────────────────────────────

  @doc "Encodes `PublishRequest{topic = 1, messages = 2}`."
  @spec encode_publish_request(String.t(), [map()]) :: binary()
  def encode_publish_request(topic, messages) do
    [
      enc_len(1, topic),
      messages |> Enum.map(&enc_len(2, encode_pubsub_message(&1))) |> IO.iodata_to_binary()
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Decodes `PublishRequest`. `{:ok, %{topic, messages}, rest}`."
  @spec decode_publish_request(binary()) :: {:ok, map(), binary()} | {:error, :bad_varint}
  def decode_publish_request(bin) do
    case split_fields(bin) do
      {:ok, fields} ->
        req =
          Enum.reduce(fields, %{topic: "", messages: []}, fn
            {1, @wt_len, {:len, v}}, m -> Map.put(m, :topic, v)
            {2, @wt_len, {:len, v}}, m ->
              case decode_pubsub_message(v) do
                {:ok, msg, _} -> Map.update!(m, :messages, &(&1 ++ [msg]))
                _ -> m
              end

            _, m -> m
          end)

        {:ok, req, <<>>}

      err ->
        err
    end
  end

  @doc "Encodes `PublishResponse{message_ids = 1}` (unpacked repeated)."
  @spec encode_publish_response([String.t()]) :: binary()
  def encode_publish_response(ids) do
    ids |> Enum.map(&enc_len(1, &1)) |> IO.iodata_to_binary()
  end

  @doc "Decodes `PublishResponse` into the id list."
  @spec decode_publish_response(binary()) :: {:ok, [String.t()]} | {:error, :bad_varint}
  def decode_publish_response(bin) do
    case split_fields(bin) do
      {:ok, fields} -> {:ok, for({1, @wt_len, {:len, v}} <- fields, do: v)}
      err -> err
    end
  end

  @doc "Encodes `PullRequest{subscription = 1, max_messages = 2, return_immediately = 3}`."
  @spec encode_pull_request(String.t(), non_neg_integer(), boolean()) :: binary()
  def encode_pull_request(sub, max_messages, return_immediately \\ false) do
    [
      enc_len(1, sub),
      enc_varint(2, max_messages),
      if(return_immediately, do: enc_varint(3, 1), else: <<>>)
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Decodes `PullRequest` into `%{subscription, max_messages, return_immediately}`."
  @spec decode_pull_request(binary()) :: {:ok, map()} | {:error, :bad_varint}
  def decode_pull_request(bin) do
    case split_fields(bin) do
      {:ok, fields} ->
        {:ok,
         Enum.reduce(fields, %{subscription: "", max_messages: 0, return_immediately: false}, fn
           {1, @wt_len, {:len, v}}, m -> Map.put(m, :subscription, v)
           {2, @wt_varint, {:v, v}}, m -> Map.put(m, :max_messages, v)
           {3, @wt_varint, {:v, n}}, m when n != 0 -> Map.put(m, :return_immediately, true)
           _, m -> m
         end)}

      err ->
        err
    end
  end

  @doc "Encodes `PullResponse{received_messages = 1}`."
  @spec encode_pull_response([map()]) :: binary()
  def encode_pull_response(received) do
    received
    |> Enum.map(fn %{ack_id: ack_id, message: msg} ->
      enc_len(1, enc_len(1, ack_id) <> enc_len(2, encode_pubsub_message(msg)))
    end)
    |> IO.iodata_to_binary()
  end

  @doc "Decodes `PullResponse` into `[%{ack_id, message}]`."
  @spec decode_pull_response(binary()) :: {:ok, [map()]} | {:error, :bad_varint}
  def decode_pull_response(bin) do
    case split_fields(bin) do
      {:ok, fields} ->
        received =
          for {1, @wt_len, {:len, v}} <- fields,
              {:ok, inner} <- [split_fields(v)] do
            Enum.reduce(inner, %{ack_id: nil, message: nil}, fn
              {1, @wt_len, {:len, av}}, m -> Map.put(m, :ack_id, av)
              {2, @wt_len, {:len, mv}}, m ->
                case decode_pubsub_message(mv) do
                  {:ok, msg, _} -> Map.put(m, :message, msg)
                  _ -> m
                end

              _, m -> m
            end)
          end

        {:ok, received}

      err ->
        err
    end
  end

  @doc "Encodes `AcknowledgeRequest{subscription = 1, ack_ids = 2}`."
  @spec encode_acknowledge_request(String.t(), [String.t()]) :: binary()
  def encode_acknowledge_request(sub, ack_ids) do
    ids = ack_ids |> Enum.map(&enc_len(2, &1)) |> IO.iodata_to_binary()
    <<enc_len(1, sub)::binary, ids::binary>>
  end

  @doc "Decodes `AcknowledgeRequest` into `%{subscription, ack_ids}`."
  @spec decode_acknowledge_request(binary()) :: {:ok, map()} | {:error, :bad_varint}
  def decode_acknowledge_request(bin) do
    sub_ack_decode(bin, %{})
  end

  @doc "Encodes `ModifyAckDeadlineRequest{subscription = 1, ack_ids = 2, ack_deadline_seconds = 3}`."
  @spec encode_modify_ack_deadline_request(String.t(), [String.t()], non_neg_integer()) :: binary()
  def encode_modify_ack_deadline_request(sub, ack_ids, deadline) do
    ids = ack_ids |> Enum.map(&enc_len(2, &1)) |> IO.iodata_to_binary()
    <<enc_len(1, sub)::binary, ids::binary, enc_varint(3, deadline)::binary>>
  end

  @doc "Decodes `ModifyAckDeadlineRequest` into `%{subscription, ack_ids, ack_deadline_seconds}`."
  @spec decode_modify_ack_deadline_request(binary()) :: {:ok, map()} | {:error, :bad_varint}
  def decode_modify_ack_deadline_request(bin) do
    sub_ack_decode(bin, %{ack_deadline_seconds: 0})
  end

  defp sub_ack_decode(bin, extra) do
    case split_fields(bin) do
      {:ok, fields} ->
        base = Map.merge(%{subscription: "", ack_ids: []}, extra)

        {:ok,
         Enum.reduce(fields, base, fn
           {1, @wt_len, {:len, v}}, m -> Map.put(m, :subscription, v)
           {2, @wt_len, {:len, v}}, m -> Map.update!(m, :ack_ids, &(&1 ++ [v]))
           {3, @wt_varint, {:v, v}}, m -> Map.put(m, :ack_deadline_seconds, v)
           _, m -> m
         end)}

      err ->
        err
    end
  end

  # ── topic / subscription admin shapes ──────────────────────────────

  # Topic{name = 1}; Subscription{name = 1, topic = 2}.
  @doc "Decodes a TopicRequest/GetSubscriptionRequest (field 1 = resource name)."
  @spec decode_topic_request(binary()) :: {:ok, map()} | {:error, :bad_varint}
  def decode_topic_request(bin) do
    case split_fields(bin) do
      {:ok, fields} ->
        name =
          Enum.find_value(fields, fn
            {1, @wt_len, {:len, v}} -> v
            _ -> nil
          end) || ""

        {:ok, %{topic: name}}

      err ->
        err
    end
  end

  @doc "Encodes `Topic{name = 1}`."
  @spec encode_topic(map()) :: binary()
  def encode_topic(%{name: name}) do
    enc_len(1, name)
  end

  @doc "Encodes `Subscription{name = 1, topic = 2}`."
  @spec encode_subscription(map()) :: binary()
  def encode_subscription(%{name: name, topic: topic}) do
    <<enc_len(1, name)::binary, enc_len(2, topic)::binary>>
  end
end

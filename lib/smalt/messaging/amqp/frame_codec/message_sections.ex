defmodule Smalt.Amqp.FrameCodec.MessageSections do
  @moduledoc """
  AMQP 1.0 message sections (transfer payload) codec — extracted verbatim from
  `Smalt.Amqp.FrameCodec` along the `# --- Message sections` fence (T10 tail
  split, v26.10.29 r10d). STRUCTURAL ONLY: every encoded/decoded byte is
  unchanged; the wire-pinned descriptors and field orders moved with the code,
  and the runtime-configurable primitive codec stays the parent's
  (`FrameCodec.codec/0`, widened defp->def, no behavior change).
  """

  alias Smalt.Amqp.FrameCodec

  @message_section_descriptors %{
    header: 0x0000_0000_0000_0070,
    delivery_annotations: 0x0000_0000_0000_0071,
    message_annotations: 0x0000_0000_0000_0072,
    properties: 0x0000_0000_0000_0073,
    application_properties: 0x0000_0000_0000_0074,
    body_data: 0x0000_0000_0000_0075,
    body_sequence: 0x0000_0000_0000_0076,
    body_amqp_value: 0x0000_0000_0000_0077,
    footer: 0x0000_0000_0000_0078
  }

  # Primitive codec is configurable for tests until the real
  # Smalt.Amqp.PrimitiveCodec lands (pinned API: encode/1, decode/1, decode_all/1).
  defp codec, do: Application.get_env(:smalt, :primitive_codec, Smalt.Amqp.PrimitiveCodec)

  @properties_order [
    :message_id,
    :user_id,
    :to,
    :subject,
    :reply_to,
    :correlation_id,
    :content_type,
    :content_encoding,
    :expiry,
    :creation_time,
    :group_id,
    :group_sequence,
    :reply_to_group_id
  ]

  # AMQP 1.0 §3.2.1 header field order: durable, priority, ttl,
  # first-acquirer, delivery-count. The previous order led with
  # delivery_count, so clients read it as `durable` and every received
  # message's deliveryCount was undefined (census abandon-complete probe:
  # ABANDON_REDELIVERY_COUNT).
  @header_order [:durable, :priority, :ttl, :first_acquirer, :delivery_count]

  # ---------------------------------------------------------------------------
  # Message sections (transfer payload)
  # ---------------------------------------------------------------------------

  @doc """
  Encodes a message as a sequence of AMQP sections (iodata).

  Sections (in order):

    * `{:header, %{delivery_count:, ttl:, durable:, priority:, first_acquirer:}}`
    * `{:delivery_annotations, map}`
    * `{:message_annotations, map}` (keys may be `"x-opt-..."` strings/symbols)
    * `{:properties, %{message_id:, correlation_id:, reply_to:, subject:, to:, content_type:, creation_time:, ...}}`
    * `{:application_properties, map}`
    * `{:body_data, binary}` | `{:body_sequence, [term]}` | `{:body_amqp_value, term}`
    * `{:footer, map}`

  Missing keys in `header`/`properties` maps are encoded as null.
  """
  @spec encode_message([tuple()]) :: iodata()
  def encode_message(sections) when is_list(sections) do
    Enum.map(sections, &encode_section/1)
  end

  defp encode_section({:header, %{} = map}) do
    described(@message_section_descriptors.header, Enum.map(@header_order, &Map.get(map, &1)))
  end

  defp encode_section({:properties, %{} = map}) do
    described(
      @message_section_descriptors.properties,
      Enum.map(@properties_order, &Map.get(map, &1))
    )
  end

  defp encode_section({:delivery_annotations, map}), do: map_section(:delivery_annotations, map)
  defp encode_section({:message_annotations, map}), do: map_section(:message_annotations, map)

  defp encode_section({:application_properties, map}),
    do: map_section(:application_properties, map)

  defp encode_section({:footer, map}), do: map_section(:footer, map)

  defp encode_section({:body_data, data}) when is_binary(data) do
    # spec: data section body is a vbin (0xA0/0xB0) — the binary itself with a
    # binary constructor; str8 (0xA1) makes rhea unwrap to a JS string and
    # binary bodies >= 0x80 come back UTF-8-mangled (census bytes probe)
    described(@message_section_descriptors.body_data, {:vbin, data})
  end

  defp encode_section({:body_sequence, values}) when is_list(values) do
    described(@message_section_descriptors.body_sequence, values)
  end

  defp encode_section({:body_amqp_value, value}) do
    # spec: amqp-value section body is the value itself, not a 1-element list
    # (wire-lane fix: rhea sends the unwrapped form)
    described(@message_section_descriptors.body_amqp_value, value)
  end

  defp map_section(kind, map) do
    # spec: annotation/property section bodies carry the map directly, not a
    # 1-element list (wire-lane fix, real-SDK census finding)
    described(Map.fetch!(@message_section_descriptors, kind), map)
  end

  defp described(desc, values) do
    FrameCodec.codec().encode({:described, desc, values})
  end

  @doc """
  Decodes a transfer payload binary into an ordered list of decoded sections:

      {:header, map} | {:delivery_annotations, term} | {:message_annotations, term}
      | {:properties, map} | {:application_properties, term}
      | {:body_data, binary} | {:body_sequence, list} | {:body_amqp_value, term}
      | {:footer, term}
  """
  @spec decode_message(binary()) :: {:ok, [tuple()]} | {:error, term()}
  def decode_message(payload) when is_binary(payload) do
    case do_decode_sections(payload, []) do
      {:ok, sections} -> {:ok, Enum.reverse(sections)}
      {:error, _} = err -> err
    end
  end

  defp do_decode_sections(<<>>, acc), do: {:ok, acc}

  defp do_decode_sections(payload, acc) do
    case FrameCodec.codec().decode(payload) do
      {:ok, {:described, desc, body}, rest} ->
        case decode_section(desc, body) do
          {:ok, section} ->
            do_decode_sections(rest, [section | acc])

          # Known descriptor with a malformed body (e.g. a header section
          # whose body is not a field list): surface the reason instead of
          # crashing — Enum.at/2 on a non-list raised out of decode_message
          # and killed the connection process (lens-2 cross-layer probe).
          {:error, reason} ->
            {:error, {:bad_section, reason}}
        end

      {:ok, _other, _} ->
        # Undecorated trailing bytes (should not happen): stop.
        {:ok, acc}

      :error ->
        {:ok, acc}

      # Undecodable section bytes: surface the codec reason instead of
      # silently returning a partial section list that reads as a short
      # message (parity with the cycle-4 frame-body reason preservation;
      # callers already match {:error, _} — connection.ex:846).
      {:error, reason} ->
        {:error, {:bad_section, reason}}
    end
  end

  # Section dispatch returns {:ok, section} | {:error, reason} — it must never
  # raise on remote input (lens-2 cross-layer invariant: anything that decodes
  # cleanly at the primitive level decodes to a tagged result here).
  defp decode_section(desc, body) when is_integer(desc) do
    case desc do
      d when d == @message_section_descriptors.header ->
        if is_list(body) do
          {:ok,
           {:header,
            @header_order
            |> Enum.with_index()
            |> Map.new(fn {k, i} -> {k, Enum.at(body, i)} end)
            |> Map.reject(fn {_k, v} -> is_nil(v) end)}}
        else
          {:error, :malformed_header}
        end

      d when d == @message_section_descriptors.properties ->
        if is_list(body) do
          props =
            @properties_order
            |> Enum.with_index()
            |> Map.new(fn {k, i} -> {k, Enum.at(body, i)} end)
            |> Map.reject(fn {_k, v} -> is_nil(v) end)

          {:ok, {:properties, props}}
        else
          {:error, :malformed_properties}
        end

      d when d == @message_section_descriptors.body_data ->
        # Section body types are enforced: body_data is a vbin (binary) on the
        # wire — a crafted described(0x75, 42) decoded "successfully" and later
        # crashed encode_section (is_binary guard) on the management replay
        # path, inside the connection process (lens-2 cycle-3 seam).
        if is_binary(body), do: {:ok, {:body_data, body}}, else: {:error, :malformed_body_data}

      d when d == @message_section_descriptors.body_sequence ->
        if is_list(body) or is_nil(body),
          do: {:ok, {:body_sequence, body || []}},
          else: {:error, :malformed_body_sequence}

      # the described body carries the value directly (rhea interop form)
      d when d == @message_section_descriptors.body_amqp_value ->
        {:ok, {:body_amqp_value, body}}

      d when d == @message_section_descriptors.delivery_annotations ->
        {:ok, {:delivery_annotations, normalize_keys(map_or(body, %{}))}}

      d when d == @message_section_descriptors.message_annotations ->
        {:ok, {:message_annotations, normalize_keys(map_or(body, %{}))}}

      d when d == @message_section_descriptors.application_properties ->
        {:ok, {:application_properties, normalize_keys(map_or(body, %{}))}}

      d when d == @message_section_descriptors.footer ->
        {:ok, {:footer, normalize_keys(map_or(body, %{}))}}

      _ ->
        {:ok, {:unknown, desc, body}}
    end
  end

  # Symbolic descriptors are legal AMQP described types but not defined
  # message sections: pass through as unknown instead of raising a
  # FunctionClauseError out of decode_message (lens-2 cross-layer probe).
  defp decode_section(desc, body), do: {:ok, {:unknown, desc, body}}

  # annotation/property sections decode to a map body (rhea form); accept the
  # legacy 1-element-list form too (wire-lane fix, real-SDK census finding)
  defp map_or(%{} = m, _default), do: m
  defp map_or([%{} = m], _default), do: m
  defp map_or(_, default), do: default

  # Annotation/application-property maps arrive from the codec with
  # `{:symbol, name}` keys; surface them as plain string keys (other key
  # types, e.g. ulong keys, pass through untouched).
  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {{:symbol, k}, v} -> {k, v}
      kv -> kv
    end)
  end

  defp normalize_keys(other), do: other
end

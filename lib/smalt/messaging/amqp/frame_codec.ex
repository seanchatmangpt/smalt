defmodule Smalt.Amqp.FrameCodec do
  @moduledoc """
  AMQP 1.0 frame layer: 8-byte frame header + performative encode/decode,
  plus message-section (transfer payload) encoding/decoding.

  ## Frame wire format

      size::32 | doff::8 | type::8 | channel::16 | body...

  `doff` is the header length in 4-byte words (standard header = 8 bytes, so
  `doff = 2`). Frame types: `0x00` AMQP, `0x01` SASL.

  ## Primitive codec contract (pinned, `Smalt.Amqp.PrimitiveCodec`)

  This module calls `encode/1`, `decode/1 -> {:ok, term, rest}` and
  `decode_all/1` on `Smalt.Amqp.PrimitiveCodec` (overridable at runtime via
  `Application.put_env(:smalt, :primitive_codec, mod)` — used by tests until
  the real module lands). Terms are:

    * `nil`, `true`, `false`, integers, binaries (and bitstrings), strings
    * `{:symbol, binary}`
    * `{:timestamp, milliseconds}` (AMQP timestamp, ms since epoch)
    * lists, maps (string or `{:symbol, _}` keys)
    * `{:described, descriptor, body}` where descriptor is an integer ulong
      or `{:symbol, binary}`; decodes back to the same shape

  ## API

      encode_frame(type, channel, performative_or_sections) -> iodata
      decode_frame(buffer) ->
        {:ok, %{type: :amqp | :sasl, channel: ch, performative: map, payload: binary}}
        | {:more, needed_bytes}
        | {:error, reason}

  `performative` is `%{performative: :open | :begin | ... , <named fields>}`.
  For transfer frames the `payload` binary carries the message sections (see
  `encode_message/1` / `decode_message/1`). Frame-splitting across TCP chunks
  is handled by returning `{:more, total_frame_size}` until the full frame is
  buffered.
  """

  @max_frame_size 1 * 1024 * 1024 + 512
  @header_size 8

  @type frame_type :: :amqp | :sasl

  @type_code_amqp 0x00
  @type_code_sasl 0x01

  @performative_descriptors %{
    open: 0x0000_0000_0000_0010,
    begin: 0x0000_0000_0000_0011,
    attach: 0x0000_0000_0000_0012,
    flow: 0x0000_0000_0000_0013,
    transfer: 0x0000_0000_0000_0014,
    disposition: 0x0000_0000_0000_0015,
    detach: 0x0000_0000_0000_0016,
    end: 0x0000_0000_0000_0017,
    close: 0x0000_0000_0000_0018,
    sasl_mechanisms: 0x0000_0000_0000_0040,
    sasl_init: 0x0000_0000_0000_0041,
    sasl_challenge: 0x0000_0000_0000_0042,
    sasl_response: 0x0000_0000_0000_0043,
    # sasl-outcome is 0x44 (wire-lane fix: real-SDK census showed the earlier
    # 0x42 got dispatched as a challenge by rhea)
    sasl_outcome: 0x0000_0000_0000_0044
  }

  @performative_names Map.keys(@performative_descriptors)

  # Spec §2.3/§5: SASL frames (type 0x01) carry only SASL performatives; AMQP
  # frames (type 0x00) carry only the session/link performatives. The layers
  # are negotiated independently (start SASL, toggle to AMQP), so a mismatch
  # is a protocol violation, not a tolerant case.
  @sasl_performatives [:sasl_mechanisms, :sasl_init, :sasl_challenge, :sasl_response, :sasl_outcome]

  # Field orders per AMQP 1.0 performative definitions (nil = null filler).
  @field_orders %{
    open: [
      :container_id,
      :hostname,
      :max_frame_size,
      :channel_max,
      :idle_time_out,
      :outgoing_locales,
      :incoming_locales,
      :offered_capabilities,
      :desired_capabilities,
      :properties
    ],
    begin: [:remote_channel, :next_outgoing_id, :incoming_window, :outgoing_window, :handle_max],
    attach: [
      :name,
      :handle,
      :role,
      :snd_settle_mode,
      :rcv_settle_mode,
      :source,
      :target,
      :unsettled,
      :incomplete_unsettled,
      :initial_delivery_count,
      :max_message_size,
      # NO outgoing_locales/incoming_locales here: those are `open` fields.
      # Including them made every attach reply a 16-element list; the AMQP
      # attach composite has 14 fields, and pyamqp reconstructs
      # AttachFrame(*frame) positionally -> "takes 15 positional arguments
      # but 17 were given" and the whole SDK handler crashed (py-court lane
      # 91 wire evidence, 2026-10-14).
      :offered_capabilities,
      :desired_capabilities,
      :properties
    ],
    flow: [
      :next_incoming_id,
      :incoming_window,
      :next_outgoing_id,
      :outgoing_window,
      :handle,
      :delivery_count,
      :link_credit,
      :available,
      :drain,
      :echo,
      :properties
    ],
    transfer: [
      :handle,
      :delivery_id,
      :delivery_tag,
      :message_format,
      :settled,
      :more,
      :rcv_settle_mode,
      :state
    ],
    disposition: [:role, :first, :last, :settled, :state, :batchable],
    detach: [:handle, :closed, :error],
    end: [:error],
    close: [:error],
    sasl_mechanisms: [:server_mechanisms],
    sasl_init: [:mechanism, :initial_response, :hostname],
    sasl_outcome: [:code, :additional_data],
    sasl_challenge: [:challenge],
    sasl_response: [:response]
  }

  @delivery_state_descriptors %{
    accepted: 0x0000_0000_0000_0024,
    rejected: 0x0000_0000_0000_0025,
    released: 0x0000_0000_0000_0026,
    modified: 0x0000_0000_0000_0027
  }

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

  @doc """
  Encodes a full frame as iodata.

  `type` is `:amqp` or `:sasl`. The performative argument is one of:

    * `{perf_name, fields_map}` — e.g. `{:open, %{container_id: "id"}}`
    * `{:transfer, fields_map, payload_iodata}` — payload appended raw after
      the performative
    * `{:transfer, fields_map, {:sections, section_list}}` — payload built by
      `encode_message/1`

  Fields absent from `fields_map` (or `nil`) are encoded as AMQP null.

  ## Outbound encode contract (raises)

  `encode_frame/3` and `encode_message/1` raise `ArgumentError` on values the
  AMQP type system cannot represent (structs, functions, refs, atoms other
  than booleans; heterogeneous `{:array, _}` elements) — the raise happens in
  the CALLER's process before any byte reaches the socket. Inbound decode is
  total (tagged errors, never raises); outbound encode is a programming-error
  contract: a tagged-error encode path is a cross-lane contract change
  (callers in connection.ex/listener.ex) and needs the connection lane's
  consent.
  """
  @spec encode_frame(frame_type(), non_neg_integer(), term()) :: iodata()
  def encode_frame(type, channel, {perf, fields})
      when perf in @performative_names and is_map(fields) and type in [:amqp, :sasl] and
             channel in 0..65_535 do
    body = encode_performative(perf, fields)
    wrap_frame(type, channel, body)
  end

  def encode_frame(type, channel, {:transfer, fields, {:sections, sections}})
      when is_map(fields) and type in [:amqp, :sasl] and channel in 0..65_535 do
    encode_frame(type, channel, {:transfer, fields, encode_message(sections)})
  end

  def encode_frame(type, channel, {:transfer, fields, payload})
      when is_map(fields) and type in [:amqp, :sasl] and channel in 0..65_535 do
    body = [encode_performative(:transfer, fields) | payload]
    wrap_frame(type, channel, body)
  end

  defp wrap_frame(type, channel, body) do
    body_bytes = IO.iodata_length(body)
    size = @header_size + body_bytes
    doff = div(@header_size, 4)
    type_code = if type == :amqp, do: @type_code_amqp, else: @type_code_sasl

    [
      <<size::32, doff::8, type_code::8, channel::16>>,
      body
    ]
  end

  defp encode_performative(perf, fields) do
    desc = Map.fetch!(@performative_descriptors, perf)
    order = Map.fetch!(@field_orders, perf)
    fields = prepare_fields(perf, fields)
    list = order |> Enum.map(&normalize_field(Map.get(fields, &1))) |> trim_trailing_nulls()
    codec().encode({:described, desc, list})
  end

  # Per-performative preprocessing of friendly field values into codec terms.

  # AMQP lists may omit trailing null fields (spec §1.4.3). Emitting them
  # inflates the positional arity for strict clients: pyamqp decodes lists
  # with the wire element count and reconstructs performatives as
  # `NamedTuple(*frame)`, so a padded attach crashed the SDK handler
  # (TypeError 17-vs-15). Trailing nulls are dropped before encoding.
  defp trim_trailing_nulls(list), do: Enum.reverse(list) |> Enum.drop_while(&is_nil/1) |> Enum.reverse()

  defp prepare_fields(:attach, fields) do
    fields
    |> Map.update(:source, nil, &encode_source_target(&1, :source))
    |> Map.update(:target, nil, &encode_source_target(&1, :target))
    |> Map.update(:properties, nil, fn
      nil -> nil
      %{} = m -> {:map_rhea, m}
      other -> other
    end)
  end

  defp prepare_fields(:transfer, fields) do
    # The delivery-tag IS the lock token: Service Bus SDKs derive
    # lockToken via rhea uuid_to_string(tag), which needs a 16-byte Buffer.
    # A plain Elixir binary encodes as utf8-string (0xA1); rhea then hands the
    # SDK a JS string (invalid bytes -> U+FFFD) and the token the client
    # echoes back on update-disposition is corrupted -> 410 MESSAGE_LOCK_LOST
    # (census exclusive-session/dead-letter/abandon probes, wire-traced).
    # Encode as AMQP uuid (0x98) — rhea decodes it to a Buffer.
    Map.update(fields, :delivery_tag, nil, fn
      <<t::binary-size(16)>> -> {:uuid, t}
      other -> other
    end)
  end

  defp prepare_fields(_perf, fields), do: fields

  defp encode_source_target(nil, _role), do: nil

  # Source/target composites are LIST-encoded (positional fields), not maps.
  # The previous map form produced an AMQP map constructor that rhea/SDK
  # cannot read back as a source (s5_sessions e2e lane finding).
  # The descriptor is chosen by ROLE (source 0x28, target 0x29), never by
  # filter presence: a filter-less SOURCE is still a source (C5 GAP R6).
  defp encode_source_target(map, role) when is_map(map) and role in [:source, :target] do
    source_or_target(map, role)
  end

  defp source_or_target(map, role) do
    filter =
      case Map.get(map, :filter) do
        {:map_rhea, _} = f ->
          f

        nil ->
          nil

        %{} = filters ->
          Map.new(filters, fn
            {k, {:session_filter, selector}} ->
              {k, {:described, {:symbol, "com.microsoft:session-filter"}, selector}}

            {k, v} ->
              {k, v}
          end)
      end

    descriptor = if role == :source, do: 0x0000_0028, else: 0x0000_0029

    {:described, descriptor,
     [
       # AMQP source/target composites: address0, durable1, expiry-policy2,
       # timeout3, dynamic4, dynamic-node-properties5, distribution-mode6,
       # filter7. The earlier 7-element form put the filter in the
       # distribution-mode slot, so rhea/SDK read filter=undefined.
       Map.get(map, :address),
       Map.get(map, :durable),
       Map.get(map, :expiry),
       Map.get(map, :timeout),
       Map.get(map, :dynamic),
       Map.get(map, :dynamic_node_properties),
       Map.get(map, :distribution_mode),
       filter
     ]}
  end

  defp normalize_field({:map_rhea, _} = v), do: v
  defp normalize_field(%{__struct__: _} = v), do: v

  # Error maps (detach/end/close/rejected) encode as the AMQP error list
  # [condition(symbol), description, info].
  defp normalize_field(%{} = error) when is_map_key(error, :condition) or is_map_key(error, "condition"),
    do: [sym(Map.get(error, :condition) || Map.get(error, "condition")),
         Map.get(error, :description) || Map.get(error, "description"),
         Map.get(error, :info) || Map.get(error, "info")]

  defp normalize_field({:rejected, error}), do: {:described, state_desc(:rejected), encode_error_list(error)}
  defp normalize_field({:modified, opts}), do: {:described, state_desc(:modified), encode_modified_list(opts)}
  defp normalize_field(:accepted), do: {:described, state_desc(:accepted), []}
  defp normalize_field(:released), do: {:described, state_desc(:released), []}
  defp normalize_field({:session_filter, selector}),
    do: {:described, {:symbol, "com.microsoft:session-filter"}, selector}
  defp normalize_field(v), do: v

  defp state_desc(name), do: Map.fetch!(@delivery_state_descriptors, name)

  defp encode_error_list(nil), do: []

  defp encode_error_list(%{} = error) do
    [
      sym(Map.get(error, :condition)),
      to_string_or_nil(Map.get(error, :description)),
      Map.get(error, :info)
    ]
  end

  defp encode_error_list(other), do: [other, nil, nil]

  defp encode_modified_list(nil), do: [nil, nil, nil]

  defp encode_modified_list(opts) do
    [
      Map.get(opts, :delivery_failed),
      Map.get(opts, :undeliverable_here),
      Map.get(opts, :annotations)
    ]
  end

  defp sym({:symbol, _} = s), do: s
  defp sym(nil), do: nil
  defp sym(s) when is_binary(s), do: {:symbol, s}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(b) when is_binary(b), do: b
  defp to_string_or_nil(other), do: to_string(other)

  @doc """
  Decodes a frame from an accumulated TCP buffer.

  Returns `{:more, needed}` when fewer than `needed` bytes are buffered (frame
  splitting across TCP chunks), `{:error, :frame_too_large}` when the declared
  size exceeds the 1 MiB + overhead limit, or `{:error, reason}` for malformed
  frames.
  """
  @spec decode_frame(binary()) ::
          {:ok, %{type: frame_type(), channel: non_neg_integer(), performative: map(), payload: binary()}}
          | {:more, pos_integer()}
          | {:error, term()}
  def decode_frame(buffer) when is_binary(buffer) do
    if byte_size(buffer) < @header_size do
      # Size (and the rest of the fixed header) not fully buffered yet.
      {:more, @header_size}
    else
      <<size::32, doff::8, type_code::8, channel::16, _::binary>> = buffer

      cond do
        size > @max_frame_size ->
          {:error, :frame_too_size}

        size < @header_size ->
          {:error, :bad_frame_size}

        # Spec §2.3: frame type byte is 0x00 (AMQP) or 0x01 (SASL). Anything
        # else decoded as :sasl below (type_code != 0 -> :sasl) — mislabeling
        # garbage as a SASL frame instead of refusing it.
        type_code > 0x01 ->
          {:error, :bad_frame_type}

        # Checked as soon as the fixed header is buffered: a bad doff fails the
        # frame early instead of after the body arrives.
        doff < 2 ->
          {:error, :bad_doff}

        # Extended header larger than the declared frame: the body slice
        # `<<_::binary-size(doff*4), _>>` of a `size`-byte frame would raise
        # MatchError on remote input (decode-never-crash violation).
        doff * 4 > size ->
          {:error, :bad_doff}

        byte_size(buffer) < size ->
          {:more, size}

        true ->
          header_bytes = doff * 4
          <<frame::binary-size(size), rest::binary>> = buffer
          <<_::binary-size(header_bytes), body::binary>> = frame
          decode_body(type_code, channel, body, rest)
      end
    end
  end

  def decode_frame(_), do: {:error, :bad_frame}

  defp decode_body(type_code, channel, body, rest) do
    case codec().decode(body) do
      {:ok, {:described, desc, fields}, remaining} when is_integer(desc) ->
        type = if type_code == @type_code_amqp, do: :amqp, else: :sasl
        perf_name = descriptor_to_name(desc)

        case perf_name do
          nil ->
            {:error, {:unknown_performative, desc}}

          name ->
            # Layer family enforcement (lens-2 cycle-5): a frame's type byte
            # and its performative must belong to the same layer. Today the
            # type byte only labels the decoded map, so a SASL frame carrying
            # an AMQP `open` (or an AMQP frame carrying `sasl_init`) decoded
            # cleanly and flowed into the connection state machine mislabeled.
            cond do
              type_code == @type_code_sasl and name not in @sasl_performatives ->
                {:error, :performative_layer_mismatch}

              type_code == @type_code_amqp and name in @sasl_performatives ->
                {:error, :performative_layer_mismatch}

              true ->
                case decode_performative(name, fields) do
                  {:ok, decoded} ->
                    {:ok, %{type: type, channel: channel, performative: decoded, payload: remaining_payload(remaining, rest)}}

                  # Malformed performative field shape (rescued FunctionClauseError
                  # in decode_performative): surface as a tagged error instead of
                  # crashing the caller with a MatchError (fuzz mutation finding).
                  {:error, _} = err ->
                    err
                end
            end
        end

      {:ok, _other, _} ->
        {:error, :unexpected_frame_body}

      :error ->
        {:error, :bad_frame_body}

      # minimal unblock (connection lane): PrimitiveCodec.decode/1 returns
      # {:error, reason} tuples, not bare :error. Reason-preserving: the
      # codec's diagnosis (truncated / invalid_constructor / ...) travels with
      # the error instead of being collapsed into the bare :bad_frame_body
      # atom, so the connection close frame and logs carry the real cause.
      {:error, reason} ->
        {:error, {:bad_frame_body, reason}}
    end
  end

  # The primitive codec returns the unconsumed tail of the frame body — that
  # tail is the transfer payload. Bytes beyond `size` belong to the next frame
  # in the caller's buffer.
  defp remaining_payload(codec_rest, _frame_rest), do: codec_rest

  # Reverse-index of @performative_descriptors: decoded-frame descriptor ->
  # name is the hot path (once per inbound frame), linear scans replaced.
  @descriptor_names Map.new(@performative_descriptors, fn {name, d} -> {d, name} end)

  defp descriptor_to_name(desc), do: Map.get(@descriptor_names, desc)

  defp decode_performative(name, fields) when is_list(fields) do
    order = Map.fetch!(@field_orders, name)
    raw = order |> Enum.with_index() |> Map.new(fn {n, i} -> {n, Enum.at(fields, i)} end)

    # Total decode: a malformed field shape must surface as a codec error (the
    # connection answers with a clean close/detach frame), never as a raise
    # that silently kills the connection process (R3 red-team finding).
    named =
      decode_fields(name, raw)
    {:ok, Map.put(named, :performative, name)}
  rescue
    FunctionClauseError -> {:error, :bad_performative_fields}
  end

  defp decode_performative(_, _), do: {:error, :bad_performative_fields}

  defp decode_fields(:attach, raw) do
    raw
    |> Map.update(:source, nil, &decode_source_target/1)
    |> Map.update(:target, nil, &decode_source_target/1)
  end

  defp decode_fields(:disposition, raw) do
    Map.update(raw, :state, nil, &decode_delivery_state/1)
  end

  # Mirror the encode side: normalize_field/1 wraps friendly :accepted /
  # :released / {:rejected,_} / {:modified,_} atoms/tuples in ANY performative
  # (including transfer state), but decode only unwrapped them for disposition
  # — a transfer state round-tripped as the raw described tuple (lens-2
  # differential fuzz finding; no consumer reads transfer state raw).
  defp decode_fields(:transfer, raw) do
    Map.update(raw, :state, nil, &decode_delivery_state/1)
  end

  defp decode_fields(_name, raw), do: raw

  defp decode_source_target(nil), do: nil

  # Bare-symbol (and bare-string) source/target: the value IS the address.
  # Canonical rhea/Azure SDK encoding for simple queue attaches (R3 red-team
  # finding): a spec-legal attach with target = {:symbol, "orders"} crashed
  # decode_source_target/1 and the connection died with a silent TCP close.
  defp decode_source_target({:symbol, address}) when is_binary(address), do: %{address: address}
  defp decode_source_target(address) when is_binary(address), do: %{address: address}

  # Positional source/target field list (FrameCodec's own encode_source_target
  # emits the bare 7-element composite field list — see the comment there).
  # Minimal disclosed unblock (census/sendable lane): the encode side moved to
  # this form without a matching decode clause, so every attach carrying a
  # source/target crashed the connection GenServer in decode_source_target/1.
  # Rewrap and reuse the described-form logic below (filter at index 6).
  defp decode_source_target(fields) when is_list(fields),
    do: decode_source_target({:described, nil, fields})

  # SDKs send source/target as described types with the address at index 0
  # (wire-lane fix, real-SDK census finding)
  defp decode_source_target({:described, _d, fields}) when is_list(fields) do
    # The filter (index 6 in the AMQP source composite) must survive the
    # described-form decode: the Service Bus SDK sends source as a described
    # type carrying com.microsoft:session-filter, and the broker needs the
    # selector both for session dequeue filtering and to echo it back in the
    # attach response (s5_sessions e2e lane finding).
    filter =
      fields
      |> Enum.find_value(fn
        {:described, {:symbol, "com.microsoft:session-filter"}, selector} ->
          {"com.microsoft:session-filter", {:session_filter, selector}}

        %{} = filters ->
          Enum.find_value(filters, fn
            {{:symbol, "com.microsoft:session-filter"}, {:described, _, selector}} ->
              {"com.microsoft:session-filter", {:session_filter, selector}}

            {{:symbol, "com.microsoft:session-filter"}, selector} ->
              {"com.microsoft:session-filter", {:session_filter, selector}}

            {"com.microsoft:session-filter", {:described, _, selector}} when is_binary(selector) ->
              {"com.microsoft:session-filter", {:session_filter, selector}}

            {"com.microsoft:session-filter", selector} when is_binary(selector) ->
              {"com.microsoft:session-filter", {:session_filter, selector}}

            _kv ->
              nil
          end)

        _ ->
          nil
      end)

    filter = if is_tuple(filter), do: Map.new([filter]), else: nil

    address =
      case Enum.at(fields, 0) do
        nil -> nil
        address -> address
      end

    base = %{
      address: address,
      durable: Enum.at(fields, 1),
      expiry: Enum.at(fields, 2),
      timeout: Enum.at(fields, 3),
      dynamic: Enum.at(fields, 4),
      distribution_mode: Enum.at(fields, 5)
    }

    base = Map.reject(base, fn {_k, v} -> is_nil(v) end)

    case filter do
      nil -> base
      filter -> Map.put(base, :filter, filter)
    end
  end

  defp decode_source_target(%{} = map) do
    map
    |> Map.new(fn
      {{:symbol, k}, v} -> {safe_atom(k), v}
      {k, v} when is_binary(k) -> {safe_atom(k), v}
      kv -> kv
    end)
    |> Map.update(:filter, nil, fn
      nil ->
        nil

      %{} = filters ->
        Map.new(filters, fn
          {k, {:described, {:symbol, "com.microsoft:session-filter"}, selector}} ->
            {key_name(k), {:session_filter, selector}}

          {k, selector} when is_binary(selector) ->
            {key_name(k), {:session_filter, selector}}

          kv ->
            kv
        end)

      other ->
        other
    end)
  end

  defp decode_delivery_state({:described, desc, _fields} = described) when is_integer(desc) do
    case Enum.find_value(@delivery_state_descriptors, fn {n, d} -> if d == desc, do: n end) do
      :rejected ->
        # fields = [error] list from described body; keep raw
        {:rejected, described_body(described)}

      :modified ->
        {:modified, described_body(described)}

      :accepted ->
        :accepted

      :released ->
        :released

      nil ->
        described
    end
  end

  defp decode_delivery_state(other), do: other

  defp described_body({:described, _d, body}), do: body

  # Wire-sourced keys are never minted into atoms: `String.to_atom/1` on remote
  # input is an unbounded atom-table flood (atoms are never GC'd; ~1M atoms can
  # kill the VM). Known source/target keys resolve to their existing atoms;
  # anything else stays a binary (a binary-tagged key, not a minted atom).
  defp safe_atom(name) when is_atom(name), do: name

  defp safe_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp key_name({:symbol, name}), do: name
  defp key_name(name) when is_binary(name), do: name
  defp key_name(other), do: other

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
    described(@message_section_descriptors.properties, Enum.map(@properties_order, &Map.get(map, &1)))
  end

  defp encode_section({:delivery_annotations, map}), do: map_section(:delivery_annotations, map)
  defp encode_section({:message_annotations, map}), do: map_section(:message_annotations, map)
  defp encode_section({:application_properties, map}), do: map_section(:application_properties, map)
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
    codec().encode({:described, desc, values})
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
    case codec().decode(payload) do
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

defmodule Smalt.Amqp10.FrameDecoder do
  @moduledoc """
  Crash-only AMQP 1.0 frame decoder (parallel family, `lib/smalt/messaging/amqp10/`).

  Independent bit-syntax decoder: `decode_frame/1` returns
  `{:ok, frame, rest}` | `{:more, buffer}` | `{:error, reason}`. The `{:more,
  buffer}` form returns the unconsumed buffer itself — the connection actor
  re-feeds it on the next TCP chunk.

  Bounds enforcement uses the OTP-29 `:erlang.is_integer/3` three-argument
  delegate via `defguardp int_in/3` (repo lane law, AR-WIRE-02), so a hostile
  declared size/doff is refused by a guard, never by a raise-then-rescue.
  Sized elements (0xA0/0xA1/0xA3/0xB0/0xB1/0xB3/0x98) additionally guard the
  AVAILABLE byte count: a truncated declared length answers `{:error,
  :truncated_frame}` — the "decode never raises on remote input" claim is
  receipted (EXPL-4 F2, expl4r-wirefront-repairs). 0xC0/0xD0/0xC1/0xD1
  declared sizes are binding: the count elements must consume the declared
  slice exactly, trailing bytes are refused.

  Structural equivalence vs `Smalt.Amqp.FrameCodec.decode_frame/1` is
  spot-checked on a shared corpus in
  `test/integration/amqp10_crash_only_court_test.exs`.
  """

  @max_frame_size 1 * 1024 * 1024 + 512
  def max_frame_size, do: @max_frame_size

  @header_size 8

  @type frame :: %{
          required(:type) => :amqp | :sasl,
          required(:channel) => 0..65_535,
          required(:performative) => {atom(), map()},
          required(:payload) => binary()
        }

  defguardp int_in(x, lo, hi) when is_integer(x) and x >= lo and x <= hi

  @doc "true iff the 8 bytes are exactly the AMQP 1.0 protocol header."
  @spec protocol_header?(binary()) :: boolean()
  def protocol_header?(<<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>), do: true
  def protocol_header?(_), do: false

  @doc """
  Decode one frame from `buffer`.

  Returns `{:ok, frame, rest}` with
  `%{type:, channel:, performative: {name, fields}, payload:}`, or
  `{:more, buffer}` when the full frame is not buffered yet. Malformed input
  returns `{:error, reason}` — decode never raises on remote input.
  """
  @spec decode_frame(binary()) ::
          {:ok, frame(), binary()} | {:more, binary()} | {:error, term()}
  def decode_frame(buffer) when is_binary(buffer) and byte_size(buffer) >= @header_size do
    <<size::32, doff::8, type::8, channel::16, _::binary>> = buffer

    cond do
      not int_in(size, @header_size, @max_frame_size) ->
        {:error, {:bad_frame_size, size}}

      type not in [0, 1] ->
        {:error, {:bad_frame_type, type}}

      not int_in(doff, 2, div(@max_frame_size, 4)) or doff * 4 > size ->
        {:error, {:bad_doff, doff}}

      byte_size(buffer) < size ->
        {:more, buffer}

      true ->
        <<frame::binary-size(^size), rest::binary>> = buffer
        <<_::binary-size(^doff * 4), body::binary>> = frame

        case decode_described(body) do
          {:ok, {:described, desc, list}, payload} ->
            with {:ok, name} <- performative_name(desc),
                 {:ok, fields} <- positional_fields(name, list) do
              {:ok, frame_map(type, channel, {name, fields}, payload), rest}
            end

          {:ok, :empty, <<>>} ->
            {:ok, frame_map(type, channel, {:heartbeat, %{}}, <<>>), rest}

          {:error, _} = err ->
            err
        end
    end
  end

  def decode_frame(buffer) when is_binary(buffer), do: {:more, buffer}
  def decode_frame(_), do: {:error, :bad_frame}

  defp frame_map(type, channel, {perf, fields}, payload) do
    %{
      type: if(type == 0, do: :amqp, else: :sasl),
      channel: channel,
      performative: {perf, fields},
      payload: payload
    }
  end

  # Body is either empty (heartbeat) or exactly one described performative;
  # whatever the described value leaves unconsumed is the transfer payload.
  defp decode_described(<<>>), do: {:ok, :empty, <<>>}

  defp decode_described(<<0x00, 0x53, d, rest::binary>>) do
    case decode_element(rest) do
      {:ok, inner, rest2} -> {:ok, {:described, d, inner}, rest2}
      err -> err
    end
  end

  defp decode_described(<<0x00, 0x80, d::64, rest::binary>>) do
    case decode_element(rest) do
      {:ok, inner, rest2} -> {:ok, {:described, d, inner}, rest2}
      err -> err
    end
  end

  defp decode_described(_), do: {:error, :bad_performative}

  defp performative_name(0x0000_0000_0000_0010), do: {:ok, :open}
  defp performative_name(0x0000_0000_0000_0011), do: {:ok, :begin}
  defp performative_name(0x0000_0000_0000_0012), do: {:ok, :attach}
  defp performative_name(0x0000_0000_0000_0013), do: {:ok, :flow}
  defp performative_name(0x0000_0000_0000_0014), do: {:ok, :transfer}
  defp performative_name(0x0000_0000_0000_0015), do: {:ok, :disposition}
  defp performative_name(0x0000_0000_0000_0016), do: {:ok, :detach}
  defp performative_name(0x0000_0000_0000_0017), do: {:ok, :end}
  defp performative_name(0x0000_0000_0000_0018), do: {:ok, :close}
  defp performative_name(0x0000_0000_0000_0040), do: {:ok, :sasl_mechanisms}
  defp performative_name(0x0000_0000_0000_0041), do: {:ok, :sasl_init}
  defp performative_name(0x0000_0000_0000_0042), do: {:ok, :sasl_challenge}
  defp performative_name(0x0000_0000_0000_0043), do: {:ok, :sasl_response}
  defp performative_name(0x0000_0000_0000_0044), do: {:ok, :sasl_outcome}
  defp performative_name(desc), do: {:error, {:unknown_performative, desc}}

  @open_fields [
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
  ]

  @begin_fields [
    :remote_channel,
    :next_outgoing_id,
    :incoming_window,
    :outgoing_window,
    :handle_max
  ]

  @attach_fields [
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
    :offered_capabilities,
    :desired_capabilities,
    :properties
  ]

  @flow_fields [
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
  ]

  @transfer_fields [
    :handle,
    :delivery_id,
    :delivery_tag,
    :message_format,
    :settled,
    :more,
    :rcv_settle_mode,
    :state
  ]

  @disposition_fields [:role, :first, :last, :settled, :state, :batchable]

  @detach_fields [:handle, :closed, :error]
  @end_fields [:error]
  @close_fields [:error]

  @sasl_mechanisms_fields [:server_mechanisms]
  @sasl_init_fields [:mechanism, :initial_response, :hostname]
  @sasl_outcome_fields [:code, :additional_data]
  @sasl_challenge_fields [:challenge]
  @sasl_response_fields [:response]

  defp positional_fields(name, list) do
    order = field_order(name)

    fields =
      order
      # list0 bodies decode to nil; List.wrap(nil) -> [] keeps the zip lawful
      |> Enum.zip(List.wrap(list) ++ List.duplicate(nil, length(order)))
      |> Map.new()

    {:ok, fields}
  end

  defp field_order(:open), do: @open_fields
  defp field_order(:begin), do: @begin_fields
  defp field_order(:attach), do: @attach_fields
  defp field_order(:flow), do: @flow_fields
  defp field_order(:transfer), do: @transfer_fields
  defp field_order(:disposition), do: @disposition_fields
  defp field_order(:detach), do: @detach_fields
  defp field_order(:end), do: @end_fields
  defp field_order(:close), do: @close_fields
  defp field_order(:sasl_mechanisms), do: @sasl_mechanisms_fields
  defp field_order(:sasl_init), do: @sasl_init_fields
  defp field_order(:sasl_outcome), do: @sasl_outcome_fields
  defp field_order(:sasl_challenge), do: @sasl_challenge_fields
  defp field_order(:sasl_response), do: @sasl_response_fields

  # ---------------------------------------------------------------------------
  # AMQP 1.0 primitive element decode
  # ---------------------------------------------------------------------------

  defp decode_element(<<0x40, rest::binary>>), do: {:ok, nil, rest}
  defp decode_element(<<0x41, rest::binary>>), do: {:ok, true, rest}
  defp decode_element(<<0x42, rest::binary>>), do: {:ok, false, rest}
  defp decode_element(<<0x56, b, rest::binary>>), do: {:ok, b != 0, rest}

  defp decode_element(<<0x50, b, rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x51, b::16, rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x52, b, rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x43, rest::binary>>), do: {:ok, 0, rest}
  defp decode_element(<<0x44, rest::binary>>), do: {:ok, 0, rest}
  defp decode_element(<<0x70, b::32, rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x53, b, rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x80, b::64, rest::binary>>), do: {:ok, b, rest}

  defp decode_element(<<0x54, b::signed-size(8), rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x71, b::signed-size(32), rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x55, b::signed-size(8), rest::binary>>), do: {:ok, b, rest}
  defp decode_element(<<0x81, b::signed-size(64), rest::binary>>), do: {:ok, b, rest}

  defp decode_element(<<0x83, ms::integer-size(64), rest::binary>>),
    do: {:ok, {:timestamp, ms}, rest}

  defp decode_element(<<0x98, uuid::binary-size(16), rest::binary>>),
    do: {:ok, {:uuid, uuid}, rest}

  defp decode_element(<<0x98, _::binary>>), do: {:error, :truncated_frame}

  # EXPL-4 F2: sized elements guard the AVAILABLE byte count, not only the
  # declared bound — a truncated body answers {:error, :truncated_frame},
  # never a MatchError (moduledoc law: decode never raises on remote input).
  defp decode_element(<<0xA0, n, rest::binary>>) when int_in(n, 0, 255) and byte_size(rest) >= n do
    <<b::binary-size(^n), rest2::binary>> = rest
    {:ok, b, rest2}
  end

  defp decode_element(<<0xA0, _n, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xB0, n::32, rest::binary>>)
       when int_in(n, 0, @max_frame_size) and byte_size(rest) >= n do
    <<b::binary-size(^n), rest2::binary>> = rest
    {:ok, b, rest2}
  end

  # SKEP-R2 F2: declared size above the constructor's structural bound is a
  # malformed size, not truncation.
  defp decode_element(<<0xB0, n::32, _rest::binary>>) when n > @max_frame_size,
    do: {:error, :bad_element}

  defp decode_element(<<0xB0, _n::32, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xA3, n, rest::binary>>) when int_in(n, 0, 255) and byte_size(rest) >= n do
    <<b::binary-size(^n), rest2::binary>> = rest
    {:ok, {:symbol, b}, rest2}
  end

  defp decode_element(<<0xA3, _n, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xB3, n::32, rest::binary>>)
       when int_in(n, 0, @max_frame_size) and byte_size(rest) >= n do
    <<b::binary-size(^n), rest2::binary>> = rest
    {:ok, {:symbol, b}, rest2}
  end

  defp decode_element(<<0xB3, n::32, _rest::binary>>) when n > @max_frame_size,
    do: {:error, :bad_element}

  defp decode_element(<<0xB3, _n::32, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xA1, n, rest::binary>>) when int_in(n, 0, 255) and byte_size(rest) >= n do
    <<b::binary-size(^n), rest2::binary>> = rest
    {:ok, b, rest2}
  end

  defp decode_element(<<0xA1, _n, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xB1, n::32, rest::binary>>)
       when int_in(n, 0, @max_frame_size) and byte_size(rest) >= n do
    <<b::binary-size(^n), rest2::binary>> = rest
    {:ok, b, rest2}
  end

  defp decode_element(<<0xB1, n::32, _rest::binary>>) when n > @max_frame_size,
    do: {:error, :bad_element}

  defp decode_element(<<0xB1, _n::32, _rest::binary>>), do: {:error, :truncated_frame}

  # EXPL-4 F2: 0xC0/0xD0/0xC1/0xD1 — the declared size IS binding. The
  # constructor is sliced to `size` bytes first (truncation => typed error),
  # then the count elements must consume the slice EXACTLY — trailing bytes
  # inside a declared list/map size are refused, never silently absorbed.
  defp decode_element(<<0xC0, size, rest::binary>>)
       when int_in(size, 1, 255) and byte_size(rest) >= size do
    <<contents::binary-size(^size), rest2::binary>> = rest
    <<count, elems::binary>> = contents
    take_exact(count, elems, rest2)
  end

  # SKEP-R2 F2: size=0 is structurally impossible (count byte alone needs 1).
  defp decode_element(<<0xC0, 0, _rest::binary>>), do: {:error, :bad_element}

  defp decode_element(<<0xC0, _size, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xD0, size::32, rest::binary>>)
       when int_in(size, 4, @max_frame_size) and byte_size(rest) >= size do
    <<contents::binary-size(^size), rest2::binary>> = rest
    <<count::32, elems::binary>> = contents
    take_exact(count, elems, rest2)
  end

  # SKEP-R2 F2: size<4 is structurally impossible (count needs 4 bytes).
  defp decode_element(<<0xD0, size::32, _rest::binary>>) when size < 4,
    do: {:error, :bad_element}

  defp decode_element(<<0xD0, _size::32, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xC1, size, rest::binary>>)
       when int_in(size, 1, 255) and byte_size(rest) >= size do
    <<contents::binary-size(^size), rest2::binary>> = rest
    <<count, elems::binary>> = contents
    map_exact(count, elems, rest2)
  end

  defp decode_element(<<0xC1, 0, _rest::binary>>), do: {:error, :bad_element}

  defp decode_element(<<0xC1, _size, _rest::binary>>), do: {:error, :truncated_frame}

  defp decode_element(<<0xD1, size::32, rest::binary>>)
       when int_in(size, 4, @max_frame_size) and byte_size(rest) >= size do
    <<contents::binary-size(^size), rest2::binary>> = rest
    <<count::32, elems::binary>> = contents
    map_exact(count, elems, rest2)
  end

  defp decode_element(<<0xD1, size::32, _rest::binary>>) when size < 4,
    do: {:error, :bad_element}

  defp decode_element(<<0xD1, _size::32, _rest::binary>>), do: {:error, :truncated_frame}

  # AMQP 1.0 list0 (0x45) and empty-map (0x46) constructors: rhea/FrameCodec
  # encode empty field lists (end/close with no error field) and empty
  # described states (accepted = described 0x24 wrapping list0) this way; a
  # decoder without these clauses answers bad_element on its own
  # encoder's output (witnessed: equivalence spot-check, v26.10.21).
  defp decode_element(<<0x45, rest::binary>>), do: {:ok, [], rest}
  defp decode_element(<<0x46, rest::binary>>), do: {:ok, %{}, rest}

  # Described values inside performatives (source/target, delivery states).
  defp decode_element(<<0x00, 0x53, d, rest::binary>>) do
    case decode_element(rest) do
      {:ok, inner, rest2} -> {:ok, {:described, d, inner}, rest2}
      err -> err
    end
  end

  defp decode_element(<<0x00, 0x80, d::64, rest::binary>>) do
    case decode_element(rest) do
      {:ok, inner, rest2} -> {:ok, {:described, d, inner}, rest2}
      err -> err
    end
  end

  defp decode_element(<<0x00, rest::binary>>) do
    case decode_element(rest) do
      {:ok, desc, rest2} ->
        case decode_element(rest2) do
          {:ok, inner, rest3} -> {:ok, {:described, desc, inner}, rest3}
          err -> err
        end

      err ->
        err
    end
  end

  defp decode_element(_), do: {:error, :bad_element}

  defp decode_elements(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_elements(n, rest, acc) when n > 0 do
    case decode_element(rest) do
      {:ok, term, rest2} -> decode_elements(n - 1, rest2, [term | acc])
      err -> err
    end
  end

  # Declared-size slice consumed exactly by `count` elements, or typed refusal.
  defp take_exact(count, elems, outer_rest) do
    case decode_elements(count, elems, []) do
      {:ok, list, <<>>} -> {:ok, list, outer_rest}
      {:ok, _, _} -> {:error, :bad_element}
      {:error, _} = err -> err
    end
  end

  defp map_exact(count, elems, outer_rest) do
    case take_exact(count, elems, outer_rest) do
      # spec-invalid odd element count must be a typed refusal, never a raise
      # (BK-SKEP F1: pairs/1 has no odd-list clause).
      {:ok, list, rest} when rem(length(list), 2) == 0 -> {:ok, Map.new(pairs(list)), rest}
      {:ok, _, _} -> {:error, :bad_element}
      {:error, _} = err -> err
    end
  end

  defp pairs([]), do: []
  defp pairs([k, v | t]), do: [{key(k), v} | pairs(t)]

  defp key({:symbol, s}) when is_binary(s), do: {:symbol, s}
  defp key(k), do: k
end

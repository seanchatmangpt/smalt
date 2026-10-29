defmodule Smalt.Amqp.DeliveryEncoder do
  @moduledoc """
  Builds outbound message-section maps for AMQP 1.0 deliveries.

  Pure functions returning plain maps; the FrameCodec lane encodes the
  sections onto the wire. Timestamps are `{:timestamp, ms}` per
  `Smalt.Amqp.PrimitiveCodec`.

      build_sections(
        sequence_number: 42,
        locked_until: 1_700_000_000_000,
        enqueued_time: 1_699_999_000_000,
        session_id: "s1",           # optional — omitted when nil
        delivery_count: 2,
        message_id: "mid-1",
        creation_time: 1_699_999_000_000,
        deadletter_reason: "max-delivery",          # DLQ footer, optional
        deadletter_description: "gave up"           # DLQ footer, optional
      )

  Returns:

      %{
        header: %{delivery_count: n},
        properties: %{message_id: ..., creation_time: {:timestamp, ms}},
        message_annotations: %{
          "x-opt-sequence-number" => ulong,
          "x-opt-locked-until" => {:timestamp, ms},
          "com.microsoft:locked-until-utc" => ulong_filetime_ticks,
          "x-opt-enqueued-time-utc" => {:timestamp, ms},
          "x-opt-session-id" => binary       # only when set
        },
        application_properties: %{
          "DeadLetterReason" => ..., "DeadLetterErrorDescription" => ...
        }   # only for DLQ deliveries
      }

  ## Service Bus dialect: .NET filetime lock expiry

  Session-lock expiry uses the Service Bus wire dialect
  `com.microsoft:locked-until-utc` as `.NET filetime` ticks (100ns intervals
  since 0001-01-01 UTC), not an AMQP timestamp. Use `filetime_from_ms/1` to
  convert epoch milliseconds; the delivery annotations carry both the
  `x-opt-locked-until` timestamp (ms) and the filetime ulong. On a session-lock
  *attach*, the Connection lane should apply the same conversion — set
  `"com.microsoft:locked-until-utc" => DeliveryEncoder.filetime_from_ms(ms)`
  (AMQP ulong) in the attach properties when a lock expiry is present.
  """

  @type section_map :: %{
          optional(:header) => %{delivery_count: non_neg_integer},
          optional(:properties) => map,
          optional(:message_annotations) => map,
          optional(:application_properties) => map
        }

  @spec build_sections(keyword) :: section_map
  def build_sections(opts) do
    opts = Map.new(opts)

    app_props = Map.get(opts, :app_props) || %{}

    %{}
    |> maybe_put(:header, build_header(opts))
    |> maybe_put(:properties, build_properties(opts))
    |> maybe_put(:message_annotations, build_message_annotations(opts))
    |> maybe_put(
      :application_properties,
      Map.merge(app_props, build_dlq_footer(opts) || %{}) |> empty_map_to_nil()
    )
  end

  # ===========================================================================
  # Section builders
  # ===========================================================================

  defp build_header(%{delivery_count: count}) when is_integer(count) and count >= 0,
    do: %{delivery_count: count}

  defp build_header(_opts), do: nil

  defp build_properties(opts) do
    %{}
    |> maybe_put(:message_id, Map.get(opts, :message_id))
    |> maybe_put(:creation_time, timestamp_opt(opts, :creation_time))
    |> empty_map_to_nil()
  end

  defp build_message_annotations(opts) do
    %{}
    |> maybe_put("x-opt-sequence-number", ulong_opt(opts, :sequence_number))
    |> maybe_put("x-opt-locked-until", timestamp_opt(opts, :locked_until))
    |> maybe_put(
      "com.microsoft:locked-until-utc",
      filetime_opt(opts, :locked_until)
    )
    # KD-COVERS: KD-85 — @azure/service-bus materializes `enqueuedTimeUtc`
    # from the annotation `x-opt-enqueued-time` (no -utc suffix); stamp both
    # keys additively so legacy `-utc` readers keep working.
    |> maybe_put("x-opt-enqueued-time-utc", timestamp_opt(opts, :enqueued_time))
    |> maybe_put("x-opt-enqueued-time", timestamp_opt(opts, :enqueued_time))
    |> maybe_put("x-opt-session-id", Map.get(opts, :session_id))
    |> empty_map_to_nil()
  end

  defp build_dlq_footer(opts) do
    reason = Map.get(opts, :deadletter_reason)
    description = Map.get(opts, :deadletter_description)

    if reason == nil and description == nil do
      nil
    else
      %{}
      |> maybe_put("DeadLetterReason", reason)
      |> maybe_put("DeadLetterErrorDescription", description)
    end
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  @doc """
  Converts epoch milliseconds to .NET filetime ticks (100ns intervals since
  0001-01-01 00:00:00 UTC), the encoding Service Bus requires for
  `com.microsoft:locked-until-utc`.

      filetime_from_ms(0)                      #=> 62_135_596_800_000_000
      filetime_from_ms(1_791_936_000_000)      #=> 639_275_328_000_000_000

  Millisecond precision is preserved (the low 4 ticks of each ms are zero).
  """
  @spec filetime_from_ms(integer) :: non_neg_integer
  def filetime_from_ms(ms) when is_integer(ms),
    do: (ms + 62_135_596_800_000) * 10_000

  # AMQP ulong domain (message-annotations values). Negative sequence
  # numbers are invalid on the wire and rejected here.
  defp ulong_opt(opts, key) do
    case Map.get(opts, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp filetime_opt(opts, key) do
    case timestamp_opt(opts, key) do
      {:timestamp, ms} -> filetime_from_ms(ms)
      nil -> nil
    end
  end

  defp timestamp_opt(opts, key) do
    case Map.get(opts, key) do
      {:timestamp, _ms} = ts -> ts
      ms when is_integer(ms) -> {:timestamp, ms}
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp empty_map_to_nil(map) when map == %{}, do: nil
  defp empty_map_to_nil(map), do: map
end

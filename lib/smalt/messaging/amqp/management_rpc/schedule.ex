defmodule Smalt.Amqp.ManagementRpc.Schedule do
  @moduledoc """
  `com.microsoft:schedule-message` / `com.microsoft:cancel-scheduled-message`
  (KD-118) — extracted verbatim from the pre-split
  `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10); bodies
  byte-identical, `defp` promoted to `def` on the handler entries only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  # KD-COVERS: KD-118 — the SDK (@azure/service-bus 7.10.0
  # managementClient.js scheduleMessages) sends body {"messages": [entry]}
  # where each entry is a wrap_map {message: <vbin of the encoded rhea
  # message>, "message-id": .., "session-id"?: ..}; the scheduled time rides
  # the EMBEDDED message's x-opt-scheduled-enqueue-time message annotation
  # (core-amqp Constants.scheduledEnqueueTime). Reply: {"sequence-numbers":
  # [long]}. The store arm (QueueStore :scheduled state + claim_candidates'
  # schedule gate) already delivers the row once the time passes; no sweeper
  # change.
  def handle(body, queue_from_request, correlation_id, context, _now) do
    queue = Shared.bare_entity(Shared.body_field(body, "queue") || queue_from_request)
    entries = unwrap_entries(Shared.body_field(body, "messages"))

    cond do
      Shared.blank?(queue) ->
        Shared.respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      is_nil(entries) ->
        Shared.respond(400, "MESSAGES_REQUIRED", nil, correlation_id)

      true ->
        case schedule_each(entries, queue, context) do
          {:ok, seqs} ->
            Shared.respond(200, "OK", %{"sequence-numbers" => seqs}, correlation_id)

          {:error, :capacity} ->
            Shared.respond(400, "QUEUE_CAPACITY_EXCEEDED", nil, correlation_id)

          {:error, :session_required} ->
            Shared.respond(400, "SESSION_REQUIRED", nil, correlation_id)

          {:error, _reason} ->
            Shared.respond(400, "MALFORMED_MESSAGE", nil, correlation_id)
        end
    end
  end

  def schedule_each(entries, queue, context, acc \\ [])

  def schedule_each([], _queue, _context, acc), do: {:ok, Enum.reverse(acc)}

  def schedule_each([entry | rest], queue, context, acc) do
    case schedule_one(entry, queue, context) do
      {:ok, seq} -> schedule_each(rest, queue, context, [seq | acc])
      {:error, _reason} = err -> err
    end
  end

  def schedule_one(entry, queue, context) when is_map(entry) do
    with raw when is_binary(raw) <- Map.get(entry, "message"),
         {:ok, sections} when is_list(sections) <- Smalt.Amqp.FrameCodec.decode_message(raw) do
      props = section_of(sections, :properties) || %{}
      annotations = section_of(sections, :message_annotations) || %{}
      app_props = section_of(sections, :application_properties) || %{}
      body = body_section(sections)

      cond do
        is_nil(body) ->
          {:error, :no_body}

        bad_scheduled_time?(annotations) ->
          {:error, :bad_scheduled_time}

        true ->
          Shared.invoke(context, :queue_store, Smalt.Amqp.QueueStore, :enqueue, [
            queue,
            body,
            [
              message_id: props[:message_id] || props["message_id"] || entry["message-id"],
              app_props: app_props,
              session_id:
                props[:group_id] || props["group_id"] || entry["session-id"],
              annotations: annotations,
              scheduled_enqueue_time: scheduled_time_ms(annotations),
              now_ms: System.system_time(:millisecond)
            ]
          ])
          |> case do
            {:ok, seq} -> {:ok, seq}
            {:error, _reason} = err -> err
          end
      end
    else
      _ -> {:error, :malformed_entry}
    end
  end

  def schedule_one(_entry, _queue, _context), do: {:error, :malformed_entry}

  # Present-but-not-a-positive-timestamp annotation is malformed (R142
  # principle: never silently degrade a schedule to immediate delivery);
  # ABSENT falls through to immediate enqueue (the PT0S case).
  def bad_scheduled_time?(annotations) do
    case Map.get(annotations, "x-opt-scheduled-enqueue-time") do
      nil -> false
      {:timestamp, ms} when is_integer(ms) and ms >= 0 -> false
      ms when is_integer(ms) and ms >= 0 -> false
      _ -> true
    end
  end

  def scheduled_time_ms(annotations) do
    case Map.get(annotations, "x-opt-scheduled-enqueue-time") do
      {:timestamp, ms} when is_integer(ms) -> ms
      ms when is_integer(ms) -> ms
      _ -> nil
    end
  end

  def section_of(sections, kind) when is_list(sections) do
    Enum.find_value(sections, fn
      {^kind, value} -> value
      _ -> nil
    end)
  end

  def body_section(sections) do
    Enum.find_value(sections, fn
      {:body_data, bin} when is_binary(bin) -> {:body_data, bin}
      {:body_amqp_value, v} -> {:body_amqp_value, v}
      {:body_sequence, xs} when is_list(xs) -> {:body_sequence, xs}
      _ -> nil
    end)
  end

  # SDK cancelScheduledMessages sends body {"sequence-numbers": [Buffer]}
  # (8-byte big-endian longs, rhea-decoded as binaries). Delete-present
  # semantics mirror batch-delete-messages: PRESENT still-scheduled rows are
  # cancelled, absent/already-delivered sequence numbers are skipped.
  def cancel(body, queue_from_request, correlation_id, context, _now) do
    queue = Shared.body_field(body, "queue") || queue_from_request

    seqs =
      Shared.body_field(body, "sequence-numbers")
      |> unwrap_entries()
      |> Enum.map(&coerce_seq_long/1)

    cond do
      Shared.blank?(queue) ->
        Shared.respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      seqs == [] or :error in seqs ->
        Shared.respond(400, "SEQUENCE_NUMBERS_REQUIRED", nil, correlation_id)

      true ->
        result =
          Enum.reduce_while(seqs, :ok, fn seq, :ok ->
            case Shared.store_call(context, :cancel_scheduled, [Shared.bare_entity(queue), seq]) do
              :ok -> {:cont, :ok}
              {:error, :not_found} -> {:cont, :ok}
              {:error, :not_scheduled} -> {:cont, :ok}
              {:error, _other} -> {:halt, {:error, :store}}
              _other -> {:halt, {:error, :store}}
            end
          end)

        case result do
          :ok -> Shared.respond(200, "OK", nil, correlation_id)
          {:error, :store} -> Shared.respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # {:array, xs} (rhea wrap_array) / bare list / nil unwrap for body arrays.
  defp unwrap_entries({:array, xs}) when is_list(xs), do: xs
  defp unwrap_entries(xs) when is_list(xs), do: xs
  defp unwrap_entries(nil), do: nil
  defp unwrap_entries(other), do: List.wrap(other)

  defp coerce_seq_long(n) when is_integer(n), do: n

  defp coerce_seq_long(bin) when is_binary(bin) do
    if byte_size(bin) in [4, 8], do: :binary.decode_unsigned(bin), else: :error
  end

  defp coerce_seq_long(_), do: :error
end

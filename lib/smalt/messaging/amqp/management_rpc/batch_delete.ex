defmodule Smalt.Amqp.ManagementRpc.BatchDelete do
  @moduledoc """
  `com.microsoft:batch-delete-messages` (GAP-A2-07) — extracted verbatim from
  the pre-split `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10);
  bodies byte-identical, `defp` promoted to `def` on the handler entry only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  # Deletes DLQ (or queue) messages by sequence number list: every PRESENT
  # sequence number is deleted and the deleted count returned; absent sequence
  # numbers are skipped, they do NOT fail the batch. Wire surface: SDK body
  # `sequence-numbers` decodes as AMQP array-of-long (the {:array, xs} form,
  # same unwrap as receive-by-sequence-number).
  def handle(body, queue_from_request, correlation_id, context, _now) do
    queue = Shared.body_field(body, "queue") || queue_from_request

    seqs =
      Shared.body_field(body, "sequence-numbers")
      |> case do
        {:array, xs} when is_list(xs) -> xs
        xs when is_list(xs) -> xs
        other -> List.wrap(other)
      end
      |> Enum.map(&Shared.coerce_long/1)

    cond do
      Shared.blank?(queue) ->
        Shared.respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      seqs == [] or :error in seqs ->
        Shared.respond(400, "SEQUENCE_NUMBERS_REQUIRED", nil, correlation_id)

      true ->
        case Shared.store_call(context, :delete_by_sequence, [queue, seqs]) do
          {:ok, deleted} when is_integer(deleted) ->
            _ = deleted
            Shared.respond(200, "OK", nil, correlation_id)

          {:error, _reason} ->
            Shared.respond(404, "NOT_FOUND", nil, correlation_id)

          _other ->
            Shared.respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end
end

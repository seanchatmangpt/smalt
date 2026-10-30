defmodule Smalt.Amqp.ManagementRpc.Peek do
  @moduledoc """
  `com.microsoft:peek-message` — extracted verbatim from the pre-split
  `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10); bodies
  byte-identical, `defp` promoted to `def` on the handler entry only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  @peek_min 1
  @peek_max 100

  def handle(body, queue_from_request, correlation_id, context, now) do
    from_seq = Shared.coerce_long(Shared.fetch_or(body, "from-sequence-number", 0))
    count = Shared.coerce_long(Shared.fetch_or(body, "message-count", 1))

    cond do
      from_seq == :error ->
        Shared.respond(400, "PEEK_BOUNDS", nil, correlation_id)

      not is_integer(count) or count < @peek_min or count > @peek_max ->
        Shared.respond(400, "PEEK_BOUNDS", nil, correlation_id)

      true ->
        case Shared.invoke(context, :queue_store, Smalt.Amqp.QueueStore, :peek, [
               Shared.bare_entity(queue_from_request || Map.get(body, :queue)),
               [from_sequence_number: from_seq, message_count: count, now: now]
             ]) do
          {:ok, []} ->
            Shared.respond(204, "NO_CONTENT", nil, correlation_id)

          {:ok, messages} when is_list(messages) ->
            payload = %{
              "messages" =>
                Enum.map(messages, fn m ->
                  %{"message" => Shared.message_body(m)}
                  |> Shared.maybe_put_seq(m)
                  # Wave-1 seam finding: peek of a still-deferred row must
                  # surface its state (Azure reply carries delivery-state).
                  |> Shared.maybe_put_delivery_state(m)
                end)
            }

            Shared.respond(200, "OK", payload, correlation_id)

          {:error, _reason} ->
            Shared.respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end
end

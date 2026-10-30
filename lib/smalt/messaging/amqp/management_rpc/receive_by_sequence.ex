defmodule Smalt.Amqp.ManagementRpc.ReceiveBySequence do
  @moduledoc """
  `com.microsoft:receive-by-sequence-number` — extracted verbatim from the
  pre-split `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10);
  bodies byte-identical, `defp` promoted to `def` on the handler entry only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  # V261014-08 task 08-2. Required body field `sequence-numbers` (long array);
  # optional `receiver-settle-mode` / `associated-link-name` accepted and
  # ignored. Batch semantics: one non-deferred (or missing) sequence number
  # fails the WHOLE batch with 410 MESSAGE_NOT_DEFERRED (atomic, no partial
  # lock) — the chosen emulator semantics, documented here and in
  # QueueStore.receive_deferred/3. Qualifying messages re-lock and re-enter
  # the normal settle path; the reply carries the peek-message envelope.
  def handle(body, queue_from_request, correlation_id, context, now) do
    queue = Shared.bare_entity(Shared.body_field(body, "queue") || queue_from_request)

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
        # Optional `session-id` (sessionful receive-by-sequence): threaded into
        # QueueStore.receive_deferred opts, where a mismatch joins the atomic
        # 410 refusal list (wave-1 seam finding: :477 dropped it).
        session_id_field = Shared.body_field(body, "session-id")
        session_id = if Shared.blank?(session_id_field), do: nil, else: session_id_field

        case Shared.invoke(context, :queue_store, Smalt.Amqp.QueueStore, :receive_deferred, [
               queue,
               seqs,
               [now_ms: now, session_id: session_id]
             ]) do
          {:ok, messages} when is_list(messages) ->
            payload = %{
              "messages" =>
                Enum.map(messages, fn m ->
                  %{"message" => Shared.message_body(m)}
                  |> Shared.maybe_put_seq(m)
                  # R178e (census deferred-receive): the 7.10.0 SDK derives the
                  # deferred message's deliveryCount from the decoded embedded
                  # message HEADER (managementClient.js ServiceBusMessageImpl)
                  # and its lockToken from msg["lock-token"] — without them the
                  # probe sees deliveryCount undefined and completes with no
                  # token (410). Real Service Bus carries both in this reply.
                  |> Shared.maybe_put_delivery_count(m)
                  |> Shared.maybe_put_lock_token(m)
                end)
            }

            Shared.respond(200, "OK", payload, correlation_id)

          {:error, {:not_deferred, _missing}} ->
            Shared.respond(410, "MESSAGE_NOT_DEFERRED", nil, correlation_id)

          {:error, _reason} ->
            Shared.respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end
end

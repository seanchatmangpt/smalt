defmodule Smalt.Amqp.ManagementRpc.LockRenewSession do
  @moduledoc """
  `com.microsoft:renew-session-lock` — extracted verbatim from the pre-split
  `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10); bodies
  byte-identical, `defp` promoted to `def` on the handler entry only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  def handle(body, queue_from_request, correlation_id, context, now) do
    session_id = Shared.body_field(body, "session-id")
    queue = Shared.body_field(body, "queue") || Map.get(body, :queue) || queue_from_request

    cond do
      Shared.blank?(session_id) ->
        Shared.respond(400, "SESSION_ID_REQUIRED", nil, correlation_id)

      true ->
        case Shared.invoke(context, :lock_manager, Smalt.Amqp.LockManager, :renew_session_lock, [
               queue,
               session_id,
               now
             ]) do
          {:ok, expiry_ms} ->
            Shared.respond(200, "OK", %{"expiration" => {:timestamp, expiry_ms}}, correlation_id)

          {:error, _reason} ->
            Shared.respond(410, "SESSION_LOCK_LOST", nil, correlation_id)
        end
    end
  end
end

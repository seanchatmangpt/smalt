defmodule Smalt.Amqp.ManagementRpc.SessionState do
  @moduledoc """
  `com.microsoft:set-session-state` / `com.microsoft:get-session-state`
  (GAP-A2-05) — extracted verbatim from the pre-split
  `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10); bodies
  byte-identical, `defp` promoted to `def` on the handler entries only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  # Opaque session state bytes ride the session lock record in
  # `:smalt_sb_sessions` (field :session_state, written by
  # LockManager.do_session_acquire and mutated only here). Emulator semantics
  # (disclosed in the KD row): the state dies with the session lock record —
  # real Service Bus keeps it for the session's lifetime independent of locks.
  def set(body, queue_from_request, correlation_id, context, _now) do
    session_id = Shared.body_field(body, "session-id")
    state = Shared.body_field(body, "session-state")
    queue = Shared.body_field(body, "queue") || Map.get(body, :queue) || queue_from_request

    cond do
      Shared.blank?(session_id) ->
        Shared.respond(400, "SESSION_ID_REQUIRED", nil, correlation_id)

      is_nil(state) ->
        # SDK set_session_state("") clears the state — an empty binary is a
        # legal value; only a truly absent field is malformed.
        Shared.respond(400, "SESSION_STATE_REQUIRED", nil, correlation_id)

      state_too_large?(state) ->
        # Azure cap: session state is capped at 256KB
        # (MessagingError "ArgumentOutOfRange"/size exceeded on the real
        # service); emulator surfaces it typed as 400.
        Shared.respond(400, "SESSION_STATE_SIZE_EXCEEDED", nil, correlation_id)

      true ->
        case Shared.store_call(context, :session_state_put, [queue, session_id, state]) do
          :ok -> Shared.respond(200, "OK", nil, correlation_id)
          {:error, :not_found} -> Shared.respond(404, "SESSION_NOT_FOUND", nil, correlation_id)
          {:error, _other} -> Shared.respond(404, "NOT_FOUND", nil, correlation_id)
          _other -> Shared.respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # 256KB Azure session-state cap; binary state only (non-binary non-nil
  # state would crash byte_size, so it falls through to the store seam and
  # fails there if truly malformed).
  @session_state_max 256 * 1024

  defp state_too_large?(state) when is_binary(state),
    do: byte_size(state) > @session_state_max

  defp state_too_large?(_), do: false

  def get(body, queue_from_request, correlation_id, context, _now) do
    session_id = Shared.body_field(body, "session-id")
    queue = Shared.body_field(body, "queue") || Map.get(body, :queue) || queue_from_request

    cond do
      Shared.blank?(session_id) ->
        Shared.respond(400, "SESSION_ID_REQUIRED", nil, correlation_id)

      true ->
        case Shared.store_call(context, :session_state_get, [queue, session_id]) do
          {:ok, state} -> Shared.respond(200, "OK", %{"session-state" => state}, correlation_id)
          {:error, :not_found} -> Shared.respond(404, "SESSION_NOT_FOUND", nil, correlation_id)
          {:error, _other} -> Shared.respond(404, "NOT_FOUND", nil, correlation_id)
          _other -> Shared.respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end
end

defmodule Smalt.Amqp.ManagementRpc do

  @moduledoc """
  `$management` request/response handling (Service Bus emulator dialect).

  `handle/2` is a pure function over a request map and a context map:

      handle(
        %{
          operation: "com.microsoft:renew-lock",
          body: %{"lock-tokens" => [uuid_binary]},
          correlation_id: binary
        },
        %{
          lock_manager: module_or_fun,   # default Smalt.Amqp.LockManager
          queue_store: module_or_fun,    # default Smalt.Amqp.QueueStore
          now: ms_integer                # optional, defaults SystemTime
        }
      )

  Context fields may be a module (invoked via `apply/3`) or an n-arity
  anonymous function; either is called with the documented signatures.

  Collaborator contracts (lane 3 siblings, PINNED):

    * `LockManager.renew_lock(lock_token, now_ms)` ->
      `{:ok, expiry_ms}` | `{:error, :lock_lost}`

    * `LockManager.renew_session_lock(queue, session_id, now_ms)` ->
      `{:ok, expiry_ms}` | `{:error, :session_lock_lost}`

    * `QueueStore.peek(queue, from_sequence_number: f, message_count: c, now: n)` ->
      `{:ok, [%{body: binary, ...}]}`

    * `QueueStore.receive_deferred(queue, [seq], now_ms: n)` ->
      `{:ok, [%{body: binary, ...}]}` | `{:error, {:not_deferred, [seq]}}`

  Status tables (exact):

    * renew-lock           — 200 {"expirations": [ts]} / 410 MESSAGE_LOCK_LOST /
      400 LOCK_TOKEN_REQUIRED
    * renew-session-lock   — 200 {"expiration": ts} / 410 SESSION_LOCK_LOST /
      400 SESSION_ID_REQUIRED
    * peek-message         — 200 {"messages": [...]} / 204 empty / 400 PEEK_BOUNDS
    * receive-by-sequence-number — 200 {"messages": [...]} (peek envelope) /
      400 SEQUENCE_NUMBERS_REQUIRED / 410 MESSAGE_NOT_DEFERRED (batch-atomic:
      one bad sequence fails the whole batch) / 404 NOT_FOUND
    * set-session-state    — 200 nil / 400 SESSION_ID_REQUIRED /
      400 SESSION_STATE_REQUIRED / 400 SESSION_STATE_SIZE_EXCEEDED (state
      > 256KB, Azure cap) / 404 SESSION_NOT_FOUND
    * get-session-state    — 200 {"session-state": binary} / 400 SESSION_ID_REQUIRED /
      404 SESSION_NOT_FOUND
    * get-message-sessions — 200 {"sessions-ids": [..], "sessions": detail,
      "skip": next} / 400 QUEUE_REQUIRED (the entity rides associated-link-name);
      optional `since-updated-time` (timestamp ms) filter. Detail entries:
      {"session-id", "session-state-size" (bytes), "session-state" (opaque bytes,
      nil when unset), "message-count", "updated-at" (timestamp)}
    * batch-delete-messages — 200 nil / 400 QUEUE_REQUIRED /
      400 SEQUENCE_NUMBERS_REQUIRED / 404 NOT_FOUND (fail-closed on missing tables)
    * schedule-message     — 200 {"sequence-numbers": [..]} / 400 QUEUE_REQUIRED /
      400 MESSAGES_REQUIRED / 400 MALFORMED_MESSAGE / 400 QUEUE_CAPACITY_EXCEEDED
      (KD-118; embedded rhea message decoded via FrameCodec, scheduled time rides
      the x-opt-scheduled-enqueue-time message annotation)
    * cancel-scheduled-message — 200 nil (delete-present semantics: absent
      sequence numbers are skipped, not fatal) / 400 QUEUE_REQUIRED /
      400 SEQUENCE_NUMBERS_REQUIRED / 404 NOT_FOUND (KD-118 sibling)
    * unknown operation    — 501 UNSUPPORTED_OPERATION

  Event Hubs READ ops (KD-19) — keyed on `(operation, type)`:

    * READ type "com.microsoft:eventhub"   — 200 {"name", "created_at",
      "partition_ids": ["0","1"], "georeplication_factor": 1}
    * READ type "com.microsoft:partition"  — 200 {"name", "partition",
      "begin_sequence_number", "last_enqueued_sequence_number",
      "last_enqueued_time_utc", "last_enqueued_offset", "is_partition_empty"} /
      404 PARTITION_NOT_FOUND for a partition outside the hub's partition set

  Timestamps are `{:timestamp, ms}` per `Smalt.Amqp.PrimitiveCodec`.

  ## Split layout (tail-splits ticket T10)

  One fenced family per sibling module under `Smalt.Amqp.ManagementRpc.*`;
  this module keeps the dispatch (`handle/2` + `normalize_op/2`) as the
  facade. Wire-visible behavior is unchanged.

    * `LockRenew`        — com.microsoft:renew-lock
    * `LockRenewSession` — com.microsoft:renew-session-lock
    * `Peek`             — com.microsoft:peek-message
    * `UpdateDisposition`— com.microsoft:update-disposition
    * `ReceiveBySequence`— com.microsoft:receive-by-sequence-number
    * `SessionState`     — set/get-session-state
    * `MessageSessions`  — get-message-sessions (+ get-namespace-usage)
    * `BatchDelete`      — batch-delete-messages
    * `Schedule`         — schedule-message / cancel-scheduled-message
    * `EventHubsRead`    — Event Hubs READ ops (KD-19)
    * `Rules`            — add/remove/enumerate-rules (w6m)
    * `Shared`           — internals shared by the family modules
  """

  alias Smalt.Amqp.ManagementRpc.{
    BatchDelete,
    EventHubsRead,
    LockRenew,
    LockRenewSession,
    MessageSessions,
    Peek,
    ReceiveBySequence,
    Rules,
    Schedule,
    SessionState,
    Shared,
    UpdateDisposition
  }

  # Service Bus operation names (the pre-KD19 surface plus the GAP-A2-05/06/07
  # session/DLQ management surface).
  @sb_ops [
    "com.microsoft:renew-lock",
    "com.microsoft:renew-session-lock",
    "com.microsoft:peek-message",
    "com.microsoft:update-disposition",
    "com.microsoft:receive-by-sequence-number",
    "com.microsoft:set-session-state",
    "com.microsoft:get-session-state",
    "com.microsoft:get-message-sessions",
    "com.microsoft:batch-delete-messages",
    # KD-118: scheduleMessage / cancelScheduledMessages ($management family,
    # core-amqp Constants.operations.scheduleMessage = "com.microsoft:schedule-message").
    "com.microsoft:schedule-message",
    "com.microsoft:cancel-scheduled-message",
    # w6n: namespace usage/quota face ($management family, SMALT extension op
    # following the com.microsoft naming convention).
    "com.microsoft:get-namespace-usage",
    # w6m: topic-subscription RULES (SQL filter subset + correlation filter).
    "com.microsoft:add-rule",
    "com.microsoft:remove-rule",
    "com.microsoft:enumerate-rules"
  ]

  @type request :: %{
          optional(:operation) => term,
          optional(:body) => term,
          optional(:correlation_id) => binary | nil,
          optional(atom) => term
        }

  @type context :: %{
          optional(:lock_manager) => module | fun,
          optional(:queue_store) => module | fun,
          optional(:now) => integer
        }

  @type response :: %{
          status_code: pos_integer,
          status_description: binary,
          body: term,
          correlation_id: binary | nil
        }

  @doc """
  Dispatches one `$management` operation and returns the exact response map.
  """
  @spec handle(request, context) :: response
  def handle(request, context \\ %{})

  def handle(%{operation: op} = request, context) when not is_nil(op) do
    now = Map.get(context, :now, System.system_time(:millisecond))
    correlation_id = Map.get(request, :correlation_id)
    body = Map.get(request, :body, %{})

    case normalize_op(op, Map.get(request, :type)) do
      :renew_lock ->
        LockRenew.handle(body, correlation_id, context, now)

      :renew_session_lock ->
        LockRenewSession.handle(body, request[:queue], correlation_id, context, now)

      :peek_message ->
        Peek.handle(body, request[:queue], correlation_id, context, now)

      :update_disposition ->
        UpdateDisposition.handle(body, request[:queue], correlation_id, context, now)

      :receive_by_sequence_number ->
        ReceiveBySequence.handle(body, request[:queue], correlation_id, context, now)

      :set_session_state ->
        SessionState.set(body, request[:queue], correlation_id, context, now)

      :get_session_state ->
        SessionState.get(body, request[:queue], correlation_id, context, now)

      :get_message_sessions ->
        MessageSessions.handle(body, request[:queue], correlation_id, context, now)

      :batch_delete_messages ->
        BatchDelete.handle(body, request[:queue], correlation_id, context, now)

      # KD-COVERS: KD-118 — scheduleMessage / cancelScheduledMessages.
      :schedule_messages ->
        Schedule.handle(body, request[:queue], correlation_id, context, now)

      :cancel_scheduled_messages ->
        Schedule.cancel(body, request[:queue], correlation_id, context, now)

      # w6n: namespace usage/quota face — live counts over the real stores.
      :get_namespace_usage ->
        MessageSessions.namespace_usage(correlation_id, context)

      # w6m: subscription rules
      :add_rule ->
        Rules.add(body, request[:queue], correlation_id, context, now)

      :remove_rule ->
        Rules.remove(body, request[:queue], correlation_id, context, now)

      :enumerate_rules ->
        Rules.enumerate(body, request[:queue], correlation_id, context, now)

      :read_eventhub ->
        EventHubsRead.eventhub(request, correlation_id, now)

      :read_partition ->
        EventHubsRead.partition(request, correlation_id, now)

      :unknown ->
        Shared.respond(501, "UNSUPPORTED_OPERATION", nil, correlation_id)
    end
  end

  def handle(_request, _context), do: Shared.respond(400, "MALFORMED_REQUEST", nil, nil)

  # ===========================================================================
  # Internals
  # ===========================================================================

  # (operation, type) keyed: the EH READ ops share the "READ" operation name
  # and are discriminated by the entity-type application property.
  defp normalize_op(op, type)

  defp normalize_op(op, _type) when is_binary(op) and op in @sb_ops do
    case op do
      "com.microsoft:renew-lock" -> :renew_lock
      "com.microsoft:renew-session-lock" -> :renew_session_lock
      "com.microsoft:peek-message" -> :peek_message
      "com.microsoft:update-disposition" -> :update_disposition
      "com.microsoft:receive-by-sequence-number" -> :receive_by_sequence_number
      "com.microsoft:set-session-state" -> :set_session_state
      "com.microsoft:get-session-state" -> :get_session_state
      "com.microsoft:get-message-sessions" -> :get_message_sessions
      "com.microsoft:batch-delete-messages" -> :batch_delete_messages
      "com.microsoft:schedule-message" -> :schedule_messages
      "com.microsoft:cancel-scheduled-message" -> :cancel_scheduled_messages
      # w6n: namespace usage/quota face.
      "com.microsoft:get-namespace-usage" -> :get_namespace_usage
      "com.microsoft:add-rule" -> :add_rule
      "com.microsoft:remove-rule" -> :remove_rule
      "com.microsoft:enumerate-rules" -> :enumerate_rules
      _ -> :unknown
    end
  end

  defp normalize_op({:symbol, op}, type) when is_binary(op) do
    case op do
      "com.microsoft:renew-lock" -> :renew_lock
      "com.microsoft:renew-session-lock" -> :renew_session_lock
      "com.microsoft:peek-message" -> :peek_message
      "com.microsoft:update-disposition" -> :update_disposition
      "com.microsoft:receive-by-sequence-number" -> :receive_by_sequence_number
      "com.microsoft:set-session-state" -> :set_session_state
      "com.microsoft:get-session-state" -> :get_session_state
      "com.microsoft:get-message-sessions" -> :get_message_sessions
      "com.microsoft:batch-delete-messages" -> :batch_delete_messages
      "com.microsoft:schedule-message" -> :schedule_messages
      "com.microsoft:cancel-scheduled-message" -> :cancel_scheduled_messages
      # w6n: namespace usage/quota face.
      "com.microsoft:get-namespace-usage" -> :get_namespace_usage
      "com.microsoft:add-rule" -> :add_rule
      "com.microsoft:remove-rule" -> :remove_rule
      "com.microsoft:enumerate-rules" -> :enumerate_rules
      _ -> normalize_read(op, type)
    end
  end

  defp normalize_op(op, type) when is_binary(op) do
    case op do
      "com.microsoft:set-session-state" -> :set_session_state
      "com.microsoft:get-session-state" -> :get_session_state
      "com.microsoft:get-message-sessions" -> :get_message_sessions
      "com.microsoft:batch-delete-messages" -> :batch_delete_messages
      "com.microsoft:schedule-message" -> :schedule_messages
      "com.microsoft:cancel-scheduled-message" -> :cancel_scheduled_messages
      # w6n: namespace usage/quota face.
      "com.microsoft:get-namespace-usage" -> :get_namespace_usage
      "com.microsoft:add-rule" -> :add_rule
      "com.microsoft:remove-rule" -> :remove_rule
      "com.microsoft:enumerate-rules" -> :enumerate_rules
      _ -> normalize_read(op, type)
    end
  end

  defp normalize_op(_op, _type), do: :unknown

  defp normalize_read("READ", "com.microsoft:eventhub"), do: :read_eventhub
  defp normalize_read("READ", "com.microsoft:partition"), do: :read_partition
  defp normalize_read("READ", {:symbol, "com.microsoft:eventhub"}), do: :read_eventhub
  defp normalize_read("READ", {:symbol, "com.microsoft:partition"}), do: :read_partition
  defp normalize_read(_op, _type), do: :unknown
end

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
  """

  alias Smalt.Amqp.RuleStore
  @default_lock_manager Smalt.Amqp.LockManager
  @default_queue_store Smalt.Amqp.QueueStore

  @peek_min 1
  @peek_max 100

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

  # KD-19: hub topology shim — the probe's hub is created with two partitions.
  @eh_partition_ids ["0", "1"]

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
        renew_lock(body, correlation_id, context, now)

      :renew_session_lock ->
        renew_session_lock(body, request[:queue], correlation_id, context, now)

      :peek_message ->
        peek_message(body, request[:queue], correlation_id, context, now)

      :update_disposition ->
        update_disposition(body, request[:queue], correlation_id, context, now)

      :receive_by_sequence_number ->
        receive_by_sequence_number(body, request[:queue], correlation_id, context, now)

      :set_session_state ->
        set_session_state(body, request[:queue], correlation_id, context, now)

      :get_session_state ->
        get_session_state(body, request[:queue], correlation_id, context, now)

      :get_message_sessions ->
        get_message_sessions(body, request[:queue], correlation_id, context, now)

      :batch_delete_messages ->
        batch_delete_messages(body, request[:queue], correlation_id, context, now)

      # KD-COVERS: KD-118 — scheduleMessage / cancelScheduledMessages.
      :schedule_messages ->
        schedule_messages(body, request[:queue], correlation_id, context, now)

      :cancel_scheduled_messages ->
        cancel_scheduled_messages(body, request[:queue], correlation_id, context, now)

      # w6n: namespace usage/quota face — live counts over the real stores.
      :get_namespace_usage ->
        get_namespace_usage(correlation_id, context)

      # w6m: subscription rules
      :add_rule ->
        add_rule(body, request[:queue], correlation_id, context, now)

      :remove_rule ->
        remove_rule(body, request[:queue], correlation_id, context, now)

      :enumerate_rules ->
        enumerate_rules(body, request[:queue], correlation_id, context, now)

      :read_eventhub ->
        read_eventhub(request, correlation_id, now)

      :read_partition ->
        read_partition(request, correlation_id, now)

      :unknown ->
        respond(501, "UNSUPPORTED_OPERATION", nil, correlation_id)
    end
  end

  def handle(_request, _context), do: respond(400, "MALFORMED_REQUEST", nil, nil)

  # ===========================================================================
  # com.microsoft:renew-lock
  # ===========================================================================

  defp renew_lock(body, correlation_id, context, now) do
    lock_tokens =
      body
      |> body_field("lock-tokens")
      |> case do
        # AMQP array-of-uuid (rhea wrap_array) decodes to {:array, elements};
        # a bare list is the internal test form. Same unwrap as
        # update_disposition — List.wrap alone wraps the whole tuple as one
        # bogus token -> normalize_token/1 nil -> LockManager.renew/3
        # FunctionClauseError (uncaught wire crash).
        {:array, toks} when is_list(toks) -> toks
        other -> List.wrap(other)
      end

    cond do
      lock_tokens == [] or lock_tokens == [nil] ->
        respond(400, "LOCK_TOKEN_REQUIRED", nil, correlation_id)

      true ->
        case renew_each(lock_tokens, context, now) do
          {:ok, expirations} ->
            respond(
              200,
              "OK",
              %{"expirations" => Enum.map(expirations, &{:timestamp, &1})},
              correlation_id
            )

          {:error, :lock_lost} ->
            respond(410, "MESSAGE_LOCK_LOST", nil, correlation_id)
        end
    end
  end

  defp renew_each(lock_tokens, context, now, acc \\ [])

  defp renew_each([], _context, _now, acc), do: {:ok, Enum.reverse(acc)}

  defp renew_each([token | rest], context, now, acc) do
    case invoke(context, :lock_manager, @default_lock_manager, :renew_lock, [
           resolve_token(token, context),
           now
         ]) do
      {:ok, expiry_ms} -> renew_each(rest, context, now, [expiry_ms | acc])
      {:error, _reason} -> {:error, :lock_lost}
    end
  end

  # ===========================================================================
  # com.microsoft:renew-session-lock
  # ===========================================================================

  defp renew_session_lock(body, queue_from_request, correlation_id, context, now) do
    session_id = body_field(body, "session-id")
    queue = body_field(body, "queue") || Map.get(body, :queue) || queue_from_request

    cond do
      blank?(session_id) ->
        respond(400, "SESSION_ID_REQUIRED", nil, correlation_id)

      true ->
        case invoke(context, :lock_manager, @default_lock_manager, :renew_session_lock, [
               queue,
               session_id,
               now
             ]) do
          {:ok, expiry_ms} ->
            respond(200, "OK", %{"expiration" => {:timestamp, expiry_ms}}, correlation_id)

          {:error, _reason} ->
            respond(410, "SESSION_LOCK_LOST", nil, correlation_id)
        end
    end
  end

  # ===========================================================================
  # com.microsoft:peek-message
  # ===========================================================================

  defp peek_message(body, queue_from_request, correlation_id, context, now) do
    from_seq = coerce_long(fetch_or(body, "from-sequence-number", 0))
    count = coerce_long(fetch_or(body, "message-count", 1))

    cond do
      from_seq == :error ->
        respond(400, "PEEK_BOUNDS", nil, correlation_id)

      not is_integer(count) or count < @peek_min or count > @peek_max ->
        respond(400, "PEEK_BOUNDS", nil, correlation_id)

      true ->
        case invoke(context, :queue_store, @default_queue_store, :peek, [
               bare_entity(queue_from_request || Map.get(body, :queue)),
               [from_sequence_number: from_seq, message_count: count, now: now]
             ]) do
          {:ok, []} ->
            respond(204, "NO_CONTENT", nil, correlation_id)

          {:ok, messages} when is_list(messages) ->
            payload = %{
              "messages" =>
                Enum.map(messages, fn m ->
                  %{"message" => message_body(m)}
                  |> maybe_put_seq(m)
                  # Wave-1 seam finding: peek of a still-deferred row must
                  # surface its state (Azure reply carries delivery-state).
                  |> maybe_put_delivery_state(m)
                end)
            }

            respond(200, "OK", payload, correlation_id)

          {:error, _reason} ->
            respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # ===========================================================================
  # com.microsoft:update-disposition
  # ===========================================================================

  # Service Bus emulator dialect `com.microsoft:update-disposition`
  # ($management): settles locked deliveries outside the link disposition
  # path. `disposition-status` values per dialect: completed / abandoned /
  # defered / suspended (note the dialect's historic "defered" spelling).
  defp update_disposition(body, queue_from_request, correlation_id, context, now) do
    lock_tokens =
      body
      |> body_field("lock-tokens")
      |> case do
        # AMQP array-of-uuid (rhea wrap_array) decodes to {:array, elements};
        # a bare list is the internal test form. List.wrap alone wraps the
        # whole tuple as one bogus token -> 410 (census dead-letter probe).
        {:array, toks} when is_list(toks) -> toks
        other -> List.wrap(other)
      end

    status = body_field(body, "disposition-status")

    cond do
      lock_tokens == [] or lock_tokens == [nil] ->
        respond(400, "LOCK_TOKEN_REQUIRED", nil, correlation_id)

      blank?(status) ->
        respond(400, "DISPOSITION_STATUS_REQUIRED", nil, correlation_id)

      true ->
        case settle_each(lock_tokens, status, body, bare_entity(queue_from_request), context, now) do
          {:ok, :settled} ->
            respond(200, "OK", nil, correlation_id)

          # R66/D1: unknown disposition-status (e.g. "deferred" vs dialect
          # "defered") is a client input error -> 400, never a lying 410.
          {:error, :bad_status} ->
            respond(400, "DISPOSITION_STATUS_INVALID", nil, correlation_id)

          # R66/D2: settle onto a full store (e.g. deadletter into a full DLQ)
          # is a quota condition -> 400, never 410 MESSAGE_LOCK_LOST.
          {:error, :capacity} ->
            respond(400, "QUEUE_CAPACITY_EXCEEDED", nil, correlation_id)

          {:error, :lock_lost} ->
            respond(410, "MESSAGE_LOCK_LOST", nil, correlation_id)
        end
    end
  end

  defp settle_each([], _status, _body, _queue, _context, _now), do: {:ok, :settled}

  defp settle_each([token | rest], status, body, queue_from_request, context, now) do
    raw = resolve_token(token, context)

    with {:ok, lock} <- fetch_lock(raw, context, now),
         queue = lock[:queue] || queue_from_request,
         {:ok, :settled} <- apply_disposition(status, lock, body, queue, context) do
      settle_each(rest, status, body, queue_from_request, context, now)
    else
      # R66/D2: capacity (e.g. DLQ full) is distinct from a lost lock.
      {:error, :capacity} -> {:error, :capacity}
      # R66/D1: unknown disposition-status is distinct from a lost lock.
      {:error, :bad_status} -> {:error, :bad_status}
      {:error, _reason} -> {:error, :lock_lost}
      :error -> {:error, :lock_lost}
    end
  end

  defp fetch_lock(raw, context, now) do
    case invoke(context, :lock_manager, @default_lock_manager, :get, [raw]) do
      {:ok, %{queue: queue, seq: seq} = lock} when is_binary(queue) and is_integer(seq) ->
        # An EXPIRED lock must settle as 410 MESSAGE_LOCK_LOST, never 200:
        # real Service Bus rejects the disposition and the message redelivers.
        cond do
          not is_integer(lock[:locked_until]) ->
            # Context stubs may omit locked_until; keep the legacy behavior.
            {:ok, %{lock_token: raw, queue: queue, seq: seq}}

          Smalt.Amqp.LockManager.expired?(lock, now) ->
            :error

          true ->
            {:ok, %{lock_token: raw, queue: queue, seq: seq}}
        end

      _ ->
        :error
    end
  end

  defp apply_disposition("completed", lock, _body, queue, context),
    do: store_call(context, queue, :complete, [queue, lock.seq])

  defp apply_disposition("abandoned", lock, _body, queue, context),
    do:
      store_call(context, queue, :release, [
        queue,
        lock.seq,
        [now_ms: System.system_time(:millisecond)]
      ])

  defp apply_disposition("suspended", lock, body, queue, context) do
    reason =
      body_field(body, "dead-letter-reason") || body_field(body, "deadletter-reason") ||
        "DeadLetter"

    description =
      body_field(body, "dead-letter-description") || body_field(body, "deadletter-description")

    # V261014-08 task 08-3: custom dead-letter-properties (string ->
    # primitive map) ride through to the DLQ message's application
    # properties; absent keeps the previous behavior exactly.
    props = body_field(body, "dead-letter-properties") || %{}
    props = if is_map(props), do: props, else: %{}

    store_call(context, queue, :deadletter, [
      queue,
      lock.seq,
      reason,
      description,
      [properties: props]
    ])
  end

  defp apply_disposition("defered", lock, _body, queue, context),
    do: store_call(context, queue, :defer, [queue, lock.seq])

  # R66/D1: unknown disposition-status is a typed error, not the legacy
  # bare :error (which settled as 410 on a perfectly valid unexpired lock).
  defp apply_disposition(_other, _lock, _body, _queue, _context), do: {:error, :bad_status}

  # R66/D2: store failures surface typed. `:capacity` (full DLQ) propagates;
  # genuine lock/store loss stays :lock_lost -> 410.
  defp store_call(context, _queue, name, args) do
    case invoke(context, :queue_store, @default_queue_store, name, args) do
      {:ok, _} -> {:ok, :settled}
      :ok -> {:ok, :settled}
      {:error, :capacity} -> {:error, :capacity}
      _other -> {:error, :lock_lost}
    end
  end

  # ===========================================================================
  # com.microsoft:receive-by-sequence-number
  # ===========================================================================

  # V261014-08 task 08-2. Required body field `sequence-numbers` (long array);
  # optional `receiver-settle-mode` / `associated-link-name` accepted and
  # ignored. Batch semantics: one non-deferred (or missing) sequence number
  # fails the WHOLE batch with 410 MESSAGE_NOT_DEFERRED (atomic, no partial
  # lock) — the chosen emulator semantics, documented here and in
  # QueueStore.receive_deferred/3. Qualifying messages re-lock and re-enter
  # the normal settle path; the reply carries the peek-message envelope.
  defp receive_by_sequence_number(body, queue_from_request, correlation_id, context, now) do
    queue = bare_entity(body_field(body, "queue") || queue_from_request)

    seqs =
      body_field(body, "sequence-numbers")
      |> case do
        {:array, xs} when is_list(xs) -> xs
        xs when is_list(xs) -> xs
        other -> List.wrap(other)
      end
      |> Enum.map(&coerce_long/1)

    cond do
      blank?(queue) ->
        respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      seqs == [] or :error in seqs ->
        respond(400, "SEQUENCE_NUMBERS_REQUIRED", nil, correlation_id)

      true ->
        # Optional `session-id` (sessionful receive-by-sequence): threaded into
        # QueueStore.receive_deferred opts, where a mismatch joins the atomic
        # 410 refusal list (wave-1 seam finding: :477 dropped it).
        session_id_field = body_field(body, "session-id")
        session_id = if blank?(session_id_field), do: nil, else: session_id_field

        case invoke(context, :queue_store, @default_queue_store, :receive_deferred, [
               queue,
               seqs,
               [now_ms: now, session_id: session_id]
             ]) do
          {:ok, messages} when is_list(messages) ->
            payload = %{
              "messages" =>
                Enum.map(messages, fn m ->
                  %{"message" => message_body(m)}
                  |> maybe_put_seq(m)
                  # R178e (census deferred-receive): the 7.10.0 SDK derives the
                  # deferred message's deliveryCount from the decoded embedded
                  # message HEADER (managementClient.js ServiceBusMessageImpl)
                  # and its lockToken from msg["lock-token"] — without them the
                  # probe sees deliveryCount undefined and completes with no
                  # token (410). Real Service Bus carries both in this reply.
                  |> maybe_put_delivery_count(m)
                  |> maybe_put_lock_token(m)
                end)
            }

            respond(200, "OK", payload, correlation_id)

          {:error, {:not_deferred, _missing}} ->
            respond(410, "MESSAGE_NOT_DEFERRED", nil, correlation_id)

          {:error, _reason} ->
            respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # ===========================================================================
  # com.microsoft:set-session-state / get-session-state (GAP-A2-05)
  # ===========================================================================

  # Opaque session state bytes ride the session lock record in
  # `:smalt_sb_sessions` (field :session_state, written by
  # LockManager.do_session_acquire and mutated only here). Emulator semantics
  # (disclosed in the KD row): the state dies with the session lock record —
  # real Service Bus keeps it for the session's lifetime independent of locks.
  defp set_session_state(body, queue_from_request, correlation_id, context, _now) do
    session_id = body_field(body, "session-id")
    state = body_field(body, "session-state")
    queue = body_field(body, "queue") || Map.get(body, :queue) || queue_from_request

    cond do
      blank?(session_id) ->
        respond(400, "SESSION_ID_REQUIRED", nil, correlation_id)

      is_nil(state) ->
        # SDK set_session_state("") clears the state — an empty binary is a
        # legal value; only a truly absent field is malformed.
        respond(400, "SESSION_STATE_REQUIRED", nil, correlation_id)

      state_too_large?(state) ->
        # Azure cap: session state is capped at 256KB
        # (MessagingError "ArgumentOutOfRange"/size exceeded on the real
        # service); emulator surfaces it typed as 400.
        respond(400, "SESSION_STATE_SIZE_EXCEEDED", nil, correlation_id)

      true ->
        case store_call(context, :session_state_put, [queue, session_id, state]) do
          :ok -> respond(200, "OK", nil, correlation_id)
          {:error, :not_found} -> respond(404, "SESSION_NOT_FOUND", nil, correlation_id)
          {:error, _other} -> respond(404, "NOT_FOUND", nil, correlation_id)
          _other -> respond(404, "NOT_FOUND", nil, correlation_id)
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

  defp get_session_state(body, queue_from_request, correlation_id, context, _now) do
    session_id = body_field(body, "session-id")
    queue = body_field(body, "queue") || Map.get(body, :queue) || queue_from_request

    cond do
      blank?(session_id) ->
        respond(400, "SESSION_ID_REQUIRED", nil, correlation_id)

      true ->
        case store_call(context, :session_state_get, [queue, session_id]) do
          {:ok, state} -> respond(200, "OK", %{"session-state" => state}, correlation_id)
          {:error, :not_found} -> respond(404, "SESSION_NOT_FOUND", nil, correlation_id)
          {:error, _other} -> respond(404, "NOT_FOUND", nil, correlation_id)
          _other -> respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # ===========================================================================
  # com.microsoft:get-message-sessions (GAP-A2-06)
  # ===========================================================================

  # Enumerates sessions recorded in `:smalt_sb_sessions` for the entity
  # (resolved from associated-link-name, like renew-session-lock). Body fields
  # `skip`/`top` page the result (both optional, defaults 0/100); the py SDK's
  # browser stops paginating on a page shorter than its `top` (100), so the
  # handler returns the remaining sessions capped at `top` and reports
  # `skip` = skip + returned. Optional `since-updated-time` (AMQP timestamp ms
  # or integer) filters to sessions whose record was touched at/after the
  # instant. Each entry carries the session-state size (bytes), the opaque
  # session-state bytes themselves, the active message count, and the
  # last-updated timestamp; the SDK consumes
  # `sessions-ids`, the detail map rides alongside (additive, wire-safe).
  # w6n: namespace usage/quota face. Read-only over the real stores; typed
  # 404 when the store tables are not materialized (same fail-closed gate
  # shape as the session/batch ops).
  defp get_namespace_usage(correlation_id, context) do
    target = Map.get(context, :namespace_usage, Smalt.Amqp.NamespaceUsage)

    case target.usage() do
      {:ok, usage} ->
        respond(200, "OK", %{"namespace-usage" => usage}, correlation_id)

      {:error, :no_table} ->
        respond(404, "NOT_FOUND", nil, correlation_id)

      other ->
        respond(500, "INTERNAL_ERROR", %{"error" => inspect(other)}, correlation_id)
    end
  end

  defp get_message_sessions(body, queue_from_request, correlation_id, context, _now) do
    queue =
      bare_entity(
        body_field(body, "queue") || Map.get(body, :queue) || queue_from_request
      )
    skip = fetch_or(body, "skip", 0) |> coerce_long()
    top = fetch_or(body, "top", 100) |> coerce_long()
    # KD-COVERS: KD-120
    # KD-120: the TS SDK (managementClient.js:884) sends `last-updated-time`
    # for the since-filter on get-message-sessions; the server key was
    # `since-updated-time` only, making the SDK-native filter dead code.
    # Accept both (SDK key wins if both present) so the SDK-native filter
    # actually filters.
    since =
      case fetch_or(body, "last-updated-time", nil) do
        nil -> fetch_or(body, "since-updated-time", nil) |> coerce_since()
        sdk_since -> coerce_since(sdk_since)
      end

    # KD-120: the SDKs' default listing mode sends last-updated-time =
    # DateTime.MaxValue sentinel (253402300800000 ms, year 10000) — real
    # Azure treats that sentinel as "no filter" (default listing mode), not
    # as a since bound. Clamp it to nil before the store call.
    since =
      case since do
        253_402_300_800_000 -> nil
        other -> other
      end

    cond do
      blank?(queue) ->
        respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      skip == :error or not is_integer(skip) or skip < 0 ->
        respond(400, "SESSION_SKIP_BOUNDS", nil, correlation_id)

      top == :error or not is_integer(top) or top < 1 ->
        respond(400, "SESSION_SKIP_BOUNDS", nil, correlation_id)

      since == :error ->
        respond(400, "SESSION_SKIP_BOUNDS", nil, correlation_id)

      true ->
        case store_call(context, :list_sessions, [
               queue,
               [skip: skip, top: top, since: since]
             ]) do
          {:ok, entries} when is_list(entries) ->
            ids = Enum.map(entries, & &1.session_id)

            detail =
              Enum.map(entries, fn e ->
                %{
                  "session-id" => e.session_id,
                  "session-state-size" => e.session_state_size,
                  "session-state" => e.session_state,
                  "message-count" => e.message_count,
                  "updated-at" => {:timestamp, e.updated_at}
                }
              end)

            respond(
              200,
              "OK",
              %{"sessions-ids" => ids, "sessions" => detail, "skip" => skip + length(ids)},
              correlation_id
            )

          {:error, _reason} ->
            respond(404, "NOT_FOUND", nil, correlation_id)

          _other ->
            respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # ===========================================================================
  # com.microsoft:batch-delete-messages (GAP-A2-07)
  # ===========================================================================

  # Deletes DLQ (or queue) messages by sequence number list: every PRESENT
  # sequence number is deleted and the deleted count returned; absent sequence
  # numbers are skipped, they do NOT fail the batch. Wire surface: SDK body
  # `sequence-numbers` decodes as AMQP array-of-long (the {:array, xs} form,
  # same unwrap as receive-by-sequence-number).
  defp batch_delete_messages(body, queue_from_request, correlation_id, context, _now) do
    queue = body_field(body, "queue") || queue_from_request

    seqs =
      body_field(body, "sequence-numbers")
      |> case do
        {:array, xs} when is_list(xs) -> xs
        xs when is_list(xs) -> xs
        other -> List.wrap(other)
      end
      |> Enum.map(&coerce_long/1)

    cond do
      blank?(queue) ->
        respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      seqs == [] or :error in seqs ->
        respond(400, "SEQUENCE_NUMBERS_REQUIRED", nil, correlation_id)

      true ->
        case store_call(context, :delete_by_sequence, [queue, seqs]) do
          {:ok, deleted} when is_integer(deleted) ->
            _ = deleted
            respond(200, "OK", nil, correlation_id)

          {:error, _reason} ->
            respond(404, "NOT_FOUND", nil, correlation_id)

          _other ->
            respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # ===========================================================================
  # com.microsoft:schedule-message / cancel-scheduled-message (KD-118)
  # ===========================================================================

  # KD-COVERS: KD-118 — the SDK (@azure/service-bus 7.10.0
  # managementClient.js scheduleMessages) sends body {"messages": [entry]}
  # where each entry is a wrap_map {message: <vbin of the encoded rhea
  # message>, "message-id": .., "session-id"?: ..}; the scheduled time rides
  # the EMBEDDED message's x-opt-scheduled-enqueue-time message annotation
  # (core-amqp Constants.scheduledEnqueueTime). Reply: {"sequence-numbers":
  # [long]}. The store arm (QueueStore :scheduled state + claim_candidates'
  # schedule gate) already delivers the row once the time passes; no sweeper
  # change.
  defp schedule_messages(body, queue_from_request, correlation_id, context, _now) do
    queue = bare_entity(body_field(body, "queue") || queue_from_request)
    entries = unwrap_entries(body_field(body, "messages"))

    cond do
      blank?(queue) ->
        respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      is_nil(entries) ->
        respond(400, "MESSAGES_REQUIRED", nil, correlation_id)

      true ->
        case schedule_each(entries, queue, context) do
          {:ok, seqs} ->
            respond(200, "OK", %{"sequence-numbers" => seqs}, correlation_id)

          {:error, :capacity} ->
            respond(400, "QUEUE_CAPACITY_EXCEEDED", nil, correlation_id)

          {:error, :session_required} ->
            respond(400, "SESSION_REQUIRED", nil, correlation_id)

          {:error, _reason} ->
            respond(400, "MALFORMED_MESSAGE", nil, correlation_id)
        end
    end
  end

  defp schedule_each(entries, queue, context, acc \\ [])

  defp schedule_each([], _queue, _context, acc), do: {:ok, Enum.reverse(acc)}

  defp schedule_each([entry | rest], queue, context, acc) do
    case schedule_one(entry, queue, context) do
      {:ok, seq} -> schedule_each(rest, queue, context, [seq | acc])
      {:error, _reason} = err -> err
    end
  end

  defp schedule_one(entry, queue, context) when is_map(entry) do
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
          invoke(context, :queue_store, @default_queue_store, :enqueue, [
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

  defp schedule_one(_entry, _queue, _context), do: {:error, :malformed_entry}

  # Present-but-not-a-positive-timestamp annotation is malformed (R142
  # principle: never silently degrade a schedule to immediate delivery);
  # ABSENT falls through to immediate enqueue (the PT0S case).
  defp bad_scheduled_time?(annotations) do
    case Map.get(annotations, "x-opt-scheduled-enqueue-time") do
      nil -> false
      {:timestamp, ms} when is_integer(ms) and ms >= 0 -> false
      ms when is_integer(ms) and ms >= 0 -> false
      _ -> true
    end
  end

  defp scheduled_time_ms(annotations) do
    case Map.get(annotations, "x-opt-scheduled-enqueue-time") do
      {:timestamp, ms} when is_integer(ms) -> ms
      ms when is_integer(ms) -> ms
      _ -> nil
    end
  end

  defp section_of(sections, kind) when is_list(sections) do
    Enum.find_value(sections, fn
      {^kind, value} -> value
      _ -> nil
    end)
  end

  defp body_section(sections) do
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
  defp cancel_scheduled_messages(body, queue_from_request, correlation_id, context, _now) do
    queue = body_field(body, "queue") || queue_from_request

    seqs =
      body_field(body, "sequence-numbers")
      |> unwrap_entries()
      |> Enum.map(&coerce_seq_long/1)

    cond do
      blank?(queue) ->
        respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      seqs == [] or :error in seqs ->
        respond(400, "SEQUENCE_NUMBERS_REQUIRED", nil, correlation_id)

      true ->
        result =
          Enum.reduce_while(seqs, :ok, fn seq, :ok ->
            case store_call(context, :cancel_scheduled, [bare_entity(queue), seq]) do
              :ok -> {:cont, :ok}
              {:error, :not_found} -> {:cont, :ok}
              {:error, :not_scheduled} -> {:cont, :ok}
              {:error, _other} -> {:halt, {:error, :store}}
              _other -> {:halt, {:error, :store}}
            end
          end)

        case result do
          :ok -> respond(200, "OK", nil, correlation_id)
          {:error, :store} -> respond(404, "NOT_FOUND", nil, correlation_id)
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

  # ===========================================================================
  # Event Hubs READ ops (KD-19)
  # ===========================================================================

  # Hub runtime info. The SDK (managementClient.js getEventHubProperties)
  # reads info.created_at via new Date(...) — an AMQP timestamp section
  # ({:timestamp, ms}) round-trips as a Date.
  defp read_eventhub(request, correlation_id, now) do
    respond(
      200,
      "OK",
      %{
        "name" => eh_entity(request),
        "created_at" => {:timestamp, now},
        "partition_ids" => @eh_partition_ids,
        "georeplication_factor" => 1
      },
      correlation_id
    )
  end

  # Partition runtime info. READ is non-mutating: the last enqueued sequence is
  # read from the EventHubs store table directly (EventHubs.next_sequence/1
  # BUMPS the counter, which would burn sequence numbers and mint rows for
  # unknown partitions on every poll).
  defp read_partition(request, correlation_id, now) do
    partition = to_string(request[:partition] || "")

    if partition in @eh_partition_ids do
      Smalt.Messaging.EventHubs.ensure_tables()
      row = eh_partition_row(eh_entity(request), partition)
      last = eh_last_seq(row)

      respond(
        200,
        "OK",
        %{
          "name" => eh_entity(request),
          "partition" => partition,
          "begin_sequence_number" => 1,
          "last_enqueued_sequence_number" => last,
          "last_enqueued_time_utc" => {:timestamp, if(last == 0, do: 0, else: now)},
          "last_enqueued_offset" => to_string(last),
          "is_partition_empty" => last == 0
        },
        correlation_id
      )
    else
      respond(404, "PARTITION_NOT_FOUND", nil, correlation_id)
    end
  end

  # Entity name rides the "name" application property (managementClient.js
  # puts it there; the request body is the JSON literal "[]").
  defp eh_entity(request) do
    case request[:name] do
      nil -> request[:queue] || ""
      name -> to_string(name)
    end
  end

  # KD-COVERS: KD-128 — partition rows in :smalt_eh_partitions are keyed
  # "<ns>/partitions/<hub>/partitions/<p>"-style composite keys (the store
  # side writes "<hub>/partitions/<p>"; KD-68: identity is hub-scoped), so a
  # bare-partition :ets.lookup always missed and every $management partition
  # readout reported last_enqueued_sequence_number = 0. Match the real key by
  # the "<hub>/partitions/<p>" suffix (exact-first), shortest key wins when
  # several namespace spellings exist — same discipline as
  # Smalt.ARM.EhArm.partition_metrics/2.
  defp eh_partition_row(hub, partition) do
    suffix = "/#{hub}/partitions/#{partition}"
    exact = String.trim_leading(suffix, "/")

    :smalt_eh_partitions
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _} -> is_binary(key) and (key == exact or String.ends_with?(key, suffix)) end)
    |> Enum.sort_by(fn {key, _} -> byte_size(key) end)
    |> case do
      [{_key, row} | _] when is_map(row) -> row
      _ -> %{}
    end
  end

  defp eh_last_seq(row) when is_map(row) do
    case row["seq"] do
      seq when is_integer(seq) -> seq
      _ -> 0
    end
  end


  # ===========================================================================
  # com.microsoft:add-rule / remove-rule / enumerate-rules (w6m)
  # ===========================================================================

  # The entity rides the $management node address: the SDK opens
  # "<topic>/Subscriptions/<sub>/$management" (managementClient.js toPath) so
  # request[:queue] arrives as the subscription path. addRule sends body
  # {"rule-name": wrap_string, "rule-description": wrap_map} where the map is
  # {"sql-filter": {"expression": s}} or {"correlation-filter": {..}}; the
  # optional "sql-rule-action": {"expression": s} is stored and echoed on
  # enumerate, never evaluated (documented subset).
  defp add_rule(body, queue_from_request, correlation_id, _context, _now) do
    entity = bare_entity(body_field(body, "queue") || queue_from_request)
    name = body_field(body, "rule-name")
    desc = body_field(body, "rule-description")

    cond do
      blank?(entity) or is_nil(RuleStore.split_sub_path(entity)) ->
        respond(400, "SUBSCRIPTION_PATH_REQUIRED", nil, correlation_id)

      blank?(name) ->
        respond(400, "RULE_NAME_REQUIRED", nil, correlation_id)

      not is_map(desc) ->
        respond(400, "RULE_DESCRIPTION_REQUIRED", nil, correlation_id)

      true ->
        filter = parse_rule_filter(desc)

        if filter == :error do
          respond(400, "RULE_FILTER_INVALID", nil, correlation_id)
        else
          {topic, sub} = RuleStore.split_sub_path(entity)
          action = rule_action(desc)

          case RuleStore.add_rule(topic, sub, name, filter, action) do
            {:ok, _rule} -> respond(200, "OK", nil, correlation_id)
            {:error, :bad_filter} -> respond(400, "RULE_FILTER_INVALID", nil, correlation_id)
            _other -> respond(409, "RULE_ALREADY_EXISTS", nil, correlation_id)
          end
        end
    end
  end

  defp parse_rule_filter(%{"sql-filter" => %{"expression" => expr}}) when is_binary(expr) do
    down = String.downcase(expr)

    cond do
      down == "1=1" -> :true
      down == "1=0" -> :false
      true -> {:sql, expr}
    end
  end

  defp parse_rule_filter(%{"sql-filter" => %{expression: expr}}) when is_binary(expr),
    do: parse_rule_filter(%{"sql-filter" => %{"expression" => expr}})

  defp parse_rule_filter(%{"correlation-filter" => corr}) when is_map(corr),
    do: {:correlation, corr}

  defp parse_rule_filter(_), do: :error

  defp rule_action(desc) do
    case desc["sql-rule-action"] do
      %{"expression" => expr} when is_binary(expr) -> expr
      %{expression: expr} when is_binary(expr) -> expr
      _ -> nil
    end
  end

  defp remove_rule(body, queue_from_request, correlation_id, _context, _now) do
    entity = bare_entity(body_field(body, "queue") || queue_from_request)
    name = body_field(body, "rule-name")

    cond do
      blank?(entity) or is_nil(RuleStore.split_sub_path(entity)) ->
        respond(400, "SUBSCRIPTION_PATH_REQUIRED", nil, correlation_id)

      blank?(name) ->
        respond(400, "RULE_NAME_REQUIRED", nil, correlation_id)

      true ->
        {topic, sub} = RuleStore.split_sub_path(entity)

        case RuleStore.remove_rule(topic, sub, name) do
          :ok -> respond(200, "OK", nil, correlation_id)
          {:error, :not_found} -> respond(404, "RULE_NOT_FOUND", nil, correlation_id)
          _other -> respond(404, "RULE_NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # enumerate-rules body: {top, skip} wrapped ints; reply {"rules": [...]}.
  # Each entry is {"rule-name": str, "rule-description": described}; the SDK
  # skips any entry whose rule-description lacks the expected descriptor, so
  # the described wire form is load-bearing (RuleStore.wire_description/1).
  defp enumerate_rules(body, queue_from_request, correlation_id, _context, _now) do
    entity = bare_entity(body_field(body, "queue") || queue_from_request)

    skip = coerce_long(fetch_or(body, "skip", 0))
    top = coerce_long(fetch_or(body, "top", 100))

    cond do
      blank?(entity) or is_nil(RuleStore.split_sub_path(entity)) ->
        respond(400, "SUBSCRIPTION_PATH_REQUIRED", nil, correlation_id)

      skip == :error or not is_integer(skip) or skip < 0 ->
        respond(400, "RULE_PAGING_BOUNDS", nil, correlation_id)

      top == :error or not is_integer(top) or top < 1 ->
        respond(400, "RULE_PAGING_BOUNDS", nil, correlation_id)

      true ->
        {topic, sub} = RuleStore.split_sub_path(entity)
        {:ok, rules} = RuleStore.list_rules(topic, sub)

        entries =
          rules
          |> Enum.drop(skip)
          |> Enum.take(top)
          |> Enum.map(&RuleStore.wire_description/1)

        respond(200, "OK", %{"rules" => entries}, correlation_id)
    end
  end

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

  # Fail-closed store gate for the session/batch ops: when the Store tables are
  # not materialized, refuse typed (404 NOT_FOUND at the call sites) instead of
  # letting a badarg escape the management dispatch. The gate consults the
  # effective queue_store collaborator's tables_ready?/0 (real store in prod,
  # injectable double in unit tests). Normalizes the store's :error (absent
  # key) into {:error, :not_found}.
  defp store_call(context, name, args) do
    target = Map.get(context, :queue_store, @default_queue_store)

    ready =
      cond do
        is_atom(target) and function_exported?(target, :tables_ready?, 0) ->
          target.tables_ready?()

        is_atom(target) ->
          @default_queue_store.tables_ready?()

        # anonymous-fun collaborators (unit-test form): gate not observable.
        true ->
          true
      end

    if ready do
      case invoke(context, :queue_store, @default_queue_store, name, args) do
        :ok -> :ok
        {:ok, _} = ok -> ok
        :error -> {:error, :not_found}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    else
      {:error, :no_table}
    end
  end

  defp normalize_read("READ", "com.microsoft:eventhub"), do: :read_eventhub
  defp normalize_read("READ", "com.microsoft:partition"), do: :read_partition
  defp normalize_read("READ", {:symbol, "com.microsoft:eventhub"}), do: :read_eventhub
  defp normalize_read("READ", {:symbol, "com.microsoft:partition"}), do: :read_partition
  defp normalize_read(_op, _type), do: :unknown

  defp body_field(body, key) when is_map(body), do: Map.get(body, key)

  defp body_field(_body, _key), do: nil

  # Present-but-nil is invalid (400); absent falls back to the default.
  defp fetch_or(body, key, default) when is_map(body) do
    if Map.has_key?(body, key), do: Map.get(body, key), else: default
  end

  defp fetch_or(_body, _key, default), do: default

  # Wire tokens are raw 16-byte AMQP uuid values; the lock store keys them as
  # dashed lowercase strings (LockManager.new_token/0). rhea string_to_uuid
  # round-trips the delivered token, so normalize before lookup.
  # Wire lock tokens arrive as raw uuid values the SDK already reordered
  # .NET-GUID style (LockManager.token_to_wire/1, shouldReorderLockToken: true).
  # The reorder is an involution, so applying it once more restores the raw
  # layout before format_uuid; straight-formatting the delivered bytes minted
  # a permuted store key and 410s on every live-lock settle/renew.
  defp normalize_token({:uuid, <<b0, b1, b2, b3, b4, b5, b6, b7, rest::binary-size(8)>>}) do
    Smalt.Amqp.LockManager.format_uuid(<<b3, b2, b1, b0, b5, b4, b7, b6, rest::binary>>)
  end

  defp normalize_token(token) when is_binary(token), do: token
  defp normalize_token(token) when is_integer(token), do: token
  defp normalize_token(_other), do: nil

  # R178e (census replay witness, @azure/service-bus 7.10.0): the SDK echoes
  # lock tokens in TWO wire dialects. Non-session receivers format the
  # delivered tag straight (rhea uuid_to_string) and echo the .NET-GUID
  # permuted bytes; session-dialect receivers run the tag through
  # reorderLockToken first (serviceBusMessage.js shouldReorderLockToken), so
  # their management echo carries the STRAIGHT bytes of the store key.
  # Unconditional unpermutation (normalize_token) made exactly one family
  # miss the lock store on every settle/renew -> 410 MESSAGE_LOCK_LOST
  # cascades. Resolution is disjunctive and store-adjudicated: try the
  # unpermuted key first (legacy contract + unit-test dialect), fall back to
  # the straight-formatted bytes; only a key actually present in the lock
  # store wins.
  defp resolve_token(token, context) do
    primary = normalize_token(token)
    alt = straight_token(token)

    cond do
      is_nil(alt) -> primary
      lock_row_exists?(primary, context) -> primary
      true -> alt
    end
  end

  defp straight_token({:uuid, <<_::binary-size(16)>> = uuid}) do
    Smalt.Amqp.LockManager.format_uuid(uuid)
  end

  defp straight_token(_other), do: nil

  # Store-backed existence probe through the same seam the settle path uses,
  # so context-injected test stubs keep adjudicating.
  defp lock_row_exists?(raw, context) do
    match?({:ok, _}, invoke(context, :lock_manager, @default_lock_manager, :get, [raw]))
  end

  defp coerce_long(n) when is_integer(n), do: n
  defp coerce_long(n) when is_float(n), do: trunc(n)

  defp coerce_long(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp coerce_long(_), do: :error

  # since-updated-time: AMQP timestamp section ({:timestamp, ms}) or raw
  # integer ms; absent/nil -> nil (no filter). Anything else is :error (400).
  defp coerce_since(nil), do: nil
  defp coerce_since({:timestamp, ms}) when is_integer(ms), do: ms
  defp coerce_since(ms) when is_integer(ms), do: ms
  defp coerce_since(_), do: :error

  # R135 (W5-17): management ops that resolve an entity by name must accept
  # URI-form queue fields ("amqps://host:5671/q") the same way link attach
  # addresses already normalize via Connection.bare_entity/1 (R96/R129).
  # Local copy because that function is private to connection.ex; keep the
  # two in sync. Deliberately not applied to $management request dispatch
  # itself — only to entity resolution inside individual op handlers.
  defp bare_entity(address) when is_binary(address) do
    case String.split(address, "://", parts: 2) do
      [scheme, rest] when scheme in ["amqp", "amqps", "sb"] ->
        case String.split(rest, "/", parts: 2) do
          [_host, entity] when is_binary(entity) and entity != "" ->
            case String.trim_trailing(entity, "/") do
              "" -> address
              bare -> bare
            end

          _ ->
            address
        end

      _ ->
        # R178c (R129 sync): BARE entity names take the same gate — "q/" is a
        # shadow namespace of "q" and used to slip past the scheme-form
        # stripping (no "://" -> pass through). Trim trailing slashes so
        # "q/" normalizes to "q"; empty-after-strip ("/") keeps the address
        # unchanged, still failing closed.
        case String.trim_trailing(address, "/") do
          "" -> address
          bare -> bare
        end
    end
  end

  defp bare_entity(other), do: other

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Context fields may be modules (apply/3) or plain functions.
  defp invoke(context, key, default, name, args) do
    target = Map.get(context, key, default)

    case target do
      fun when is_function(fun, length(args)) -> apply(fun, args)
      fun when is_function(fun) -> raise ArgumentError, "bad arity for #{key}: #{inspect(fun)}"
      mod when is_atom(mod) -> apply(mod, name, args)
    end
  end

  defp respond(status_code, status_description, body, correlation_id) do
    %{
      status_code: status_code,
      status_description: status_description,
      body: body,
      correlation_id: correlation_id
    }
  end

  # Peeked messages carry their per-queue sequence number; the SDK's
  # ManagementClient tracks _lastPeekedSequenceNumber from the embedded raw
  # message's x-opt-sequence-number annotation.
  defp maybe_put_seq(map, %{seq: seq}) when is_integer(seq),
    do: Map.put(map, "sequence-number", seq)

  defp maybe_put_seq(map, _), do: map

  # Peek envelope surfaces the row's settlement state for non-live rows
  # (still-deferred rows read `delivery-state: deferred`); live rows are
  # stateless from the SDK's perspective and stay unlabeled.
  defp maybe_put_delivery_state(map, %{state: :deferred}),
    do: Map.put(map, "delivery-state", "deferred")

  defp maybe_put_delivery_state(map, %{state: :dead}),
    do: Map.put(map, "delivery-state", "suspended")

  defp maybe_put_delivery_state(map, _), do: map

  # R178e: the receive-by-sequence reply must carry the message HEADER
  # delivery-count (the SDK reads deliveryCount from the decoded header, not
  # from the envelope) and the lock-token uuid (the SDK uses it as the
  # delivery tag for later settle). Normalized into wire sections by
  # Connection.normalize_mgmt_message/1. (Merged duplicate clause blocks,
  # lane 243: wire form kept — {:uuid, LockManager.token_to_wire/1} — string
  # raw-token form removed as unreachable.)
  defp maybe_put_delivery_count(map, %{delivery_count: dc}) when is_integer(dc),
    do: Map.put(map, "delivery-count", dc)

  defp maybe_put_delivery_count(map, _), do: map

  defp maybe_put_lock_token(map, %{lock_token: t}) when is_binary(t),
    do: Map.put(map, "lock-token", {:uuid, Smalt.Amqp.LockManager.token_to_wire(t)})

  defp maybe_put_lock_token(map, _), do: map

  defp message_body(%{body: body}), do: body
  defp message_body(%{"body" => body}), do: body
  defp message_body(binary) when is_binary(binary), do: binary
  defp message_body(other), do: other
end

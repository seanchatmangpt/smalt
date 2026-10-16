defmodule Smalt.Amqp.ManagementRpc do
  require Logger
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

  @default_lock_manager Smalt.Amqp.LockManager
  @default_queue_store Smalt.Amqp.QueueStore

  @peek_min 1
  @peek_max 100

  # Service Bus operation names (the pre-KD19 surface).
  @sb_ops ["com.microsoft:renew-lock", "com.microsoft:renew-session-lock",
           "com.microsoft:peek-message", "com.microsoft:update-disposition",
           "com.microsoft:receive-by-sequence-number"]

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
      :renew_lock -> renew_lock(body, correlation_id, context, now)
      :renew_session_lock -> renew_session_lock(body, request[:queue], correlation_id, context, now)
      :peek_message -> peek_message(body, request[:queue], correlation_id, context, now)
      :update_disposition -> update_disposition(body, request[:queue], correlation_id, context, now)
      :receive_by_sequence_number -> receive_by_sequence_number(body, request[:queue], correlation_id, context, now)
      :read_eventhub -> read_eventhub(request, correlation_id, now)
      :read_partition -> read_partition(request, correlation_id, now)
      :unknown -> respond(501, "UNSUPPORTED_OPERATION", nil, correlation_id)
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
      |> List.wrap()

    cond do
      lock_tokens == [] or lock_tokens == [nil] ->
        respond(400, "LOCK_TOKEN_REQUIRED", nil, correlation_id)

      true ->
        case renew_each(lock_tokens, context, now) do
          {:ok, expirations} ->
            respond(200, "OK", %{"expirations" => Enum.map(expirations, &{:timestamp, &1})},
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
           normalize_token(token),
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
               queue_from_request || Map.get(body, :queue),
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
        case settle_each(lock_tokens, status, body, queue_from_request, context, now) do
          {:ok, :settled} ->
            respond(200, "OK", nil, correlation_id)

          {:error, :lock_lost} ->
            respond(410, "MESSAGE_LOCK_LOST", nil, correlation_id)
        end
    end
  end

  defp settle_each([], _status, _body, _queue, _context, _now), do: {:ok, :settled}

  defp settle_each([token | rest], status, body, queue_from_request, context, now) do
    raw = normalize_token(token)

    with {:ok, lock} <- fetch_lock(raw, context),
         queue = lock[:queue] || queue_from_request,
         {:ok, :settled} <- apply_disposition(status, lock, body, queue, context) do
      settle_each(rest, status, body, queue_from_request, context, now)
    else
      {:error, _reason} -> {:error, :lock_lost}
      :error -> {:error, :lock_lost}
    end
  end

  defp fetch_lock(raw, context) do
    case invoke(context, :lock_manager, @default_lock_manager, :get, [raw]) do
      {:ok, %{queue: queue, seq: seq}} when is_binary(queue) and is_integer(seq) ->
        {:ok, %{lock_token: raw, queue: queue, seq: seq}}

      _ ->
        :error
    end
  end

  defp apply_disposition("completed", lock, _body, queue, context),
    do: store_call(context, queue, :complete, [queue, lock.seq])

  defp apply_disposition("abandoned", lock, _body, queue, context),
    do: store_call(context, queue, :release, [queue, lock.seq, [now_ms: System.system_time(:millisecond)]])

  defp apply_disposition("suspended", lock, body, queue, context) do
    reason = body_field(body, "dead-letter-reason") || body_field(body, "deadletter-reason") || "DeadLetter"
    description = body_field(body, "dead-letter-description") || body_field(body, "deadletter-description")

    # V261014-08 task 08-3: custom dead-letter-properties (string ->
    # primitive map) ride through to the DLQ message's application
    # properties; absent keeps the previous behavior exactly.
    props = body_field(body, "dead-letter-properties") || %{}
    props = if is_map(props), do: props, else: %{}

    store_call(context, queue, :deadletter, [queue, lock.seq, reason, description, [properties: props]])
  end

  defp apply_disposition("defered", lock, _body, queue, context),
    do: store_call(context, queue, :defer, [queue, lock.seq])

  defp apply_disposition(_other, _lock, _body, _queue, _context), do: :error

  defp store_call(context, _queue, name, args) do
    case invoke(context, :queue_store, @default_queue_store, name, args) do
      {:ok, _} -> {:ok, :settled}
      :ok -> {:ok, :settled}
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
        case invoke(context, :queue_store, @default_queue_store, :receive_deferred, [queue, seqs, [now_ms: now]]) do
          {:ok, messages} when is_list(messages) ->
            payload = %{
              "messages" =>
                Enum.map(messages, fn m ->
                  %{"message" => message_body(m)}
                  |> maybe_put_seq(m)
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
  # Event Hubs READ ops (KD-19)
  # ===========================================================================

  # Hub runtime info. The SDK (managementClient.js getEventHubProperties)
  # reads info.created_at via new Date(...) — an AMQP timestamp section
  # ({:timestamp, ms}) round-trips as a Date.
  defp read_eventhub(request, correlation_id, now) do
    respond(200, "OK", %{
      "name" => eh_entity(request),
      "created_at" => {:timestamp, now},
      "partition_ids" => @eh_partition_ids,
      "georeplication_factor" => 1
    }, correlation_id)
  end

  # Partition runtime info. READ is non-mutating: the last enqueued sequence is
  # read from the EventHubs store table directly (EventHubs.next_sequence/1
  # BUMPS the counter, which would burn sequence numbers and mint rows for
  # unknown partitions on every poll).
  defp read_partition(request, correlation_id, now) do
    partition = to_string(request[:partition] || "")

    if partition in @eh_partition_ids do
      Smalt.Messaging.EventHubs.ensure_tables()
      row = eh_partition_row(partition)
      last = eh_last_seq(row)

      respond(200, "OK", %{
        "name" => eh_entity(request),
        "partition" => partition,
        "begin_sequence_number" => 1,
        "last_enqueued_sequence_number" => last,
        "last_enqueued_time_utc" => {:timestamp, if(last == 0, do: 0, else: now)},
        "last_enqueued_offset" => to_string(last),
        "is_partition_empty" => last == 0
      }, correlation_id)
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

  defp eh_partition_row(partition) do
    case :ets.lookup(:smalt_eh_partitions, partition) do
      [{^partition, row}] when is_map(row) -> row
      _ -> %{}
    end
  end

  defp eh_last_seq(row) when is_map(row) do
    case row["seq"] do
      seq when is_integer(seq) -> seq
      _ -> 0
    end
  end

  defp eh_last_seq(_), do: 0

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
      _ -> normalize_read(op, type)
    end
  end

  defp normalize_op(op, type) when is_binary(op) do
    normalize_read(op, type)
  end

  defp normalize_op(_op, _type), do: :unknown

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
  defp normalize_token({:uuid, <<_::128>> = raw}), do: Smalt.Amqp.LockManager.format_uuid(raw)
  defp normalize_token(token) when is_binary(token), do: token
  defp normalize_token(token) when is_integer(token), do: token
  defp normalize_token(_other), do: nil

  defp coerce_long(n) when is_integer(n), do: n
  defp coerce_long(n) when is_float(n), do: trunc(n)
  defp coerce_long(binary) when is_binary(binary) do
    case Integer.parse(binary) do
      {n, ""} -> n
      _ -> :error
    end
  end
  defp coerce_long(_), do: :error

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

  defp message_body(%{body: body}), do: body
  defp message_body(%{"body" => body}), do: body
  defp message_body(binary) when is_binary(binary), do: binary
  defp message_body(other), do: other
end

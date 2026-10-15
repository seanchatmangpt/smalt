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

  Status tables (exact):

    * renew-lock           — 200 {"expirations": [ts]} / 410 MESSAGE_LOCK_LOST /
      400 LOCK_TOKEN_REQUIRED
    * renew-session-lock   — 200 {"expiration": ts} / 410 SESSION_LOCK_LOST /
      400 SESSION_ID_REQUIRED
    * peek-message         — 200 {"messages": [...]} / 204 empty / 400 PEEK_BOUNDS
    * unknown operation    — 501 UNSUPPORTED_OPERATION

  Timestamps are `{:timestamp, ms}` per `Smalt.Amqp.PrimitiveCodec`.
  """

  @default_lock_manager Smalt.Amqp.LockManager
  @default_queue_store Smalt.Amqp.QueueStore

  @peek_min 1
  @peek_max 100

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

    case normalize_op(op) do
      :renew_lock -> renew_lock(body, correlation_id, context, now)
      :renew_session_lock -> renew_session_lock(body, correlation_id, context, now)
      :peek_message -> peek_message(body, correlation_id, context, now)
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

  defp renew_session_lock(body, correlation_id, context, now) do
    session_id = body_field(body, "session-id")
    queue = body_field(body, "queue") || Map.get(body, :queue)

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

  defp peek_message(body, correlation_id, context, now) do
    from_seq = coerce_long(fetch_or(body, "from-sequence-number", 0))
    count = coerce_long(fetch_or(body, "message-count", 1))

    cond do
      from_seq == :error ->
        respond(400, "PEEK_BOUNDS", nil, correlation_id)

      not is_integer(count) or count < @peek_min or count > @peek_max ->
        respond(400, "PEEK_BOUNDS", nil, correlation_id)

      true ->
        case invoke(context, :queue_store, @default_queue_store, :peek, [
               Map.get(body, :queue),
               [from_sequence_number: from_seq, message_count: count, now: now]
             ]) do
          {:ok, []} ->
            respond(204, "NO_CONTENT", nil, correlation_id)

          {:ok, messages} when is_list(messages) ->
            payload = %{"messages" => Enum.map(messages, &%{"message" => message_body(&1)})}

            respond(200, "OK", payload, correlation_id)

          {:error, _reason} ->
            respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp normalize_op(op) do
    case op do
      "com.microsoft:renew-lock" -> :renew_lock
      "com.microsoft:renew-session-lock" -> :renew_session_lock
      "com.microsoft:peek-message" -> :peek_message
      {:symbol, "com.microsoft:renew-lock"} -> :renew_lock
      {:symbol, "com.microsoft:renew-session-lock"} -> :renew_session_lock
      {:symbol, "com.microsoft:peek-message"} -> :peek_message
      _ -> :unknown
    end
  end

  defp body_field(body, key) when is_map(body), do: Map.get(body, key)

  defp body_field(_body, _key), do: nil

  # Present-but-nil is invalid (400); absent falls back to the default.
  defp fetch_or(body, key, default) when is_map(body) do
    if Map.has_key?(body, key), do: Map.get(body, key), else: default
  end

  defp fetch_or(_body, _key, default), do: default

  defp normalize_token({:uuid, raw}) when is_binary(raw), do: raw
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

  defp message_body(%{body: body}), do: body
  defp message_body(%{"body" => body}), do: body
  defp message_body(binary) when is_binary(binary), do: binary
  defp message_body(other), do: other
end

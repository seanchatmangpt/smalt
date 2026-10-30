defmodule Smalt.Amqp.ManagementRpc.UpdateDisposition do
  @moduledoc """
  `com.microsoft:update-disposition` — extracted verbatim from the pre-split
  `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10); bodies
  byte-identical, `defp` promoted to `def` on the handler entry only. The
  settle-path `store_call/4` variant stays private here (only this fence
  used it); the session/batch `store_call/3` gate lives in `Shared`.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  # Service Bus emulator dialect `com.microsoft:update-disposition`
  # ($management): settles locked deliveries outside the link disposition
  # path. `disposition-status` values per dialect: completed / abandoned /
  # defered / suspended (note the dialect's historic "defered" spelling).
  def handle(body, queue_from_request, correlation_id, context, now) do
    lock_tokens =
      body
      |> Shared.body_field("lock-tokens")
      |> case do
        # AMQP array-of-uuid (rhea wrap_array) decodes to {:array, elements};
        # a bare list is the internal test form. List.wrap alone wraps the
        # whole tuple as one bogus token -> 410 (census dead-letter probe).
        {:array, toks} when is_list(toks) -> toks
        other -> List.wrap(other)
      end

    status = Shared.body_field(body, "disposition-status")

    cond do
      lock_tokens == [] or lock_tokens == [nil] ->
        Shared.respond(400, "LOCK_TOKEN_REQUIRED", nil, correlation_id)

      Shared.blank?(status) ->
        Shared.respond(400, "DISPOSITION_STATUS_REQUIRED", nil, correlation_id)

      true ->
        case settle_each(lock_tokens, status, body, Shared.bare_entity(queue_from_request), context, now) do
          {:ok, :settled} ->
            Shared.respond(200, "OK", nil, correlation_id)

          # R66/D1: unknown disposition-status (e.g. "deferred" vs dialect
          # "defered") is a client input error -> 400, never a lying 410.
          {:error, :bad_status} ->
            Shared.respond(400, "DISPOSITION_STATUS_INVALID", nil, correlation_id)

          # R66/D2: settle onto a full store (e.g. deadletter into a full DLQ)
          # is a quota condition -> 400, never 410 MESSAGE_LOCK_LOST.
          {:error, :capacity} ->
            Shared.respond(400, "QUEUE_CAPACITY_EXCEEDED", nil, correlation_id)

          {:error, :lock_lost} ->
            Shared.respond(410, "MESSAGE_LOCK_LOST", nil, correlation_id)
        end
    end
  end

  def settle_each([], _status, _body, _queue, _context, _now), do: {:ok, :settled}

  def settle_each([token | rest], status, body, queue_from_request, context, now) do
    raw = Shared.resolve_token(token, context)

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
    case Shared.invoke(context, :lock_manager, Smalt.Amqp.LockManager, :get, [raw]) do
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
      Shared.body_field(body, "dead-letter-reason") || Shared.body_field(body, "deadletter-reason") ||
        "DeadLetter"

    description =
      Shared.body_field(body, "dead-letter-description") || Shared.body_field(body, "deadletter-description")

    # V261014-08 task 08-3: custom dead-letter-properties (string ->
    # primitive map) ride through to the DLQ message's application
    # properties; absent keeps the previous behavior exactly.
    props = Shared.body_field(body, "dead-letter-properties") || %{}
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
    case Shared.invoke(context, :queue_store, Smalt.Amqp.QueueStore, name, args) do
      {:ok, _} -> {:ok, :settled}
      :ok -> {:ok, :settled}
      {:error, :capacity} -> {:error, :capacity}
      _other -> {:error, :lock_lost}
    end
  end
end

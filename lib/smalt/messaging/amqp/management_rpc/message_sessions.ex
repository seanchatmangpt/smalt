defmodule Smalt.Amqp.ManagementRpc.MessageSessions do
  @moduledoc """
  `com.microsoft:get-message-sessions` (GAP-A2-06) — extracted verbatim from
  the pre-split `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10);
  bodies byte-identical, `defp` promoted to `def` on the handler entries only.
  The `get-namespace-usage` handler is included here because it sits inside
  this fence in the pre-split source (disclosed placement).
  """

  alias Smalt.Amqp.ManagementRpc.Shared

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
  def handle(body, queue_from_request, correlation_id, context, _now) do
    queue =
      Shared.bare_entity(
        Shared.body_field(body, "queue") || Map.get(body, :queue) || queue_from_request
      )
    skip = Shared.fetch_or(body, "skip", 0) |> Shared.coerce_long()
    top = Shared.fetch_or(body, "top", 100) |> Shared.coerce_long()
    # KD-COVERS: KD-120
    # KD-120: the TS SDK (managementClient.js:884) sends `last-updated-time`
    # for the since-filter on get-message-sessions; the server key was
    # `since-updated-time` only, making the SDK-native filter dead code.
    # Accept both (SDK key wins if both present) so the SDK-native filter
    # actually filters.
    since =
      case Shared.fetch_or(body, "last-updated-time", nil) do
        nil -> Shared.fetch_or(body, "since-updated-time", nil) |> Shared.coerce_since()
        sdk_since -> Shared.coerce_since(sdk_since)
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
      Shared.blank?(queue) ->
        Shared.respond(400, "QUEUE_REQUIRED", nil, correlation_id)

      skip == :error or not is_integer(skip) or skip < 0 ->
        Shared.respond(400, "SESSION_SKIP_BOUNDS", nil, correlation_id)

      top == :error or not is_integer(top) or top < 1 ->
        Shared.respond(400, "SESSION_SKIP_BOUNDS", nil, correlation_id)

      since == :error ->
        Shared.respond(400, "SESSION_SKIP_BOUNDS", nil, correlation_id)

      true ->
        case Shared.store_call(context, :list_sessions, [
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

            Shared.respond(
              200,
              "OK",
              %{"sessions-ids" => ids, "sessions" => detail, "skip" => skip + length(ids)},
              correlation_id
            )

          {:error, _reason} ->
            Shared.respond(404, "NOT_FOUND", nil, correlation_id)

          _other ->
            Shared.respond(404, "NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # w6n: namespace usage/quota face. Read-only over the real stores; typed
  # 404 when the store tables are not materialized (same fail-closed gate
  # shape as the session/batch ops).
  def namespace_usage(correlation_id, context) do
    target = Map.get(context, :namespace_usage, Smalt.Amqp.NamespaceUsage)

    case target.usage() do
      {:ok, usage} ->
        Shared.respond(200, "OK", %{"namespace-usage" => usage}, correlation_id)

      {:error, :no_table} ->
        Shared.respond(404, "NOT_FOUND", nil, correlation_id)

      other ->
        Shared.respond(500, "INTERNAL_ERROR", %{"error" => inspect(other)}, correlation_id)
    end
  end
end

defmodule Smalt.Messaging.EventGrid.RetryPolicy do
  @moduledoc """
  Subscription-scoped retryPolicy (w6be) — extracted verbatim from
  `Smalt.Messaging.EventGrid` along the `# -- retryPolicy` fence (T10 tail
  split, v26.10.29 r10d). Defaults mirror real Event Grid: 30 attempts, 1 day
  TTL. Raises are preserved (ArgumentError, caller's process); the TTL-expiry
  drop path still emits `[:smalt, :event_grid, :ttl_expired]`.
  """

  @retry_policy_defaults {30, 86_400}

  # -- retryPolicy (w6be) ----------------------------------------------------------
  # Subscription-scoped retryPolicy: {max_delivery_attempts, event_time_to_live_s}.
  # Defaults mirror real Event Grid: 30 attempts, 1 day TTL.

  @retry_policy_defaults {30, 86_400}

  def validate!(nil), do: @retry_policy_defaults

  def validate!({max, ttl}) when is_integer(max) and is_integer(ttl) do
    unless max >= 1 and max <= 30 do
      raise ArgumentError,
            "EventGrid.subscribe/4 :retry_policy max_delivery_attempts must be 1..30, got #{max}"
    end

    unless ttl >= 1 do
      raise ArgumentError,
            "EventGrid.subscribe/4 :retry_policy event_time_to_live must be >= 1s, got #{ttl}"
    end

    {max, ttl}
  end

  # `{:hours, n}` and ISO-8601 "PTnH" / "PTnM" / "PTnS" duration forms.
  def validate!({:hours, n}) when is_integer(n) and n >= 1,
    do: {30, n * 3_600}

  def validate!(ttl) when is_binary(ttl) do
    case Regex.run(~r/^PT(\d+)([HMS])$/i, ttl) do
      [_, n, unit] ->
        secs =
          case String.upcase(unit) do
            "H" -> String.to_integer(n) * 3_600
            "M" -> String.to_integer(n) * 60
            "S" -> String.to_integer(n)
          end

        if secs < 1,
          do:
            raise(
              ArgumentError,
              "EventGrid.subscribe/4 :retry_policy event_time_to_live must be >= 1s"
            )

        {30, secs}

      nil ->
        raise ArgumentError,
              "EventGrid.subscribe/4 :retry_policy event_time_to_live must be seconds integer, " <>
                "{:hours, n}, or ISO-8601 PTnH/PTnM/PTnS, got #{inspect(ttl)}"
    end
  end

  def validate!(other),
    do:
      raise(ArgumentError,
        message:
          "EventGrid.subscribe/4 :retry_policy must be {max_delivery_attempts, " <>
            "event_time_to_live_seconds}, got #{inspect(other)}"
      )

  # True when the queue entry's publish-time stamp is past the subscription's
  # event_time_to_live. Expired events are DROPPED at dispatch (never delivered,
  # typed telemetry) — the real Event Grid event-TTL law.
  def entry_expired?(sub, {_id, _ev, ts, _attempts}) do
    ttl_s = sub[:event_time_to_live_s] || 86_400
    System.system_time(:millisecond) - ts > ttl_s * 1_000
  end

  # Drops every TTL-expired queued event for the subscription. Returns the
  # updated topic state. Each drop emits `[:smalt, :event_grid, :ttl_expired]`
  # (never delivered, never loss-silent — the drop is observed).
  def drop_expired(t, topic, name) do
    case t.subscribers[name] do
      nil ->
        t

      sub ->
        {kept, dropped} =
          :queue.fold(
            fn entry, {kept, dropped} ->
              if entry_expired?(sub, entry) do
                {kept, [entry | dropped]}
              else
                {:queue.in(entry, kept), dropped}
              end
            end,
            {:queue.new(), []},
            sub.queue
          )

        Enum.each(dropped, fn {id, _ev, _ts, _attempts} ->
          :telemetry.execute(
            [:smalt, :event_grid, :ttl_expired],
            %{count: 1},
            %{topic: topic, subscriber: name, id: id}
          )
        end)

        put_in(t.subscribers[name], %{sub | queue: kept})
    end
  end
end

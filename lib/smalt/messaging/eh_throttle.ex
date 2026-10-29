defmodule Smalt.Messaging.EhThrottle do
  @moduledoc """
  Event Hubs ingress quota/limit parity (wave-6 lane w6au2).

  Real Event Hubs throttles publish ingress when a quota is exceeded: the
  caller gets a server-busy / resource-limit-exceeded class refusal with a
  retry hint, and (over HTTP faces) a 429 with a `Retry-After` seconds
  header. This module is that quota engine for the emulator:

  - per-hub sliding-window ingress quota (events per window), counted in
    `:smalt_eh_throttle` ETS;
  - `admit/3` is the single publish-side gate: under quota admits, over
    quota returns a typed refusal carrying the retry hint;
  - the refusal face is shared by both planes: the AMQP link path can map
    it to the server-busy error class, the HTTP/ARM path renders 429 +
    `Retry-After`;
  - quotas are configurable two ways: an additive hub-record field
    (`"quota"` in the hub record properties — read-only, never written by
    this module) and an explicit `set_quota/4` override;

  ETS table is lazily created with the shadow-table heir law
  (`{:heir, Process.whereis(:init), []}` 3-tuple) so the table survives
  request-process death (the silent-disarm class fixed across waves 4-5).
  """

  @table :smalt_eh_throttle
  @telemetry [:smalt, :event_hubs, :throttled]

  require Logger

  # Default window when a quota is set without an explicit window: 1 second
  # (real EH ingress quotas are per-second class).
  @default_window_ms 1_000

  # Retry-After hint granularity (seconds): at least 1, never more than the
  # remaining window.
  defp retry_after_s(now_ms, window_reset_ms) do
    max(1, div(max(window_reset_ms - now_ms, 1), 1_000))
  end

  @doc """
  Lazily create the throttle table (shadow-table heir law). Idempotent.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          heir: Process.whereis(:init) || self()
        ])
      catch
        :error, :badarg -> :ok
      end
    end

    :ok
  end

  @doc """
  Set the publish quota for `hub`: `limit` events per `window_ms` (default
  #{@default_window_ms} ms). `limit: nil` removes the quota (unthrottled).
  Returns the stored quota map.
  """
  @spec set_quota(String.t(), pos_integer() | nil, pos_integer() | nil) :: map()
  def set_quota(hub, limit, window_ms \\ nil)

  def set_quota(hub, nil, _window_ms) when is_binary(hub) do
    ensure_table()
    :ets.delete(@table, quota_key(hub))
    %{hub: hub, quota: :off}
  end

  def set_quota(hub, limit, window_ms)
      when is_binary(hub) and is_integer(limit) and limit > 0 do
    ensure_table()
    window = window_ms || @default_window_ms

    true = :ets.insert(@table, {quota_key(hub), %{limit: limit, window_ms: window}})

    %{hub: hub, quota: %{limit: limit, window_ms: window}}
  end

  @doc """
  The publish-side gate. Admits when the hub has no quota or the sliding
  window has capacity; returns the typed throttled face when over quota.

  Faces:
    * `{:ok, :admitted}` — publish proceeds.
    * `{:throttled, %{retry_after_s: s, window_ms: w, limit: l}}` — refusal;
      `retry_after_s` feeds the HTTP `Retry-After` header, and the AMQP
      link path maps this to the server-busy / resource-limit-exceeded
      error class.
  """
  @spec admit(String.t(), pos_integer(), pos_integer() | nil) ::
          {:ok, :admitted} | {:throttled, map()}
  def admit(hub, n \\ 1, now_ms \\ nil)

  def admit(hub, n, now_ms) when is_binary(hub) and is_integer(n) and n > 0 do
    ensure_table()
    now = now_ms || System.system_time(:millisecond)

    case :ets.lookup(@table, quota_key(hub)) do
      [] ->
        # No explicit quota — fall back to an additive hub-record field
        # ("quota" in the hub record properties), if present. Read-only
        # lookup against the resources store; a missing record means
        # unthrottled (the emulator default).
        case hub_record_quota(hub) do
          %{limit: limit, window_ms: window} when is_integer(limit) and limit > 0 ->
            true = :ets.insert(@table, {quota_key(hub), %{limit: limit, window_ms: window}})
            admit(hub, n, now)

          _ ->
            {:ok, :admitted}
        end

      [{_k, %{limit: limit, window_ms: window}}] ->
        window_key = window_key(hub, now, window)

        # Sliding window: drop counts from previous windows before counting.
        counts =
          @table
          |> :ets.lookup(window_key)
          |> case do
            [] -> 0
            [{_k, c}] -> c
          end

        if counts + n > limit do
          :telemetry.execute(@telemetry, %{refused: n}, %{
            hub: hub,
            limit: limit,
            window_ms: window
          })

          {:throttled,
           %{
             retry_after_s: retry_after_s(now, window_reset_ms(now, window)),
             window_ms: window,
             limit: limit
           }}
        else
          # RMW via delete+insert preserves the heir'd row shape; counts are
          # advisory (races admit at most one extra event — quota-class
          # semantics, not ledger semantics).
          :ets.delete(@table, window_key)
          true = :ets.insert(@table, {window_key, counts + n})
          {:ok, :admitted}
        end
    end
  end

  @doc """
  HTTP/ARM face: `Retry-After` seconds for a hub currently over quota (0
  when the hub is not throttled). Callers render 429 + `Retry-After` from
  this.
  """
  @spec retry_after(String.t()) :: non_neg_integer()
  def retry_after(hub) when is_binary(hub) do
    ensure_table()
    now = System.system_time(:millisecond)

    with [{_k, %{limit: _l, window_ms: window}}] <- :ets.lookup(@table, quota_key(hub)),
         [{_k, counts}] when is_integer(counts) <- :ets.lookup(@table, window_key(hub, now, window)),
         true <- counts >= limit_of(hub) do
      retry_after_s(now, window_reset_ms(now, window))
    else
      _ -> 0
    end
  end

  defp limit_of(hub) do
    case :ets.lookup(@table, quota_key(hub)) do
      [{_k, %{limit: l}}] -> l
      _ -> 0
    end
  end

  @doc "Current window counts for `hub` (0 when unquotaed)."
  @spec window_counts(String.t()) :: non_neg_integer()
  def window_counts(hub) when is_binary(hub) do
    ensure_table()
    now = System.system_time(:millisecond)

    with [{_k, %{window_ms: window}}] <- :ets.lookup(@table, quota_key(hub)),
         [{_k, c}] <- :ets.lookup(@table, window_key(hub, now, window)) do
      c
    else
      _ -> 0
    end
  end

  @doc "Remove all throttle state for `hub` (quota + window counts)."
  @spec clear(String.t()) :: :ok
  def clear(hub) when is_binary(hub) do
    ensure_table()

    hub_key = quota_key(hub)

    window_keys =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {k, _} -> k end)
      |> Enum.filter(fn k -> is_binary(k) and String.starts_with?(k, "win:" <> hub <> ":") end)

    Enum.each([hub_key | window_keys], &:ets.delete(@table, &1))
    :ok
  end

  @doc "Typed AMQP-face refusal mapping: server-busy error class terms."
  def amqp_refusal(%{retry_after_s: s}) when is_integer(s) do
    {:error,
     {:resource_limit_exceeded,
      "Event hub ingress quota exceeded; retry after #{s} seconds"}}
  end

  def amqp_refusal(_), do: {:error, {:resource_limit_exceeded, "ingress quota exceeded"}}

  # --- internals -----------------------------------------------------------

  defp quota_key(hub), do: "quota:" <> hub

  defp window_key(hub, now_ms, window_ms) do
    "win:" <> hub <> ":" <> Integer.to_string(div(now_ms, window_ms))
  end

  defp window_reset_ms(now_ms, window_ms), do: (div(now_ms, window_ms) + 1) * window_ms

  defp hub_record_quota(hub) do
    # Read-only additive-field lookup over the resources store: a hub record
    # whose properties carry an integer "quota" is throttled with the
    # default window. Never written here.
    try do
      Smalt.Store.list_prefix(:smalt_resources, "")
      |> Enum.find_value(fn rec ->
        case record_matches_hub?(rec, hub) do
          true -> quota_from_props(rec)
          false -> nil
        end
      end)
    rescue
      e ->
        # JA16-D3: a corrupted/unavailable resources store must not degrade
        # throttling silently — log and emit a typed telemetry fault while
        # still falling back to the default quota window.
        Logger.warning(
          "eh_throttle: hub_record_quota store lookup failed for #{inspect(hub)}: " <>
            Exception.format(:error, e)
        )

        :telemetry.execute(@telemetry, %{store_fault: 1}, %{hub: hub, cause: :store_lookup_failed})

        nil
    end
  end

  defp record_matches_hub?(%{} = rec, hub) do
    id = rec["id"] || get_in(rec, ["properties", "id"])

    is_binary(id) and String.contains?(id, "/eventhubs/" <> hub)
  end

  defp record_matches_hub?(_, _), do: false

  defp quota_from_props(rec) do
    props = rec["properties"] || %{}

    case props do
      %{"quota" => q} when is_integer(q) and q > 0 -> %{limit: q, window_ms: @default_window_ms}
      _ -> nil
    end
  end
end

defmodule Smalt.Telemetry do
  @moduledoc """
  Observability for smalt: normalized spans from ecosystem `:telemetry` events plus
  smalt-native event emitters and in-memory rolling counters.

  ## Bandit integration

  Bandit emits `[:bandit, :request, :stop]` with measurements `duration` (`:native`
  units) and metadata `conn` / `plug` / `error` (see `Bandit.Telemetry` moduledoc).
  `attach/0` attaches a handler that normalizes these into
  `%Smalt.Telemetry.Span{route: conn.request_path, status: conn.status, duration_ms: ...}`.

  ## Integration point (for `Smalt.Application`)

  The coordinator should add exactly one line to `lib/smalt/application.ex`'s `start/2`
  (before or after the supervisor start; the handler survives either):

      Smalt.Telemetry.attach()

  `attach/0` is idempotent (`:telemetry.attach` returns `{:error, :already_exists}`
  on re-attach and it is swallowed). No child spec is required for the handler; the
  `RollingCounters` GenServer is a separate `Smalt.Telemetry.RollingCounters` child
  if the coordinator wants it supervised:

      {Smalt.Telemetry.RollingCounters, []}

  ## Matter-isolation law (privacy)

  Smalt-native events (`admit/2`, `refuse/3`, `sb_delivery/3`) carry counts, verdicts
  and codes ONLY in metadata — never payload values or identifiers. `metadata_keys/0`
  is the whitelist enforced by tests.
  """

  defstruct [:route, :status, :duration_ms]

  alias __MODULE__.RollingCounters
  alias __MODULE__.SemConv.Registry

  @typedoc "Normalized request span."
  @type span :: %__MODULE__{
          route: String.t() | nil,
          status: non_neg_integer() | nil,
          duration_ms: non_neg_integer()
        }

  @bandit_request_stop [:bandit, :request, :stop]

  @smalt_events [[:smalt, :admit], [:smalt, :refuse], [:smalt, :sb_delivery]]

  @metadata_keys [:event, :verdict, :code, :route]

  @doc "Whitelisted metadata keys for smalt-native events (matter-isolation law)."
  def metadata_keys, do: @metadata_keys

  @doc "Event names emitted by the smalt-native emitters."
  def smalt_events, do: @smalt_events

  @doc """
  Attaches the span-normalizing handler to `[:bandit, :request, :stop]`.
  Idempotent. Returns `:ok`.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(
           "smalt-telemetry",
           [@bandit_request_stop | @smalt_events],
           &__MODULE__.handle_event/4,
           :counters
         ) do
      :ok -> :ok
      # Handler already registered from another boot path — never re-attach,
      # or every bandit stop would be double-counted.
      {:error, :already_exists} -> :ok
    end
  end

  @doc """
  Attached handler. For `[:bandit, :request, :stop]` it normalizes the event into a
  `%Smalt.Telemetry{}` span (returned for testability; `:telemetry` ignores handler
  returns), bumps per-route/status counters, and buckets 4xx/5xx as `:error`.
  """
  def handle_event([:bandit, :request, :stop], measurements, metadata, _config) do
    span = normalize_span(measurements, metadata)
    RollingCounters.bump({:bandit_request_stop, span.route, span.status})

    if span.status in 400..599 do
      RollingCounters.bump({:bandit_request_stop, :error})
    end

    span
  end

  def handle_event([:smalt, _, _] = _event, _measurements, _metadata, _config) do
    # Direct emitter path (`admit/refuse/sb_delivery`) already bumped; this clause
    # only tolerates external re-emissions of smalt events by third parties.
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp normalize_span(measurements, metadata) do
    duration_ms =
      measurements
      |> Map.get(:duration, 0)
      |> System.convert_time_unit(:native, :millisecond)

    conn = Map.get(metadata, :conn)

    %__MODULE__{
      route: conn && conn.request_path,
      status: conn && conn.status,
      duration_ms: duration_ms
    }
  end

  ## Smalt-native emitters — counts and codes only, never payloads.

  @doc """
  Emits `[:smalt, :admit]` with `#{inspect(@metadata_keys)} ⊆ metadata`.
  `verdict` is a shape verdict atom (e.g. `:ok`); no payload values.
  """
  @spec admit(atom(), keyword()) :: :ok
  def admit(verdict, opts \\ []) do
    execute([:smalt, :admit], verdict, opts)
  end

  @doc """
  Emits `[:smalt, :refuse]` with a typed refusal `code` atom.
  Metadata: `code` plus whitelisted keys only — no refusal payloads.
  """
  @spec refuse(atom(), keyword()) :: :ok
  def refuse(code, opts \\ []) do
    execute([:smalt, :refuse], code, opts)
  end

  @doc """
  Emits `[:smalt, :sb_delivery]` for an AMQP delivery. Metadata carries
  `event` (delivery kind) only — never delivery payloads or identifiers.
  """
  @spec sb_delivery(atom(), keyword()) :: :ok
  def sb_delivery(event, opts \\ []) do
    execute([:smalt, :sb_delivery], event, opts)
  end

  defp execute(event, head, opts) do
    # SemConv allowlist gate (otel-weaver registry law): an attribute whose
    # runtime key is not registered for this event's semconv name is dropped
    # and counted — never emitted, never raised. The matter-isolation
    # @metadata_keys take still runs first.
    semconv_name = Registry.resolve(event)

    {allowed, rejected} =
      opts
      |> Keyword.take(@metadata_keys)
      |> Enum.split_with(fn {key, _} -> Registry.attribute_allowed?(semconv_name, key) end)

    Enum.each(rejected, fn {key, _} ->
      RollingCounters.bump({:semconv_unknown_attribute, semconv_name, key})
    end)

    metadata =
      allowed
      |> Keyword.put(:event, head)
      |> Map.new()

    RollingCounters.bump({event, metadata})
    :telemetry.execute(event, Map.new(), metadata)
    :ok
  end

  @doc "Dump current rolling counters (delegates to `RollingCounters.dump/0`)."
  @spec dump() :: map()
  defdelegate dump(), to: RollingCounters
end

defmodule Smalt.Telemetry.RollingCounters do
  @moduledoc """
  GenServer keeping in-memory per-minute counters per event key in an
  unnamed ETS table it owns (not `Smalt.Store`). Counters older than one
  window are pruned on a periodic tick; `dump/0` returns the live map.
  """

  use GenServer

  @prune_interval :timer.minutes(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Bump the counter for `key` in the current minute window."
  @spec bump(term()) :: :ok
  def bump(key) do
    # ST15 contention fix: direct ETS update (public table,
    # write_concurrency) — the GenServer.call funnel cost 4.2x under
    # parallel emitters. FAIL-CLOSED: a missing table is a boot-order
    # violation (RollingCounters not started) and raises ArgumentError —
    # no rescue, no silent drop. Counters are telemetry, but swallowing
    # boot-order defects here would hide real wiring breaks.
    full_key = {now_minute(), key, :self}
    :ets.update_counter(:smalt_rolling_counters, full_key, {2, 1}, {full_key, 0})
    :ok
  end

  @doc """
  Dump counters as `%{key => count}` for the current rolling window.
  Keys are `{event_name, metadata}` tuples; per-minute granularity is
  exposed via the `per_minute/0` view.
  """
  @spec dump() :: %{(event :: term()) => non_neg_integer()}
  def dump do
    GenServer.call(__MODULE__, :dump)
  end

  @doc "Dump counters grouped by minute: `%{{minute, key} => count}`."
  @spec per_minute() :: %{{integer(), term()} => non_neg_integer()}
  def per_minute do
    GenServer.call(__MODULE__, :per_minute)
  end

  @impl true
  def init(_opts) do
    # :named_table is required: bump/1 addresses the table by name from any
    # emitter process; without it the atom is a throwaway suggestion and every
    # named access raises ArgumentError (boot-order false positive).
    table = :ets.new(:smalt_rolling_counters, [:set, :public, :named_table, write_concurrency: true])
    schedule_prune()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:bump, _key, _minute}, _from, state) do
    # Kept for API compatibility; bump/1 writes inline (ST15 contention fix).
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:dump, _from, %{table: table} = state) do
    now = now_minute()
    counters = for {{m, k, _}, n} <- :ets.tab2list(table), recent?(m, now), into: %{}, do: {k, n}
    {:reply, counters, state}
  end

  def handle_call(:per_minute, _from, %{table: table} = state) do
    counters = for {{m, k, _}, n} <- :ets.tab2list(table), into: %{}, do: {{m, k}, n}
    {:reply, counters, state}
  end

  @impl true
  def handle_info(:prune, %{table: table} = state) do
    now = now_minute()

    for {{m, _, _} = full_key, _n} <- :ets.tab2list(table), m < now - 1 do
      :ets.delete(table, full_key)
    end

    schedule_prune()
    {:noreply, state}
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval)
  defp now_minute, do: System.system_time(:millisecond) |> div(60_000)

  defp recent?(minute, now), do: minute in [now - 1, now]
end

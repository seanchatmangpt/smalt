defmodule Smalt.ArmGateway.LRO.Sweeper do
  @moduledoc """
  Periodic at-rest terminality driver + opt-in retention eviction for ARM LRO
  operation records (`:smalt_operations`), closing
  `GAP(lro-lazy-terminality)` (at-rest face) and `GAP(lro-retention-unbounded)`
  (v26.10.14, V261014-05).

  - **Trigger**: periodic `Process.send_after` loop, interval
    `Application.get_env(:smalt, :lro_sweep_interval_ms, 30_000)`. Started as a
    child of `Smalt.Supervisor` (same pattern as `Smalt.AmqpBroker` — the
    gateway has no supervisor of its own), never under a request process.
  - **Flip pass**: every InProgress record whose delay has fully elapsed —
    and every malformed record — is driven through `Smalt.ArmGateway.LRO`'s
    PUBLIC `evaluate/2` / `fail_closed/2`. Since the v26.10.18 one-writer
    redesign (lib-redesign-wasm-lro.md Part 2) this process is the SINGLE
    terminal writer: the read path (`LRO.get_op/1`) and the Notifier's
    due-check route their persistence here (`flip_key/2`, `{:fail_closed, _}`
    requests), so swept and routed records converge to the identical
    persisted terminal and the two paths cannot diverge. Each flip is
    published through `Smalt.ArmGateway.LRO.Notifier` so `LRO.await/3`
    waiters wake on the explicit signal.
  - **Eviction pass** (only when `Application.get_env(:smalt, :lro_retention_ms,
    :infinity)` is a non-negative integer): terminal records (`status` ≠
    `"InProgress"`) whose parsed `endTime` is older than the window are
    deleted, oldest-terminal-first. **InProgress records are never evicted at
    any age.** Default `:infinity` preserves the historical accumulate-forever
    policy — no silent policy change.

  Fail-closed contract (matches `Smalt.Amqp.Sweeper`): a scan failure raises
  and crashes this GenServer; the supervisor restart is the honest signal.

  Idempotence/concurrency: `Store.put/3` is a single atomic insert of the
  whole record; a sweep racing a wire poll writes byte-identical terminal
  bodies (second-truncated `endTime`), so the store converges to ONE terminal
  without a lock (fenced in `test/lro_test.exs`).
  """

  use GenServer

  alias Smalt.ArmGateway.LRO
  alias Smalt.ArmGateway.LRO.Notifier
  alias Smalt.Store

  @tick_key {__MODULE__, :tick_ms}
  @default_tick_ms 30_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- single-writer request API -------------------------------------------------
  # The v26.10.18 one-writer redesign (lib-redesign-wasm-lro.md Part 2) makes
  # THIS process the single terminal writer on the flip path: the read path
  # (`LRO.get_op/1`) and the Notifier's due-check route due/malformed
  # persistence here via these requests instead of writing themselves. Every
  # flip below persists through the PUBLIC shared `LRO.evaluate/2` /
  # `LRO.fail_closed/2` (sole terminal-transition authority) and publishes the
  # terminal through the Notifier via an explicit cast.

  @doc """
  Single-writer flip of ONE key: an InProgress record past its delay is
  evaluated (and persisted terminal) through the shared `LRO.evaluate/2`;
  anything else is returned unchanged (`{:ok, record}` / `{:error,
  :not_found}`), always idempotent. Used by the read path (`LRO.get_op/1`)
  and the Notifier's due-check cast.
  """
  def flip_key(server \\ __MODULE__, key) do
    GenServer.call(server, {:flip_due, key}, 10_000)
  end

  @impl true
  def handle_call({:flip_due, key}, _from, state) do
    {:reply, flip_key_write(key), state}
  end

  @impl true
  def handle_call({:fail_closed, key, record}, _from, state) do
    {:reply, fail_key_write(key, record), state}
  end

  @impl true
  def handle_call(:sweep, _from, :manual) do
    run_pass()
    {:reply, :ok, :manual}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    run_pass()
    {:reply, :ok, state}
  end

  # Persist the terminal via the shared evaluate/2, then publish through the
  # Notifier (explicit cast — the sweeper is the ONLY flip-path component
  # invoking evaluate/fail_closed). Idempotent under races: an already-flipped
  # or vanished key replies without publishing.
  defp flip_key_write(key) do
    case Store.get(:smalt_operations, key) do
      {:ok, %{"status" => "InProgress"} = record} ->
        case LRO.evaluate(record, key) do
          %{"status" => "InProgress"} = unchanged ->
            # Not yet due (race with a concurrent flip): untouched.
            {:ok, unchanged}

          terminal ->
            GenServer.cast(Notifier, {:terminal, key, terminal})
            {:ok, terminal}
        end

      {:ok, record} ->
        {:ok, record}

      :error ->
        {:error, :not_found}
    end
  end

  defp fail_key_write(key, record) do
    terminal = LRO.fail_closed(record, key)
    GenServer.cast(Notifier, {:terminal, key, terminal})
    {:ok, terminal}
  end

  # -- GenServer ----------------------------------------------------------------

  @doc """
  Run one full pass immediately (flip pass, then eviction pass when
  `:lro_retention_ms` is enabled). Also invoked by the periodic tick.
  Returns `:ok`.
  """
  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep)
  end

  @doc """
  One flip pass over `:smalt_operations`: every InProgress record past
  `startedAtMs + delayMs` is persisted terminal via the SHARED `evaluate/2`;
  every malformed InProgress record (missing/non-integer scheduling fields)
  is persisted Failed via the SHARED `fail_closed/2`. Already-terminal and
  not-yet-due records are untouched (zero writes).
  """
  def flip_pass do
    now = System.system_time(:millisecond)

    :smalt_operations
    |> Store.keys()
    |> Enum.each(fn key ->
      case Store.get(:smalt_operations, key) do
        {:ok, %{"status" => "InProgress"} = record} ->
          evaluate_if_due(record, key, now)

        _ ->
          :ok
      end
    end)

    :ok
  end

  # The record is due (or malformed) -> drive the shared function and publish
  # the terminal through the Notifier; still InProgress -> untouched. Malformed
  # scheduling fields route to the fail_closed clause of evaluate/2 (public),
  # identical to the read path's routed request.
  defp evaluate_if_due(%{"startedAtMs" => started, "delayMs" => delay} = record, key, now)
       when is_integer(started) and is_integer(delay) do
    if now - started >= delay do
      case LRO.evaluate(record, key) do
        %{"status" => "InProgress"} -> :ok
        terminal -> GenServer.cast(Notifier, {:terminal, key, terminal})
      end
    else
      :ok
    end
  end

  defp evaluate_if_due(record, key, _now) do
    terminal = LRO.evaluate(record, key)
    GenServer.cast(Notifier, {:terminal, key, terminal})
    :ok
  end

  @doc """
  Retention eviction pass. Eligibility: terminal (`status` ≠ `"InProgress"`)
  AND parsed `endTime` older than the `:lro_retention_ms` window; evicted
  oldest-terminal-first (`endTime` ascending). InProgress NEVER evicted.
  `:infinity` (the default) or any non-integer config evicts nothing
  (fail-closed like `:lro_delay_ms`).
  """
  def eviction_pass do
    case Application.get_env(:smalt, :lro_retention_ms, :infinity) do
      ms when is_integer(ms) and ms >= 0 -> eviction_pass(ms)
      _ -> :ok
    end
  end

  @doc """
  Explicit-retention eviction pass: identical eligibility rules to
  `eviction_pass/0` but the window is passed directly rather than read from
  `:lro_retention_ms` — no global application-env mutation. `eviction_pass(0)`
  evicts every terminal record (endTime <= now), so the enclave lifecycle can
  reclaim its own operation rows. InProgress records are NEVER evicted at any
  retention, including 0.
  """
  def eviction_pass(retention_ms) when is_integer(retention_ms) and retention_ms >= 0 do
    cutoff = System.system_time(:millisecond) - retention_ms

    :smalt_operations
    |> Store.keys()
    |> Enum.flat_map(fn key ->
      case Store.get(:smalt_operations, key) do
        {:ok, %{"status" => status, "endTime" => end_iso} = _record}
        when status != "InProgress" and is_binary(end_iso) ->
          case DateTime.from_iso8601(end_iso) do
            {:ok, dt, _off} -> [{key, DateTime.to_unix(dt, :millisecond)}]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(fn {_key, end_ms} -> end_ms end)
    |> Enum.each(fn {key, end_ms} ->
      # retention 0 means "reclaim everything already terminal": the
      # second-truncated endTime can legitimately equal the cutoff to the
      # millisecond, so the boundary is inclusive there (never a residual
      # terminal row from the same clock second).
      if (retention_ms == 0 and end_ms <= cutoff) or end_ms < cutoff,
        do: Store.delete(:smalt_operations, key)
    end)

    :ok
  end

  # -- GenServer ----------------------------------------------------------------

  @impl true
  def init(opts) do
    tick_ms =
      opts[:tick_ms] || Application.get_env(:smalt, :lro_sweep_interval_ms, @default_tick_ms)

    # tick_ms: :manual (or any non-positive-integer) disables the periodic
    # tick entirely: init fires NO pass and the instance is driven only by
    # explicit sweep_now/1. Test-owned instances use this so no background
    # pass can land between before/after reads; the app-owned default is
    # byte-identical to the previous behavior.
    if is_integer(tick_ms) and tick_ms > 0 do
      :persistent_term.put(@tick_key, tick_ms)
      Process.send_after(self(), :tick, 0)
      {:ok, %{tick_ms: tick_ms}}
    else
      {:ok, :manual}
    end
  end

  # Notifier due-check (and any async single-writer trigger) flips here.
  @impl true
  def handle_cast({:flip_due, key}, state) do
    flip_key_write(key)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:fail_closed, key, record}, state) do
    fail_key_write(key, record)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, :manual), do: {:noreply, :manual}

  @impl true
  def handle_info(:tick, state) do
    run_pass()
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  defp run_pass do
    if :ets.info(:smalt_operations) == :undefined do
      # AZB-20 interop unblock (disclosed in the AZB-20 receipt): on a
      # control-only plane boot (SMALT_PLANES=control) the data-plane Store —
      # owner of the :smalt_operations ETS table — is not running. The pass
      # no-ops until the table exists instead of crash-looping the whole
      # control plane (topology defect, not a data defect).
      :ok
    else
      flip_pass()
      eviction_pass()
      :ok
    end
  end
end

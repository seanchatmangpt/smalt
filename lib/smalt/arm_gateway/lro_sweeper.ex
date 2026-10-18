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
    PUBLIC `evaluate/2` / `fail_closed/2`, the exact functions the lazy poll
    path calls, so swept and polled records converge to the identical
    persisted terminal and the two paths cannot diverge.
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
  alias Smalt.Store

  @tick_key {__MODULE__, :tick_ms}
  @default_tick_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

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

  # The record is due (or malformed) -> drive the shared function; still
  # InProgress -> untouched. Malformed scheduling fields route to the
  # fail_closed clause of evaluate/2 (public), identical to the lazy path.
  defp evaluate_if_due(%{"startedAtMs" => started, "delayMs" => delay} = record, key, now)
       when is_integer(started) and is_integer(delay) do
    if now - started >= delay, do: LRO.evaluate(record, key), else: :ok
  end

  defp evaluate_if_due(record, key, _now), do: LRO.evaluate(record, key)

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

    :persistent_term.put(@tick_key, tick_ms)
    Process.send_after(self(), :tick, 0)
    {:ok, %{tick_ms: tick_ms}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    run_pass()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_pass()
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  defp run_pass do
    flip_pass()
    eviction_pass()
    :ok
  end
end

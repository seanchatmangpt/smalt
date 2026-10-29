defmodule Smalt.Wasm.Pool do
  @moduledoc """
  Supervised WASM worker pool (WASM-SANDBOX-SPEC.md).

  16 pre-warmed workers by default (config `:smalt, :wasm_pool_size`, or
  `:size` start option), queue checkout/checkin, `trap_exit` + EXIT-driven
  fresh respawn — crash-only self-healing. A drained pool returns the typed
  `{:error, :pool_exhausted}`; it never queues unbounded work.
  """

  use GenServer

  @default_size 16

  # -- public API ------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Checks out one worker: `{:ok, pid}` or `{:error, :pool_exhausted}`."
  def checkout(pool \\ __MODULE__) do
    GenServer.call(pool, :checkout)
  end

  @doc "Returns a checked-out worker to the queue. No-op for dead/foreign pids."
  def checkin(pool \\ __MODULE__, worker) do
    GenServer.cast(pool, {:checkin, worker})
  end

  @doc "Number of live workers currently idle in the queue."
  def idle(pool \\ __MODULE__), do: GenServer.call(pool, :idle)

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    size = Keyword.get(opts, :size, Application.get_env(:smalt, :wasm_pool_size, @default_size))
    worker_opts = Keyword.take(opts, [:timeout_ms, :limit_bytes, :runner_args])

    workers =
      for _ <- 1..size,
          {:ok, pid} <- [start_worker(worker_opts)] do
        pid
      end

    {:ok, %{queue: :queue.from_list(workers), set: MapSet.new(workers), worker_opts: worker_opts}}
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    case :queue.out(state.queue) do
      {{:value, worker}, rest} ->
        {:reply, {:ok, worker}, %{state | queue: rest}}

      {:empty, _} ->
        {:reply, {:error, :pool_exhausted}, state}
    end
  end

  def handle_call(:idle, _from, state), do: {:reply, :queue.len(state.queue), state}

  @impl true
  def handle_cast({:checkin, worker}, state) do
    cond do
      MapSet.member?(state.set, worker) ->
        {:noreply, %{state | queue: :queue.in(worker, state.queue)}}

      # A fresh respawn that raced a stale checkin is already queued.
      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, worker, reason}, state) do
    if MapSet.member?(state.set, worker) do
      # Crash-only self-healing: the dead worker is dropped wherever it was
      # (idle or checked out) and a fresh one takes its place in the queue.
      {:noreply, respawn(state, worker, reason)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- internal --------------------------------------------------------------

  defp respawn(state, dead_worker, _reason) do
    {:ok, fresh} = start_worker(state.worker_opts)

    %{
      state
      | set: state.set |> MapSet.delete(dead_worker) |> MapSet.put(fresh),
        queue: state.queue |> then(&:queue.filter(fn w -> w != dead_worker end, &1)) |> then(& :queue.in(fresh, &1))
    }
  end

  defp start_worker(opts) do
    case Smalt.Wasm.Worker.start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> raise "wasm worker boot failed: #{inspect(reason)}"
    end
  end
end

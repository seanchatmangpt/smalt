defmodule Smalt.Aoq.Partitions do
  @moduledoc """
  AOQ partitioned-plane ring registry (LANE-05).

  Cold-path-only GenServer: ring lifecycle (ensure/drop) and the
  `{Smalt.Aoq.Partitions, :rings}` persistent_term map
  `ring_id -> {cursor, name}`. The data path never calls the
  GenServer: `submit/2` is one persistent_term read, an atomic seq
  claim (`Cursor.seq_next/1`), and a `send/2` to the ring's registered
  worker name. The GenServer sits only on the ring-mint/drop path.

  Off-heap cursor law: the `Smalt.Aoq.Cursor` atomics array lives in
  ref-counted memory outside any process heap, so a worker crash
  destroys the handle, never the data. The restarted worker adopts the
  same cursor from the registry and the per-ring seq continues (no
  reset on crash; reset is `drop_ring/2` only).
  """

  use GenServer

  alias Smalt.Aoq.Cursor
  alias Smalt.Aoq.PartitionWorker
  alias Smalt.Aoq.PartitionSup

  @rings_key {__MODULE__, :rings}

  @doc "Starts the registry GenServer."
  def start_link(cfg) do
    GenServer.start_link(__MODULE__, cfg, name: __MODULE__)
  end

  @doc """
  Idempotent ring mint (cold path). Returns the existing registry
  entry when the ring already exists; otherwise mints the cursor,
  starts the worker under `PartitionSup` keyed by `ring_id`, and
  publishes the entry to persistent_term.
  """
  @spec ensure_ring(term, keyword) :: {:ok, {Cursor.t(), atom}} | {:error, term}
  def ensure_ring(ring_id, cfg \\ config()) when is_list(cfg) do
    case ring(ring_id) do
      {:ok, _entry} = ok ->
        ok

      :error ->
        GenServer.call(__MODULE__, {:ensure_ring, ring_id, cfg})
    end
  end

  @doc """
  Drops a ring (cold path): stops the worker, bumps the lease
  generation (`Cursor.reset/1`, so outstanding leases fail typed), and
  erases the registry entry. This is the only seq-resetting transition.
  """
  @spec drop_ring(term) :: :ok | {:error, :no_ring}
  def drop_ring(ring_id) do
    GenServer.call(__MODULE__, {:drop_ring, ring_id})
  end

  @doc """
  Hot path (one persistent_term get): claims the ring's next u64 seq
  and hands `{frame, seq}` to the ring's registered worker. Returns
  `{:error, :no_ring}` for an un-minted ring. Delivery during a
  dead-worker window is a no-op send and the seq is still consumed:
  gapful-but-monotone is the crash law the partition crash court pins.
  """
  @spec submit(binary, term) :: {:ok, non_neg_integer} | {:error, :no_ring}
  def submit(frame, ring_id) when is_binary(frame) do
    case :persistent_term.get(@rings_key, %{}) |> Map.fetch(ring_id) do
      {:ok, {cursor, name}} ->
        seq = Cursor.seq_next(cursor)

        # Resolve the registered name to a pid: send to an atom name raises
        # badarg when unregistered (dead worker window) — a dropped delivery
        # with a consumed seq is the crash law, never a crash of the caller.
        case Process.whereis(name) do
          nil -> {:ok, seq}
          pid -> send(pid, {:aoq_frame, {frame, seq}})
        end

        {:ok, seq}

      :error ->
        {:error, :no_ring}
    end
  end

  @doc "Registry lookup: `{:ok, {cursor, name}}` or `:error`."
  @spec ring(term) :: {:ok, {Cursor.t(), atom}} | :error
  def ring(ring_id) do
    :persistent_term.get(@rings_key, %{}) |> Map.fetch(ring_id)
  end

  @doc "All live ring ids."
  @spec ring_ids() :: [term]
  def ring_ids do
    :persistent_term.get(@rings_key, %{}) |> Map.keys()
  end

  @doc "AoQ plane config (`Smalt.Aoq.Supervisor.config/0` resolution)."
  @spec config() :: keyword
  def config do
    Smalt.Aoq.Supervisor.config()
  end

  # GenServer callbacks (cold path only)

  @impl true
  def init(cfg) do
    {:ok, %{sink: Keyword.get(cfg, :sink, Smalt.Aoq.PartitionSink)}}
  end

  @impl true
  def handle_call({:ensure_ring, ring_id, cfg}, _from, state) do
    case ring(ring_id) do
      {:ok, _entry} = ok ->
        {:reply, ok, state}

      :error ->
        cursor = Cursor.new()
        sink = cfg[:sink] || state.sink
        name = PartitionWorker.registered(ring_id)
        spec = PartitionWorker.child_spec({ring_id, cursor, sink})

        case DynamicSupervisor.start_child(PartitionSup, spec) do
          {:ok, _pid} ->
            entry = {cursor, name}
            rings = :persistent_term.get(@rings_key, %{})
            :persistent_term.put(@rings_key, Map.put(rings, ring_id, entry))
            {:reply, {:ok, entry}, state}

          {:error, _reason} = err ->
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_call({:drop_ring, ring_id}, _from, state) do
    case ring(ring_id) do
      {:ok, {cursor, name}} ->
        pid = Process.whereis(name)

        if is_pid(pid) do
          DynamicSupervisor.terminate_child(PartitionSup, pid)
        end

        Cursor.reset(cursor)
        rings = :persistent_term.get(@rings_key, %{})
        :persistent_term.put(@rings_key, Map.delete(rings, ring_id))
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :no_ring}, state}
    end
  end
end

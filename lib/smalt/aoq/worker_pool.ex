defmodule Smalt.Aoq.WorkerPool do
  @moduledoc """
  Fixed pool of stateless frame workers (spec sections 1.1/1.2, LANE-11).

  The pool is a plain one_for_one Supervisor that pre-spawns `:workers`
  GenServer-free worker processes at boot (static children — readiness is
  structural, never a clock). Workers are stateless: all durable AoQ state
  lives in `:atomics`/`:persistent_term`, so a worker crash is a restart.

  Dispatch: `submit/1` hands a frame to one registered worker, chosen by
  an :atomics round-robin counter (`add_get` only - the section-6
  single-writer op-class law). Workers pull from their own mailbox; the
  pool process is never on the data path.
  """

  use Supervisor

  @doc false
  @dispatch_key {__MODULE__, :dispatch}

  def start_link(cfg) do
    Supervisor.start_link(__MODULE__, cfg, name: __MODULE__)
  end

  @impl true
  def init(cfg) do
    count = Keyword.fetch!(cfg, :workers)

    # Section-6 layout: dispatch round-robin + seq lease counter, u64,
    # add_get-only, owned here but addressed by index from any worker.
    dispatch = :atomics.new(1, signed: false)
    seq = :atomics.new(1, signed: false)
    :persistent_term.put(@dispatch_key, {count, dispatch, seq})

    children = Enum.map(0..(count - 1), &Smalt.Aoq.Worker.child_spec(&1))
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Push a frame at the pool. Picks a worker round-robin via :atomics and
  hands off the binary - the only synchronous hop on the ingest path
  (spec section 1.3). Returns {:ok, lease} where lease is the frame's seq.
  """
  @spec submit(binary) :: {:ok, non_neg_integer} | {:error, term}
  def submit(frame) when is_binary(frame) do
    case :persistent_term.get(@dispatch_key, nil) do
      nil ->
        {:error, :pool_down}

      {count, dispatch, seq} when count > 0 ->
        idx = :atomics.add_get(dispatch, 1, 1)
        send(Smalt.Aoq.Worker.via(idx, count), {:aoq_frame, frame})
        {:ok, :atomics.add_get(seq, 1, 1)}

      _ ->
        {:error, :pool_empty}
    end
  end

  @doc "Number of live workers (real observable, used by readiness polls)."
  @spec live_workers() :: non_neg_integer
  def live_workers do
    case :persistent_term.get(@dispatch_key, nil) do
      {count, _, _} when count > 0 ->
        Enum.count(0..(count - 1), fn i ->
          is_pid(Process.whereis(Smalt.Aoq.Worker.registered(i)))
        end)

      _ ->
        0
    end
  end
end

defmodule Smalt.Aoq.PartitionWorker do
  @moduledoc """
  One partition worker per ring (LANE-05): a plain GenServer-free
  process spawned with the `worker.ex` isolation profile verbatim
  (:link, off_heap MQD, max_heap_size kill budget, 30 s GC heartbeat),
  SINGLE claimant of its ring's head/tail.

  Loop: drain the mailbox into a bounded batch of `{frame, seq}`,
  batch-claim the head (`Cursor.claim_head/2`), parse through the
  `Smalt.Aoq.NifHolder` seam, `Cursor.drop/2` on parse refusal, then
  batch-release the tail (`Cursor.release_tail/2`), bringing
  `in_flight` back to 0 after every flush.

  Sink seam (L6 composes here): the worker calls `sink.deliver(ring_id,
  seq, parsed)` for every parsed frame; the default sink
  (`Smalt.Aoq.PartitionSink`) is a no-op so LANE-06's storage can mount
  via the `:sink` config key without editing this file.
  """

  # 2_097_152 words = 16 MiB heap budget per worker (worker.ex profile).
  @max_heap_words 2_097_152

  @batch 64

  alias Smalt.Aoq.Cursor

  @doc false
  def child_spec({ring_id, cursor, sink}) do
    %{
      id: ring_id,
      start: {__MODULE__, :start_link, [{ring_id, cursor, sink}]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Registered name for ring `ring_id`."
  def registered(ring_id), do: :"Smalt.Aoq.PartitionWorker.#{ring_id}"

  @doc false
  def start_link({ring_id, cursor, sink}) do
    # Isolation opts ride :erlang.spawn_opt/2 (atomic at spawn), same law
    # as Smalt.Aoq.Worker (Elixir has no 4-arity spawn_link).
    pid =
      :erlang.spawn_opt(
        fn -> loop(ring_id, cursor, sink) end,
        [
          :link,
          {:message_queue_data, :off_heap},
          {:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: true}}
        ]
      )

    Process.register(pid, registered(ring_id))
    {:ok, pid}
  end

  # SLEEP-CLASS: POLL-STEP — GC heartbeat, not coordination. max_heap_size
  # enforcement is GC-gated and the idle zero-alloc loop never GCs on its
  # own; the 30 s receive timeout forces a collection then recurses.
  defp loop(ring_id, cursor, sink) do
    case drain([], 0) do
      [] ->
        receive do
          {:aoq_frame, pair} ->
            # First frame flushes immediately; the next drain() sweep picks
            # up whatever queued behind it (bounded micro-batch law).
            flush(ring_id, cursor, sink, [pair])
            loop(ring_id, cursor, sink)

          :stop ->
            :ok
        after
          30_000 ->
            :erlang.garbage_collect()
            loop(ring_id, cursor, sink)
        end

      batch ->
        flush(ring_id, cursor, sink, batch)
        loop(ring_id, cursor, sink)
    end
  end

  # Drain queued frames into a bounded batch (oldest first).
  defp drain(acc, n) when n < @batch do
    receive do
      {:aoq_frame, {frame, seq}} ->
        drain([{frame, seq} | acc], n + 1)
    after
      0 ->
        :lists.reverse(acc)
    end
  end

  defp drain(acc, _n), do: :lists.reverse(acc)

  defp flush(ring_id, cursor, sink, batch) do
    n = length(batch)
    _first = Cursor.claim_head(cursor, n)

    Enum.each(batch, fn {frame, seq} ->
      case Smalt.Aoq.NifHolder.parse(frame) do
        {:ok, parsed} ->
          sink.deliver(ring_id, seq, parsed)

        {:error, _reason} ->
          Cursor.drop(cursor)
      end
    end)

    Cursor.release_tail(cursor, n)
  end
end

defmodule Smalt.Aoq.PartitionSink do
  @moduledoc """
  Default no-op sink for the partition worker's sink seam (LANE-05):
  parsed frames are dropped. LANE-06 mounts real storage by passing a
  module with `deliver(ring_id, seq, parsed) :: :ok` under the `:sink`
  config key — no edit to the worker or registry files.
  """

  @callback deliver(ring_id :: term, seq :: non_neg_integer, parsed :: term) :: :ok

  @behaviour Smalt.Aoq.PartitionSink

  @impl true
  def deliver(_ring_id, _seq, _parsed), do: :ok
end

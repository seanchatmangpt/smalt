defmodule Smalt.Aoq.CursorPersist do
  @moduledoc """
  Durable AoQ ring-cursor checkpointing (v26.11.6 offset-restart lane).

  The `Smalt.Aoq.Cursor` atomics array is ref-counted off-heap memory: a
  worker crash destroys the handle, a `kill -9` destroys the whole node's
  memory. `CursorPersist` folds the cursor's durable counters (`head`,
  `tail`, `seq`, `drop_ctr`) into the `Smalt.Storage.JournalSink` under the
  dedicated matter scope `"aoq"` (`<dir>/matter_aoq/segments/`) so the next
  boot can fold them back via `Smalt.Aoq.Cursor.restore_from_durable/2`.

  ## Checkpoint protocol

    * `note_release/2` (cast, consumer hot path): counts releases; every
      `@checkpoint_every` (1024) releases one checkpoint frame is appended
      (`flush/1` forces one immediately). `tail` is monotone, so the last
      frame in SeqID order carries the greatest tail — the boot fold takes
      the max `{tail, seq}` across all sealed matter-`"aoq"` frames.
    * Writes ride `JournalSink.append_frame/6` with `matter_scope: "aoq"`:
      scoped bytes live under `matter_aoq/`, cross-scope contamination is
      structurally unrepresentable.
    * A degraded sink is a LAWFUL accept-and-drop (`JournalSink` SPOF-A1):
      the checkpoint is lost, the next boot folds a shorter tail, the plane
      still boots. A log sink's restart budget is never paid by the AoQ
      plane.

  ## Boot fold (init)

  Boot-only: `restore_from_durable/2` raises if the cursor is not virgin
  (`tail != 0`), and raises the lagging head to the durable tail (head >=
  tail invariant). Integrity refusals from the reader (CRC/manifest/
  truncation) are fail-closed boot refusals (raise), never a partial
  admission; completeness failures (crash-window tails) are quarantined by
  discovery per SPOF-A3, never a boot wedge.
  """

  use GenServer
  require Logger

  alias Smalt.Aoq.Cursor
  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink

  @matter_scope "aoq"
  @event_type 0x0C01
  @table_id 0x0001
  @key "aoq_cursor"
  @checkpoint_every 1024

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Consumer hot path: record `n` tail releases. Every
  `@checkpoint_every` releases triggers one journal checkpoint frame
  (append is async via cast — a degraded sink accepts-and-drops, never
  crashes the caller).
  """
  @spec note_release(GenServer.server(), pos_integer()) :: :ok
  def note_release(server \\ __MODULE__, n) do
    GenServer.cast(server, {:note_release, n})
  end

  @doc """
  Force an immediate checkpoint frame. Returns `{:ok, seq_id}` — also in
  the degraded-sink case, which is the lawful accept-and-drop (SPOF-A1):
  `{:ok, seq_id}` with the frame counted as dropped by the sink, never a
  crash of the caller. A bad matter scope is a typed
  `{:error, {:bad_matter_scope, _}}`.
  """
  @spec flush(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, {:bad_matter_scope, binary()}}
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush, 30_000)
  end

  @doc "Matter scope used for all cursor checkpoints (\"aoq\")."
  def matter_scope, do: @matter_scope

  @doc "Journal directory of the plane sink (`config :smalt, :aoq` `:journal_dir`)."
  def journal_dir(cfg) when is_list(cfg) do
    cfg[:journal_dir] || "tmp/aoq_journal"
  end

  @impl true
  def init(opts) do
    cursor = Keyword.fetch!(opts, :cursor)
    sink = Keyword.get(opts, :sink, Smalt.Aoq.CursorPersist.Sink)
    dir = Keyword.get(opts, :dir, "tmp/aoq_journal")
    every = Keyword.get(opts, :checkpoint_every, @checkpoint_every)

    state = %{cursor: cursor, sink: sink, dir: dir, every: every, since_checkpoint: 0}

    case fold_boot_snapshots(dir) do
      {:ok, nil} ->
        {:ok, state}

      {:ok, snap} ->
        Cursor.restore_from_durable(cursor, snap)
        Logger.info("CursorPersist: restored durable cursor #{inspect(snap)}")
        {:ok, state}

      {:error, reason} ->
        # Fail-closed: integrity refusal (CRC/manifest/truncation) is a boot
        # refusal, never a partial admission.
        raise "CursorPersist: journal boot fold refused: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_cast({:note_release, n}, state) when is_integer(n) and n > 0 do
    since = state.since_checkpoint + n

    if since >= state.every do
      append_checkpoint(state)
      {:noreply, %{state | since_checkpoint: 0}}
    else
      {:noreply, %{state | since_checkpoint: since}}
    end
  end

  def handle_cast({:note_release, n}, state) do
    # Typed degrade: a zero/negative release count carries no tail progress;
    # ignore (counted, never a crash of the cast path).
    Logger.warning("CursorPersist: ignoring non-positive note_release #{inspect(n)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, append_checkpoint(state), state}
  end

  @impl true
  def handle_info({:EXIT, _from, reason}, state) do
    Logger.warning("CursorPersist: ignoring EXIT message (reason=#{inspect(reason)})")
    {:noreply, state}
  end

  def handle_info(unexpected, state) do
    Logger.warning("CursorPersist: unexpected message #{inspect(unexpected)}")
    {:noreply, state}
  end

  # -- internals -------------------------------------------------------------

  defp append_checkpoint(%{cursor: cursor, sink: sink} = state) do
    snap = Cursor.durable_snapshot(cursor)
    payload = encode_payload(snap)

    case JournalSink.append_frame(sink, @event_type, @table_id, @key, payload,
           matter_scope: @matter_scope
         ) do
      {:ok, seq_id} ->
        {:ok, seq_id}

      {:error, reason} = err ->
        # SPOF-A1 law: the sink already logged + counted the drop; the
        # persist surface degrades typed — never raises into the plane.
        Logger.warning("CursorPersist: checkpoint dropped (#{inspect(reason)})")
        err
    end
  end

  # Fold ALL sealed matter-"aoq" segments; take the max {tail, seq} frame.
  # Sync-only frames (none today) would decode as garbage — every frame in
  # this scope is written by append_checkpoint's fixed binary layout, so a
  # scope-frame that does not decode is a typed :bad_checkpoint_payload.
  defp fold_boot_snapshots(dir) do
    with {:ok, segs} <- JournalReader.discover_sealed_segments(dir, matter_scope: @matter_scope) do
      segs
      |> Enum.reduce_while({:ok, nil}, fn seg, {:ok, acc} ->
        case JournalReader.read_sealed_segment(seg) do
          {:ok, frames} ->
            {:cont, {:ok, max_snapshot(acc, frames)}}

          {:error, _} = refusal ->
            {:halt, refusal}
        end
      end)
    end
  end

  defp max_snapshot(nil, frames), do: max_snapshot(empty(), frames)

  defp max_snapshot(acc, frames) do
    frames
    |> Enum.reduce(acc, fn frame, best ->
      case decode_payload(frame.payload) do
        {:ok, snap} -> if better?(snap, best), do: snap, else: best
        :error -> raise ":bad_checkpoint_payload in #{frame.seq_id}"
      end
    end)
  end

  defp better?(a, b) do
    a.tail > b.tail or (a.tail == b.tail and a.seq > b.seq)
  end

  defp empty, do: %{head: 0, tail: 0, seq: 0, drop_ctr: 0}

  # <<head::64, tail::64, seq::64, drop_ctr::64>>
  defp encode_payload(snap) do
    <<snap.head::unsigned-integer-size(64), snap.tail::unsigned-integer-size(64),
      snap.seq::unsigned-integer-size(64), snap.drop_ctr::unsigned-integer-size(64)>>
  end

  defp decode_payload(
         <<head::unsigned-integer-size(64), tail::unsigned-integer-size(64),
           seq::unsigned-integer-size(64), drop_ctr::unsigned-integer-size(64)>>
       ) do
    {:ok, %{head: head, tail: tail, seq: seq, drop_ctr: drop_ctr}}
  end

  defp decode_payload(_), do: :error
end

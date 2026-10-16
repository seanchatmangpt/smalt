defmodule Smalt.Messaging.EventHubs do
  @moduledoc """
  Event Hubs semantics on the shared AMQP 1.0 stack (mode `:eh`, port 5673).

  A sender attach / transfer on an entity path containing `"/eventhubs/"` routes to
  EH semantics: the broker assigns a **strictly monotonic** per-partition sequence
  number, returned to the sender as the `x-opt-sequence-number` message annotation.
  Receiver links on the same partition receive events back in sequence order.

  Storage (extends `Smalt.Store`, tables created idempotently here so this module is
  usable even before `Smalt.Store.@tables` is extended):

  | Table | Key | Value |
  |---|---|---|
  | `:smalt_eh_partitions` | `"ns/hub/partition"` | `%{"seq" => n, "events" => [{seq, body}], "offset" => n}` |
  | `:smalt_eh_checkpoints` | `{group, partition}` | `%{"seq" => n, "offset" => n, "etag" => n, "claim" => %{...} \\| nil}` |

  Monotonicity and exactly-once CAS: sequence assignment and checkpoint CAS are
  serialized through an internal named GenServer (`Smalt.Messaging.EventHubs.Server`,
  started lazily on first use), which is race-free by construction. When
  `Smalt.Store.update_counter/3` exists it is used as the atomic sequence source
  (a dedicated integer cell row `{:seq_counter, partition}` in
  `:smalt_eh_partitions`, mirrored into the map row) — always from inside the
  server's `handle_call`, so all mutations stay on one serialization point.

  Public contract (as required by the checkpoint-management surface):
  `next_sequence/1`, `send_event/3`, `receive_events/3`, `compare_and_swap/4`,
  `reserve_processing/4`, `reconcile/2`, `sweep/0`.
  """

  require Logger

  @partitions :smalt_eh_partitions
  @checkpoints :smalt_eh_checkpoints

  alias Smalt.Messaging.EventHubs.Server, as: EHServer

  # -- Tables -------------------------------------------------------------------

  @doc "Idempotently ensure the two EH tables exist. Returns `:ok`."
  def ensure_tables do
    # Tables are created INSIDE the EH server (lens-5 F-4): caller-side
    # creation made the named tables owned by whichever mortal process called
    # first — when that process exited the table died under the running
    # server, and the server's next `:ets` op crashed (lens-6 M-B re-witness:
    # the rescue-guarded caller-side pre-init shape is killed by the F-4
    # court — winner Task's mortality leaves `:ets.info == :undefined` after
    # the hammer). Server-owned tables also serialize the create itself (no
    # lookup-then-create race at all).
    EHServer.transaction(:ensure_tables)
  end

  # -- Sequencing / events --------------------------------------------------------

  @doc """
  Assign the next strictly monotonic sequence number for `partition`
  (e.g. `"ns/hub/partition"` or an entity path containing `"/eventhubs/"`).
  Returns `{:ok, seq}` with seq starting at 1. Used on every sender transfer in
  `:eh` mode to stamp `x-opt-sequence-number`.
  """
  @spec next_sequence(String.t()) :: {:ok, pos_integer()}
  def next_sequence(partition) when is_binary(partition) do
    ensure_tables()
    {:ok, EHServer.transaction({:next_seq, partition})}
  end

  @doc """
  Append an event to `partition` with a freshly assigned monotonic sequence.
  Returns `{:ok, seq, event_map}` where `event_map` carries `"seq"`, `"body"` and any
  `"properties"`. Receiver links replay these in sequence order.
  """
  @spec send_event(String.t(), term(), keyword()) :: {:ok, pos_integer(), map()}
  def send_event(partition, body, opts \\ []) when is_binary(partition) do
    ensure_tables()

    props = Keyword.get(opts, :properties, %{})

    seq = EHServer.transaction({:send_event, partition, body, props})

    {:ok, seq, %{"seq" => seq, "body" => body, "properties" => props, "enqueued" => now_ms()}}
  end

  @doc """
  Events for `partition` with `seq > after_seq`, ascending by sequence, at most
  `limit` (default 100).
  """
  @spec receive_events(String.t(), non_neg_integer(), pos_integer()) :: [map()]
  def receive_events(partition, after_seq \\ 0, limit \\ 100)
      when is_binary(partition) and is_integer(after_seq) and after_seq >= 0 do
    ensure_tables()

    case :ets.lookup(@partitions, partition) do
      [{^partition, %{"events" => events}}] ->
        events
        |> Enum.filter(fn {seq, _} -> seq > after_seq end)
        |> Enum.sort_by(fn {seq, _} -> seq end)
        |> Enum.take(limit)
        |> Enum.map(fn {seq, {body, props}} ->
          %{"seq" => seq, "body" => body, "properties" => props}
        end)

      _ ->
        []
    end
  end

  # -- Checkpoint management ------------------------------------------------------

  @doc """
  Compare-and-swap the checkpoint for `{group, partition}`: succeeds only when the
  current checkpoint equals `expect`. Returns `:ok` or `{:error, :conflict}`.
  Routing through the internal serialised server (`Smalt.Messaging.EventHubs.Server`)
  unifies serialization with `reserve_processing/4` — exactly one of N concurrent
  callers with the same `expect` wins, race-free by construction.
  """
  @spec compare_and_swap(String.t(), String.t(), map(), map()) :: :ok | {:error, :conflict}
  def compare_and_swap(group, partition, expect, new)
      when is_binary(group) and is_binary(partition) and is_map(expect) and is_map(new) do
    ensure_tables()
    key = {group, partition}

    # NO caller-side seed of the checkpoint row (lens-4 F-2, the F-1 window
    # class): a lookup-then-insert seed here raced `reserve_processing` — a
    # claim written by the serialized server between the lookup and the insert
    # was clobbered by the stale seed insert, silently dropping a live lease
    # (two consumers hold one partition). The serialized `cas_claim_blind`
    # handler already treats an absent row as the zero checkpoint, so the seed
    # carried zero semantics; all checkpoint writes are now serialized.

    # Claim-blind CAS (lens-2 cycle 2): `reconcile/2` — the documented
    # authoritative view — strips the `"claim"` lease field, so a client
    # building `expect` from it could never win while a lease rides the same
    # row. The CAS therefore compares against the claim-stripped checkpoint and
    # preserves the live claim on write. Routing through the serialized server
    # unifies serialization with `reserve_processing/4` (claim writes), closing
    # the reserve-vs-CAS race where the two wrote different serialization
    # points.
    EHServer.transaction({:cas_claim_blind, key, expect, new})
  end

  # Checkpoints are keyed {group, partition}; a claim row lives inside the same
  # map.

  @doc """
  Acquire a processing lease on `{group, partition}` for `owner` lasting `ttl_ms`.
  `:ok` if the lease is free/expired/already owned by `owner`; `{:error, :conflict}`
  if another live owner holds it. Expired leases are reclaimed by `sweep/0` or
  lazily on the next reservation.

  The caller passes a RELATIVE `ttl_ms`; the expiry (`until`) is computed inside
  the serialized server from its own clock (V261014-04 F5) — one clock source
  for the claim-free check and the stored expiry.
  """
  @spec reserve_processing(String.t(), String.t(), term(), pos_integer()) ::
          :ok | {:error, :conflict}
  def reserve_processing(group, partition, owner, ttl_ms)
      when is_binary(group) and is_binary(partition) and is_integer(ttl_ms) and ttl_ms > 0 do
    ensure_tables()
    EHServer.transaction({:reserve, {group, partition}, owner, ttl_ms})
  end

  @doc """
  Authoritative view for `{group, partition}`: the partition's assigned sequence
  (broker truth) and the stored checkpoint. Never fails on missing rows — absent
  state reads as zero/empty.
  """
  @spec reconcile(String.t(), String.t()) :: {:ok, map()}
  def reconcile(group, partition) do
    ensure_tables()

    partition_seq =
      case :ets.lookup(@partitions, partition) do
        [{^partition, %{"seq" => seq}}] -> seq
        _ -> 0
      end

    checkpoint =
      case :ets.lookup(@checkpoints, {group, partition}) do
        [{_k, cp}] -> Map.delete(cp, "claim")
        [] -> nil
      end

    {:ok,
     %{
       "group" => group,
       "partition" => partition,
       "seq" => partition_seq,
       "offset" => partition_seq,
       "checkpoint" => checkpoint
     }}
  end

  @doc "GC expired processing claims. Returns the number of claims removed."
  @spec sweep() :: non_neg_integer()
  def sweep do
    ensure_tables()

    # NO caller-side read-modify-write here (lens-5 F-3, the F-2/F-1 window
    # class): the previous shape read each checkpoint via `:ets.tab2list` and
    # then wrote the WHOLE value back. The sweep runs as ONE serialized
    # `handle_call` on the same server as `reserve`/`cas_claim_blind`, so the
    # window no longer exists. Lens-6: the F-3 shape court now bans ANY
    # checkpoint write (`insert` or `update_element`) from the sweeping
    # caller, and requires an expired claim so the sweep actually writes —
    # the lens-5 court was evaded by an insert-shaped caller-side mutant
    # (M-A survived it 19/0; kill witnessed after hardening, receipt
    # cycle-2). Lens-7: the ban is the FULL `:ets` write surface
    # (insert/insert_new/update_element/update_counter x2/delete/
    # delete_all_objects) — a delete-shaped caller-side reclaim mutant
    # (M-C) evaded the two-op trace pattern 19/0; kill witnessed after the
    # full-surface hardening (receipt cycle-2).
    EHServer.transaction({:sweep, now_ms()})
  end

  # -- Sequence bump (shared by server + Store path) --------------------------------

  @doc false
  def bump_sequence(partition) do
    if store_counter_available?() do
      # Atomic ETS counter on a dedicated integer cell; the map row mirrors the value
      # so readers of the pinned {"seq" => n} layout stay consistent.
      seq = Smalt.Store.update_counter(@partitions, {:seq_counter, partition}, 1)

      map_row =
        case :ets.lookup(@partitions, partition) do
          [{^partition, row}] when is_map(row) -> row
          _ -> %{}
        end

      :ets.insert(@partitions, {partition, Map.put(map_row, "seq", seq)})
      seq
    else
      seq =
        case :ets.lookup(@partitions, partition) do
          [{^partition, %{"seq" => current}}] when is_integer(current) -> current + 1
          _ -> 1
        end

      upsert_partition_row(partition, fn row -> Map.put(row, "seq", seq) end)
      seq
    end
  end

  defp upsert_partition_row(partition, fun) do
    row =
      case :ets.lookup(@partitions, partition) do
        [{^partition, row}] when is_map(row) -> row
        _ -> %{}
      end

    :ets.insert(@partitions, {partition, fun.(row)})
  end

  defp store_counter_available? do
    Code.ensure_loaded?(Smalt.Store) and function_exported?(Smalt.Store, :update_counter, 3)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defmodule Server do
    @moduledoc false
    # Serialised mutation point for EH state when Smalt.Store counter/CAS primitives
    # are not yet available. Started lazily (name-registered, start race resolved by
    # `:already_started` handling).

    use GenServer

    @name Smalt.Messaging.EventHubs.Server
    @partitions :smalt_eh_partitions
    @checkpoints :smalt_eh_checkpoints

    def transaction(request) do
      ensure_started()
      GenServer.call(@name, request)
    end

    defp ensure_started do
      case GenServer.start(__MODULE__, :ok, name: @name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> exit({:eh_server_start_failed, reason})
      end
    end

    @impl true
    def init(:ok) do
      do_ensure_tables()
      {:ok, %{}}
    end

    # Runs inside the (immortal-named) server process, so the named tables are
    # server-owned and never die with a mortal caller. Serialized by the
    # server mailbox: no lookup-then-create race.
    defp do_ensure_tables do
      Enum.each([@partitions, @checkpoints], fn table ->
        if :ets.info(table) == :undefined do
          # NB: literal opts — module attributes do not leak into a nested
          # defmodule (the parent's @table_opts reads nil here).
          :ets.new(table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        end
      end)

      :ok
    end

    @impl true
    def handle_call(:ensure_tables, _from, state) do
      {:reply, do_ensure_tables(), state}
    end

    @impl true
    def handle_call({:next_seq, partition}, _from, state) do
      {:reply, Smalt.Messaging.EventHubs.bump_sequence(partition), state}
    end

    def handle_call({:send_event, partition, body, props}, _from, state) do
      seq = Smalt.Messaging.EventHubs.bump_sequence(partition)
      append_event(partition, seq, body, props)
      {:reply, seq, state}
    end

    def handle_call({:cas_claim_blind, key, expect, new}, _from, state) do
      current =
        case :ets.lookup(@checkpoints, key) do
          [{^key, cp}] when is_map(cp) -> cp
          _ -> %{"seq" => 0, "offset" => 0, "etag" => 0}
        end

      if Map.delete(current, "claim") == expect do
        cp = case current["claim"] do
          nil -> new
          claim -> Map.put(new, "claim", claim)
        end

        :ets.insert(@checkpoints, {key, cp})
        {:reply, :ok, state}
      else
        {:reply, {:error, :conflict}, state}
      end
    end

    def handle_call({:sweep, now}, _from, state) do
      count =
        :ets.tab2list(@checkpoints)
        |> Enum.reduce(0, fn {key, cp}, acc ->
          case cp do
            %{"claim" => %{"until" => until}} when until <= now ->
              # Serialized with reserve/cas: the whole-value write can no
              # longer clobber a claim a concurrent reserve wrote between
              # the read and the write (lens-5 F-3).
              :ets.update_element(@checkpoints, key, {2, Map.put(cp, "claim", nil)})
              acc + 1

            _ ->
              acc
          end
        end)

      {:reply, count, state}
    end

    def handle_call({:reserve, key, owner, ttl_ms}, _from, state) do
      # F5 normalization: `ttl_ms` arrives RELATIVE; the expiry is computed
      # here, inside the serialized server — one clock source for both the
      # claim-free check and the stored expiry (V261014-04 F5).
      now = System.system_time(:millisecond)
      until = now + ttl_ms

      current =
        case :ets.lookup(@checkpoints, key) do
          [{^key, cp}] when is_map(cp) -> cp
          _ -> %{}
        end

      claim_free? = fn cp ->
        case cp["claim"] do
          %{"owner" => o, "until" => u} -> u <= now or o == owner
          _ -> true
        end
      end

      if claim_free?.(current) do
        cp =
          current
          |> Map.put_new("seq", 0)
          |> Map.put_new("offset", 0)
          |> Map.put_new("etag", 0)
          |> Map.put("claim", %{"owner" => owner, "until" => until})

        :ets.insert(@checkpoints, {key, cp})
        {:reply, :ok, state}
      else
        {:reply, {:error, :conflict}, state}
      end
    end

    defp append_event(partition, seq, body, props) do
      row =
        case :ets.lookup(@partitions, partition) do
          [{^partition, row}] when is_map(row) -> row
          _ -> %{}
        end

      events = Map.get(row, "events", [])
      row = row |> Map.put("events", [{seq, {body, props}} | events])
      :ets.insert(@partitions, {partition, row})
      :ok
    end
  end
end

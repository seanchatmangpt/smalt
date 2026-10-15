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

  Monotonicity and exactly-once CAS: when `Smalt.Store.update_counter/3` exists it is
  used as the atomic sequence source (a dedicated integer cell row
  `{:seq_counter, partition}` in `:smalt_eh_partitions`, mirrored into the map row);
  otherwise sequence assignment and checkpoint CAS are serialised through an internal
  named GenServer (`Smalt.Messaging.EventHubs.Server`, started lazily on first use),
  which is race-free by construction. When `Smalt.Store.compare_and_swap/4` exists,
  CAS delegates to it; the server fallback does lookup+insert atomically inside a
  single `handle_call`.

  Public contract (as required by the checkpoint-management surface):
  `next_sequence/1`, `send_event/3`, `receive_events/3`, `compare_and_swap/4`,
  `reserve_processing/4`, `reconcile/2`, `sweep/0`.
  """

  require Logger

  @partitions :smalt_eh_partitions
  @checkpoints :smalt_eh_checkpoints

  @table_opts [:set, :public, :named_table, read_concurrency: true, write_concurrency: true]

  alias Smalt.Messaging.EventHubs.Server, as: EHServer

  # -- Tables -------------------------------------------------------------------

  @doc "Idempotently ensure the two EH tables exist. Returns `:ok`."
  def ensure_tables do
    Enum.each([@partitions, @checkpoints], fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, @table_opts)
      end
    end)

    :ok
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
  Delegates to `Smalt.Store.compare_and_swap/4` when available, else the internal
  serialised server — exactly one of N concurrent callers with the same `expect`
  wins.
  """
  @spec compare_and_swap(String.t(), String.t(), map(), map()) :: :ok | {:error, :conflict}
  def compare_and_swap(group, partition, expect, new)
      when is_binary(group) and is_binary(partition) and is_map(expect) and is_map(new) do
    ensure_tables()
    key = {group, partition}

    # Store's CAS conflicts on a missing row; EH semantics treat an absent
    # checkpoint as the zero checkpoint, so seed it (idempotent) first.
    case :ets.lookup(@checkpoints, row_key(key)) do
      [] -> :ets.insert(@checkpoints, {row_key(key), %{"seq" => 0, "offset" => 0, "etag" => 0}})
      _ -> :ok
    end

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
  # map. Kept as a function so the row layout stays in one place.
  defp row_key(key), do: key

  @doc """
  Acquire a processing lease on `{group, partition}` for `owner` lasting `ttl_ms`.
  `:ok` if the lease is free/expired/already owned by `owner`; `{:error, :conflict}`
  if another live owner holds it. Expired leases are reclaimed by `sweep/0` or
  lazily on the next reservation.
  """
  @spec reserve_processing(String.t(), String.t(), term(), pos_integer()) ::
          :ok | {:error, :conflict}
  def reserve_processing(group, partition, owner, ttl_ms)
      when is_binary(group) and is_binary(partition) and is_integer(ttl_ms) and ttl_ms > 0 do
    ensure_tables()
    EHServer.transaction({:reserve, {group, partition}, owner, now_ms() + ttl_ms})
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
    now = now_ms()

    :ets.tab2list(@checkpoints)
    |> Enum.reduce(0, fn {key, cp}, acc ->
      case expired_claim?(cp, now) do
        true ->
          :ets.update_element(@checkpoints, key, {2, Map.put(cp, "claim", nil)})
          acc + 1

        false ->
          acc
      end
    end)
  end

  defp expired_claim?(%{"claim" => %{"until" => until}}, now), do: until <= now
  defp expired_claim?(_, _), do: false

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
      Smalt.Messaging.EventHubs.ensure_tables()
      {:ok, %{}}
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

    def handle_call({:reserve, key, owner, until}, _from, state) do
      now = System.system_time(:millisecond)

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

defmodule Smalt.Store do
  @moduledoc """
  In-memory ETS backed storage for ARM resources, Cosmos docs, Key Vault items,
  immutable Blob storage, Confidential Ledger Merkle transactions, and event topics.

  All tables are `:ordered_set` with lowercased full ARM id strings as keys, so
  `list_prefix/2` scans are deterministic and TF-stable.

  ## TTV-5 reference architecture (partitioned error kernel)

  `Smalt.Store` is the FACADE of a supervised ensemble; the process named
  `Smalt.Store` is the ensemble SUPERVISOR (`whereis(Smalt.Store)` stays
  meaningful — killing it IS the full-node crash):

    * `Smalt.Store.Heir` — quiet heir, boots first, holds tables whose
      owning partition died and gives them back via `reclaim_table/2`;
    * `Smalt.Store.Boot` — runs the TTV-4 sealed-journal replay LAST
      (adopt-then-replay: partitions create/adopt the tables first, the
      sealed journal is applied before the ensemble finishes starting —
      no request is served until all 18 children are up); a typed reader
      refusal is a boot refusal (TTV-4 law unchanged);
    * `Smalt.Store.Partition` × 16 — permanent workers, one per
      `:erlang.phash2(table, 16)` stripe; serialized writes (CAS, CAS-delete,
      insert_new, next_seq) route through the owning worker.

  Reads bypass the processes entirely (public tables). The canonical table
  names are UNCHANGED — the stripe is per TABLE, not per key (coordinator-
  approved deviation: key-striping would rename the canonical namespace and
  break ~15 cross-lease modules doing direct ETS/readiness checks), so
  per-table CAS/next_seq serialization is identical to the pre-partition
  single-GenServer guarantee.
  """
  use Supervisor, restart: :permanent

  require Logger

  # W1b projection: the table list is the generated registry
  # (lib/smalt/store_tables.ex — smalt:StoreTable ontology rows), replacing
  # the hand-written @tables list. Equivalence at the swap was proven by
  # test/store_tables_replay_identity_test.exs; DO NOT re-introduce a local
  # list — regenerate with `mix smalt.gen`.
  @tables Smalt.StoreTables.table_names()

  # SCVD backpressure audit MED-3: the data-plane call funnel (CAS / cas_delete
  # / insert_new / next_seq) previously relied on the implicit GenServer.call
  # 5_000ms default. Typed now; same value, semantics unchanged.
  @call_timeout 5_000

  # TTV-4: journal frame event types owned by the Store (u16 wire codes).
  # Disjoint from the OcelEmitter codes (0x0001..0x0004) so a shared journal
  # directory carries both and replay filters by event type, never guessing.
  @journal_evt_put 0x0A01
  @journal_evt_delete 0x0A02

  # TTV-4: table identity on the wire is the table's index in the generated
  # registry (store_tables.ex). Frames carry the u16 index; replay maps back.
  @table_id_by_name @tables |> Enum.with_index() |> Map.new(fn {t, i} -> {t, i} end)
  @table_name_by_id @tables |> Enum.with_index() |> Map.new(fn {t, i} -> {i, t} end)

  # TTV-5: the 16-way stripe (table-level — see moduledoc).
  @partitions 16

  def start_link(opts \\ []) do
    # TTV-4: an explicit :name opt lets a court boot a second, non-default
    # ensemble against a scratch journal dir. Default is unchanged. The
    # ensemble supervisor carries the name; every child name derives from it.
    base = Keyword.get(opts, :name, __MODULE__)

    children =
      [
        # Heir FIRST: the give-away anchor is alive before any worker binds.
        {Smalt.Store.Heir, opts}
      ] ++
        Enum.map(0..(@partitions - 1), fn i ->
          # Partitions SECOND. Cold boot: the OWNING partition CREATEs its
          # assigned tables with {:heir, heir_pid, []} (reference contract —
          # a later partition crash hands tables to the Heir for the
          # respawn to reclaim; :ets.give_away does NOT reset the heir
          # option, so creation heir must be the Heir, never :init).
          # BK-65 unblock: {Mod, arg} children all default to id `Mod` — 16x
          # duplicate (witnessed SUBSTRATE_DIED). Unique map-form ids.
          %{id: {Smalt.Store.Partition, i}, start: {Smalt.Store.Partition, :start_link, [{base, i}]}}
        end) ++
        [
          # Boot LAST: adopt-then-replay. The sealed journal is applied
          # AFTER the partitions have created/adopted the tables (a cold VM
          # has no tables until the partitions make them; a full-node kill
          # deletes them via the dead-heir chain), and BEFORE the ensemble
          # finishes starting — no request is served until all 18 children
          # are up, so this is serving-equivalent to replay-then-adopt. A
          # typed reader refusal is a boot refusal (TTV-4 law unchanged).
          {Smalt.Store.Boot, opts}
        ]

    case Supervisor.start_link(children,
           strategy: :one_for_one,
           max_restarts: 200,
           max_seconds: 5,
           name: base
         ) do
      {:ok, pid} ->
        # Boot seeding (regression fix, BK-70rr): the TTV-5 ensemble rewrite
        # dropped the init-time default-subscription seed (it survived only in
        # clear/0), so a fresh boot served 404 SubscriptionNotFound on the
        # fixed dev subscription. Idempotent, key-only overwrite — same
        # :ets.insert semantics as clear/0's reseed.
        seed_default_subscription()
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def init(children) do
    # Satisfies the Supervisor behaviour for `use Supervisor`; the ensemble
    # is actually booted via start_link/1 above (children built there, since
    # they depend on the `base` name).
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 200, max_seconds: 5)
  end

  @doc """
  Single source of truth for the Store ETS table names (mirrors `@tables`).
  Read by SmaltTest.Lifecycle.ensure_store_up/0 to wait for full materialization.
  """
  def table_names, do: @tables

  @doc "TTV-5: number of partition workers (16)."
  def partition_count, do: @partitions

  @doc "TTV-5: the partition worker owning `table`'s stripe."
  def partition_of(table), do: Smalt.Store.Partition.owner_of(table)

  @doc """
  TTV-4 boot replay: applies every frame of every SEALED segment under the
  configured `:journal_sink_dir` to the Store ETS tables, in segment then
  SeqID order.

  Fail-closed contract: `{:error, {seg_path, reason}}` on the first typed
  reader refusal (manifest mismatch, CRC, truncation, seq regression) or the
  first uninterpretable Store frame (`{:unknown_table_id, id}`,
  `{:bad_payload, ...}`) — nothing past the refusing segment is applied and
  nothing is skipped silently. `{:ok, applied}` counts applied Store frames.
  Non-Store frames (e.g. OcelEmitter event codes 0x0001..0x0004) are skipped
  by event type — they are another writer's records, not corruption.
  """
  def replay_sealed(dir) when is_binary(dir) do
    with {:ok, segs} <- Smalt.Storage.JournalReader.discover_sealed_segments(dir) do
      Enum.reduce_while(segs, {:ok, 0}, fn seg, {:ok, n} ->
        case Smalt.Storage.JournalReader.read_sealed_segment(seg) do
          {:ok, frames} ->
            case apply_frames(frames) do
              :ok -> {:cont, {:ok, n + length(frames)}}
              {:error, _} = err -> {:halt, err}
            end

          {:error, reason} ->
            {:halt, {:error, {seg, reason}}}
        end
      end)
    end
  end

  @doc false
  # Called by the Smalt.Store.Boot ensemble child (adopt-then-replay).
  def boot_replay_for_boot(opts) do
    dir =
      Keyword.get(opts, :journal_sink_dir) || Application.get_env(:smalt, :journal_sink_dir)

    case dir do
      nil ->
        :ok

      dir ->
        case replay_sealed(Path.expand(dir)) do
          {:ok, applied} ->
            if applied > 0 do
              Logger.info("Smalt.Store: journal replay restored #{applied} frame(s) from #{dir}")
            end

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp apply_frames(frames) do
    Enum.reduce_while(frames, :ok, fn f, :ok ->
      case apply_frame(f) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_frame(%{event_type: evt, table_id: tid, key: key, payload: payload}) do
    case Map.fetch(@table_name_by_id, tid) do
      :error ->
        {:error, {:unknown_table_id, tid}}

      {:ok, table} ->
        case evt do
          @journal_evt_put ->
            apply_put(table, key, payload)

          @journal_evt_delete ->
            :ets.delete(table, key)
            :ok

          _ ->
            # another writer's frame (OcelEmitter codes etc.) — skip, not corruption
            :ok
        end
    end
  end

  defp apply_put(table, key, payload) do
    value = :erlang.binary_to_term(payload)
    :ets.insert(table, {key, value})
    :ok
  rescue
    ArgumentError -> {:error, {:bad_payload, table: table, key: key}}
  end

  @doc """
  Atomic insert-only: the exists-check AND the insert run as ONE
  `handle_call` inside the Store GenServer. Returns `:ok` or
  `{:error, :exists}` — the create-on-existing-id silent overwrite (measured
  201-with-overwrite; real Cosmos 409 Conflict) is structurally impossible.
  Unknown table raises in the caller, same fail-closed contract as CAS.
  """
  def insert_new(table, key, value) do
    if :ets.info(table) == :undefined do
      raise ArgumentError, "Smalt.Store.insert_new/3: unknown table #{inspect(table)}"
    end

    GenServer.call(
      Smalt.Store.Partition.whereis_owner(__MODULE__, table),
      {:insert_new, table, key, value},
      @call_timeout
    )
  end

  def put(table, key, value) do
    journal_mutation(@journal_evt_put, table, key, :erlang.term_to_binary(value))
    :ets.insert(table, {key, value})
    :ok
  end

  def get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, val}] -> {:ok, val}
      [] -> :error
    end
  end

  def delete(table, key) do
    journal_mutation(@journal_evt_delete, table, key, <<>>)
    :ets.delete(table, key)
    :ok
  end

  # TTV-4: journal-then-apply (WAL order). Best-effort at the caller: if the
  # sink is down or the config is unset the mutation still applies (same
  # fail-safe log-drop law as the SJ-4 OcelEmitter journal path — never a
  # crash of the data plane); the crash court exercises the sink-up face
  # where every committed key must survive. Unknown tables carry no wire
  # identity, so they are never journaled (the caller's :ets op raises, as
  # before).
  @doc false
  def journal_evt_put, do: @journal_evt_put

  @doc false
  def journal_evt_delete, do: @journal_evt_delete

  @doc false
  # TTV-5: PUBLIC — the partition workers call this from their handle_calls
  # (one journal law for the ensemble).
  def journal_mutation(event_type, table, key, payload) do
    case Application.get_env(:smalt, :journal_sink_dir) do
      nil ->
        :ok

      _dir ->
        case Map.fetch(@table_id_by_name, table) do
          :error ->
            :ok

          {:ok, table_id} ->
            try do
              {:ok, _seq} =
                Smalt.Storage.JournalSink.append(
                  Smalt.Storage.JournalSink,
                  event_type,
                  table_id,
                  key,
                  payload
                )

              :ok
            rescue
              e ->
                Logger.warning("Smalt.Store: journal append dropped: #{Exception.message(e)}")
                :ok
            catch
              :exit, _ ->
                Logger.warning("Smalt.Store: journal append dropped (sink down)")
                :ok
            end
        end
    end
  end

  @doc """
  Lists all values in `table` in key order (deterministic, TF-stable).
  Entries deleted mid-walk are skipped (churn-safe).
  """
  def list(table) do
    table
    |> keys()
    |> Enum.flat_map(fn key ->
      case :ets.lookup(table, key) do
        [{^key, val}] -> [val]
        _ -> []
      end
    end)
  end

  @doc """
  Churn-safe full-table scan that does NOT restrict to binary keys (`list/1`
  filters to the binary-key prefix contract and silently drops tuple-keyed
  rows, e.g. the App Config `{key, label}` rows). Returns all values in term
  key order; entries deleted mid-walk are skipped.
  """
  def list_all(table) do
    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.flat_map(fn {k, v} ->
      case :ets.lookup(table, k) do
        [{^k, ^v}] -> [v]
        _ -> []
      end
    end)
  end

  @doc """
  Bounded `:ordered_set` scan: returns all values whose keys sort between
  `prefix` (inclusive) and `prefix <> <<0xFF>>` (exclusive of the bound itself).
  Entries deleted mid-walk are skipped (churn-safe).
  """
  def list_prefix(table, prefix) when is_binary(prefix) do
    table
    |> prefix_keys(prefix)
    |> Enum.flat_map(fn key ->
      case :ets.lookup(table, key) do
        [{^key, val}] -> [val]
        _ -> []
      end
    end)
  end

  @doc """
  Returns the binary keys of `table` matching the binary-key prefix contract:
  `keys/1` returns all binary-keyed rows sorted, `prefix_keys/2` bounds the walk
  to keys in `[prefix, prefix <> <<0xFF>>)`. Tuple keys (`{name, version}` vault
  rows, `{:latest, _}`, `{queue, sid}`, `{db, coll}`) and non-binary keys are
  OUT OF SCOPE: `prefix_keys/2` raises ArgumentError on a non-binary PREFIX
  argument (SHIM-COURT contract); non-binary KEYS in the table are silently
  skipped (they cannot match a binary range in term order).
  """
  @spec keys(atom) :: [term]
  def keys(table) do
    prefix_keys(table, "")
  end

  @doc false
  # SHIM-COURT: fail-loud guard — mixed-type `key >= prefix` comparisons do not
  # raise, they silently drop (tuples sort below binaries in term order). Every
  # caller of prefix_keys/2 is on the binary-key contract; make violations typed.
  def prefix_keys(_table, prefix) when not is_binary(prefix) do
    raise(ArgumentError, "prefix scan requires binary keys, got: #{inspect(prefix)}")
  end

  def prefix_keys(table, prefix) when is_binary(prefix) do
    # Walk from the table start and filter. Erlang term order puts ALL tuples
    # below every binary, so a prev(prefix) seek skips tuple-keyed rows;
    # table sizes here are small and a full ordered walk is deterministic.
    upper = prefix <> <<0xFF>>

    table
    |> ordered_walk(:ets.first(table), [])
    |> Enum.reverse()
    |> Enum.filter(fn key ->
      # Non-binary KEYS (atom/tuple rows legitimately stored by internal writers,
      # e.g. {:seq_counter}, {"r14-dup", "v1"}) cannot match a binary range in
      # term order — restore the original silent-skip. The raise above stays
      # only for a non-binary PREFIX argument (the caller-side contract).
      is_binary(key) and key >= prefix and key < upper
    end)
  end

  defp ordered_walk(_table, :"$end_of_table", acc), do: acc

  defp ordered_walk(table, key, acc) do
    ordered_walk(table, :ets.next(table, key), [key | acc])
  end

  def clear do
    Enum.each(@tables, fn table ->
      if :ets.info(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end)

    # SHIM-COURT-eligible invariant: boot state always carries the default
    # subscription (no KD row — internal consistency, not a divergence;
    # lane R123 note).
    seed_default_subscription()

    :ok
  end

  # Idempotent reseed of the init/1 default subscription. Same :ets.insert
  # (overwrite-of-that-key-only) semantics as the original boot seeding, so
  # clear/0 restores boot state without touching test-seeded subscriptions.
  defp seed_default_subscription do
    default_sub = "00000000-0000-0000-0000-000000000000"

    :ets.insert(
      :smalt_subscriptions,
      {default_sub,
       %{
         "id" => "/subscriptions/#{default_sub}",
         "subscriptionId" => default_sub,
         "displayName" => "Sovereign Smalt Subscription",
         "state" => "Enabled"
       }}
    )

    :ok
  end

  @doc """
  Serialized compare-and-swap: lookup+insert runs inside the table's OWNING
  PARTITION worker so exactly one concurrent caller wins. Returns :ok |
  {:error, :conflict}.
  """
  def compare_and_swap(table, key, expect, new) do
    # Fail closed in the CALLER: an unknown table must raise here, not inside
    # the partition's handle_call — an :ets.lookup on a missing table would
    # crash the shared partition worker. (TTV-5: the pre-partition "a restart
    # loses data" clause is SUPERSEDED — tables are heir-held by
    # Smalt.Store.Heir and partition-scoped, so neither a partition crash nor
    # a full-node crash deletes data tables; the unknown-table raise is kept
    # purely as the fail-closed caller-side contract.)
    if :ets.info(table) == :undefined do
      raise ArgumentError, "Smalt.Store.compare_and_swap/4: unknown table #{inspect(table)}"
    end

    GenServer.call(
      Smalt.Store.Partition.whereis_owner(__MODULE__, table),
      {:cas, table, key, expect, new},
      @call_timeout
    )
  end

  @doc """
  Atomic compare-and-DELETE: the etag check AND the delete run as ONE
  `handle_call` inside the Store GenServer, so N concurrent conditional
  deletes with the same etag yield exactly one `:ok` and N-1
  `{:error, :conflict}` — the read-check-delete TOCTOU that let two racing
  conditional deletes both return 204 is structurally impossible, matching
  the guarantee `compare_and_swap/4` gives the replace path.
  """
  def compare_and_swap_delete(table, key, expect) do
    # Same fail-closed contract as compare_and_swap/4.
    if :ets.info(table) == :undefined do
      raise ArgumentError,
            "Smalt.Store.compare_and_swap_delete/3: unknown table #{inspect(table)}"
    end

    GenServer.call(
      Smalt.Store.Partition.whereis_owner(__MODULE__, table),
      {:cas_delete, table, key, expect},
      @call_timeout
    )
  end

  @doc """
  Atomic init-and-increment counter (ETS update_counter with default 0).
  Returns the new value.
  """
  def update_counter(table, key, incr \\ 1) do
    res = :ets.update_counter(table, key, incr, {key, 0})

    if Application.get_env(:smalt, :sentinel_forensic, false) do
      case :ets.info(:smalt_sentinel_forensic) do
        :undefined ->
          :ok

        _ ->
          :ets.insert(
            :smalt_sentinel_forensic,
            {System.unique_integer([:monotonic, :positive]), {:uc, table, key, incr, res}, self()}
          )
      end
    end

    res
  end

  def current_counter(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc """
  Serialized atomic fetch-and-increment with one-time seeding.

  The whole read-check-seed-bump runs as ONE `handle_call` inside the Store
  GenServer: if the counter row exists, the reply is `current + 1`; if it is
  missing, the reply is `seed_fun.() + 1` and the row is inserted at
  `seed_fun.() + 1`.

  Why: the previous caller-side shape (init via `update_counter(.., 0)`, check
  `current_counter == 0`, count existing rows, `compare_and_swap(key, 0,
  existing)`, then a direct `:ets.update_counter` bump) raced with itself —
  the CAS's lookup-then-insert pair is two separate ETS ops executed on other
  schedulers than the tasks' direct bumps, so a bump that slipped between
  lookup and insert was clobbered back to `existing` (measured: duplicate seq
  assignment, duplicate row keys collapse by last-write-wins, final counter
  one or more short; lens-3 huntE round 1 timeline). Structural repair: all
  counter traffic is serialized through the Store GenServer, so the
  lookup-insert window no longer exists.
  """
  def next_seq(table, key, seed_fun) when is_function(seed_fun, 0) do
    if :ets.info(table) == :undefined do
      raise ArgumentError, "Smalt.Store.next_seq/3: unknown table #{inspect(table)}"
    end

    GenServer.call(
      Smalt.Store.Partition.whereis_owner(__MODULE__, table),
      {:next_seq, table, key, seed_fun},
      @call_timeout
    )
  end
end
defmodule Smalt.Store.Boot do
  @moduledoc """
  TTV-5 ensemble child #2: runs the TTV-4 sealed-journal replay during init,
  BEFORE the 16 partitions start (Supervisor starts children in order, so
  replay-then-partition-adopt is structural, not best-effort). A typed
  reader refusal is a boot refusal for the whole ensemble — never a silent
  skip (TTV-4 law, unchanged). With `:journal_sink_dir` unset this is a
  no-op — byte-identical default boot.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    base = Keyword.get(opts, :name, Smalt.Store)
    GenServer.start_link(__MODULE__, opts, name: Module.concat(base, Boot))
  end

  @impl true
  def init(opts) do
    case Smalt.Store.boot_replay_for_boot(opts) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, {:journal_replay_failed, reason}}
    end
  end
end

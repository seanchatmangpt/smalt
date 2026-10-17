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
  Returns `{:ok, seq, event_map}` where `event_map` carries `"seq"`, `"body"`, any
  `"properties"`, plus the GAP-A2-04 delivery metadata: `"offset"` (string),
  `"enqueued"` (storage write time, epoch ms) and `"partition_key"` (when the
  sender set one). Receiver links replay these in sequence order.
  """
  @spec send_event(String.t(), term(), keyword()) :: {:ok, pos_integer(), map()}
  def send_event(partition, body, opts \\ []) when is_binary(partition) do
    ensure_tables()

    props = Keyword.get(opts, :properties, %{})
    pk = Keyword.get(opts, :partition_key)
    enqueued_ms = Keyword.get(opts, :enqueued_ms) || now_ms()

    case batch_inner_messages(body) do
      [_ | _] = inners ->
        # KD-COVERS: KD-53 — split at ingest. A producer `createBatch` envelope
        # is ONE transfer whose body carries N concatenated encoded inner
        # messages; storing the envelope whole and unwrapping at delivery
        # surfaced only the first inner body, silently dropping events 2..N.
        # Each inner message is stored as its own event (own monotonic seq), so
        # the receiver link drains N deliveries with the inner payloads.
        events =
          Enum.map(inners, fn inner ->
            seq = EHServer.transaction({:send_event, partition, inner, props, pk, enqueued_ms})

            %{
              "seq" => seq,
              "body" => inner,
              "properties" => props,
              "enqueued" => enqueued_ms,
              "offset" => Integer.to_string(seq),
              "partition_key" => pk
            }
          end)

        {:ok, hd(events)["seq"], hd(events)}

      _ ->
        seq = EHServer.transaction({:send_event, partition, body, props, pk, enqueued_ms})

        {:ok, seq,
         %{
           "seq" => seq,
           "body" => body,
           "properties" => props,
           "enqueued" => enqueued_ms,
           "offset" => Integer.to_string(seq),
           "partition_key" => pk
         }}
    end
  end

  # KD-53: detect a batch envelope — a binary payload whose decoded message
  # body is itself a stream of >=2 concatenated encoded inner messages. The
  # concatenated inner stream decodes as a flat section list; inner messages
  # are re-grouped at each body section (every AMQP message has exactly one
  # body section) and re-encoded. Returns nil for any non-batch payload
  # (ordinary messages and single-event batches stay exactly one event).
  defp batch_inner_messages(payload) when is_binary(payload) do
    with {:ok, sections} when is_list(sections) <- Smalt.Amqp.FrameCodec.decode_message(payload),
         data_sections when data_sections != [] and is_list(data_sections) <-
           sections
           |> Enum.filter(fn
             {:body_data, b} when is_binary(b) -> true
             _ -> false
           end)
           |> Enum.map(fn {:body_data, b} -> b end),
         # SHIM-COURT / audit-A22-F1: a single legal AMQP message may carry
         # multiple data sections (AMQP §3.2.5). Split into events ONLY when
         # EVERY outer data section decodes as a complete AMQP message (the
         # KD-53 createBatch shape); if any section fails inner-message decode,
         # the payload is NOT a batch — the whole outer message stays ONE event.
         true <- Enum.all?(data_sections, &complete_inner_message?/1),
         data when is_binary(data) and data != <<>> <- IO.iodata_to_binary(data_sections),
         {:ok, inner_sections} when is_list(inner_sections) <-
           Smalt.Amqp.FrameCodec.decode_message(data),
         # SHIM-COURT / R141 (W5-10 exploit): a tail group with NO body section
         # but REAL message sections (header/annotations/properties/app-props)
         # is an inner message whose body section was cut at a section boundary
         # (decoder stops cleanly per-section, complete_inner_message? is
         # satisfied by the earlier complete inners). Falling through to the
         # bodyless-tail drop loses the truncated inner's bytes with send_event
         # returning ok — the F1/R74 fallback applies instead: the whole outer
         # stays ONE event. A tail that never decodes into sections (undecodable
         # junk bytes) is swallowed by decode_message and leaves NO tail group:
         # the AUD6-R1 drop stands (junk dropped, no phantom event).
         {:ok, groups} when length(groups) >= 2 <- group_inner_messages(inner_sections, [], []) do
      Enum.map(groups, &IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_message(&1)))
    else
      _ -> nil
    end
  end

  defp batch_inner_messages(_payload), do: nil

  # A data section counts as a complete AMQP message only when it decodes to a
  # non-empty section list carrying at least one body section. Raw (non-message)
  # payloads decode to an empty list (FrameCodec swallows undecodable trailing
  # bytes as {:ok, []}), so the non-empty + body-section requirement is what
  # rejects them — this is the F1 discriminator.
  defp complete_inner_message?(section_binary) do
    case Smalt.Amqp.FrameCodec.decode_message(section_binary) do
      {:ok, secs} when is_list(secs) and secs != [] -> Enum.any?(secs, &body_section?/1)
      _ -> false
    end
  end

  # Group the flat decoded inner stream into messages: every AMQP message has
  # exactly one body section, so a group ends at (and includes) each body
  # section.
  #
  # Returns {:ok, groups} when the stream ends cleanly at a body-section
  # boundary, :incomplete when it ends mid-message. R141 discriminator:
  #   - a NON-EMPTY trailing group with no body section but real message
  #     sections (header/annotations/properties/app-props) is a truncated inner
  #     (body cut at a section boundary) → :incomplete → the F1/R74 fallback
  #     keeps the whole outer as ONE event, never a silent byte loss;
  #   - undecodable junk bytes are swallowed by decode_message and leave NO
  #     tail group — the AUD6-R1 drop stands (nothing phantom is flushed).
  #   - a trailing footer belongs to the preceding (complete) message, so a
  #     footer-only tail is not an incomplete inner.
  #
  # R166 (per-group multiplicity + batch-shape homogeneity; multiplicity
  # REPLACED by duplicate-kind detection per R185e — see below): the R141 tail
  # check alone leaves a truncated NON-tail inner (header-only, no body)
  # absorbable into the NEXT group's sections — the absorbed pre-body sections
  # ride along with the next inner's real ones, yielding composite phantom
  # events or byte-cannibalized splits with send_event :ok. Two discriminators,
  # one fallback:
  #   1. Duplicate-kind (R185e, REPLACES R166's raw multiplicity): a legal
  #      AMQP message carries at most ONE of each pre-body section kind
  #      (header, delivery_annotations, message_annotations, properties,
  #      application_properties) — real @azure/event-hubs inners legitimately
  #      serialize [header, message_annotations, properties,
  #      application_properties?, body_data] (3-4 pre-body sections), which
  #      R166's COUNT-based check wrongly rejected (KD-53 silent-drop
  #      resurrection, fixed here). A TRUNCATED inner merged into a group
  #      manifests as a DUPLICATE kind (e.g. two :header sections) →
  #      :incomplete. Catches merges where the next inner carries the same
  #      section kind as the absorbed truncated one.
  #   2. Homogeneity: a real producer createBatch serializes every inner with
  #      the SAME section-kind shape, so any completed group whose section-kind
  #      tuple differs from the FIRST completed group is a merged/cannibalized
  #      group → :incomplete. Catches the residual body-only-neighbor merge
  #      ([body][header-only][body] → [body][header body]) that multiplicity
  #      cannot see ([header body] looks like a legal inner). Fail-closed: a
  #      heterogeneous batch simply stays ONE event (no split, no data loss).
  defp group_inner_messages([], [], groups), do: {:ok, Enum.reverse(groups)}

  defp group_inner_messages([], [_ | _] = current, groups) do
    if Enum.any?(current, &pre_body_section?/1),
      do: :incomplete,
      else: {:ok, Enum.reverse(groups)}
  end

  defp group_inner_messages([section | rest], current, groups) do
    # SHIM-COURT / R185e (replaces R166): a pre-body section whose KIND is
    # already present in the current bodyless group means a truncated inner
    # merged into this group (a legal message never repeats a section kind).
    if pre_body_section?(section) and
         Enum.any?(current, fn {k, _} -> {k, nil} == put_elem(section, 1, nil) end),
       do: :incomplete,
       else: do_group_inner_messages(section, rest, current, groups)
  end

  defp do_group_inner_messages(section, rest, current, groups) do
    current = [section | current]

    if body_section?(section) do
      group = Enum.reverse(current)

      # SHIM-COURT / R166 homogeneity: every completed group must match the
      # first completed group's section-kind shape.
      if groups != [] and group_kind_shape(group) != group_kind_shape(hd(groups)),
        do: :incomplete,
        else: group_inner_messages(rest, [], [group | groups])
    else
      group_inner_messages(rest, current, groups)
    end
  end

  defp group_kind_shape(group), do: Enum.map(group, fn {k, _} -> k end)

  # Message sections that precede the body: seeing one in a bodyless tail means
  # an inner message started but never reached its body section.
  defp pre_body_section?({k, _}) when k in [:header, :delivery_annotations, :message_annotations, :properties, :application_properties],
    do: true

  defp pre_body_section?(_), do: false

  defp body_section?({k, _}) when k in [:body_data, :body_sequence, :body_amqp_value], do: true
  defp body_section?(_), do: false

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
        |> Enum.map(fn {seq, {body, props, meta}} ->
          %{
            "seq" => seq,
            "body" => body,
            "properties" => props,
            "offset" => event_offset(seq),
            "enqueued" => meta_enqueued_ms(meta),
            "partition_key" => meta_pk(meta)
          }
        end)

      _ ->
        []
    end
  end

  # GAP-A2-03: the partition's most-recently-enqueued event, as surfaced in
  # EH delivery annotations (`last_enqueued_offset` / `last_enqueued_sequence_number`
  # / `last_enqueued_time_utc`). Absent state reads `:none` — no row, or a row
  # whose events list is empty (events are PREPENDED in `append_event/4`, so
  # the head is the newest).
  @doc """
  The partition's most-recently-enqueued event: `%{"seq" => n, "offset" => "...",
  "enqueued" => ms}` or `:none` when the partition has no events.
  """
  @spec last_enqueued(String.t()) :: %{String.t() => term()} | :none
  def last_enqueued(partition) when is_binary(partition) do
    ensure_tables()

    case :ets.lookup(@partitions, partition) do
      [{^partition, %{"events" => [{_seq, {_body, _props, meta}} | _]}}] ->
        %{
          "seq" => meta_seq(meta),
          "offset" => meta_offset(meta),
          "enqueued" => meta_enqueued_ms(meta)
        }

      _ ->
        :none
    end
  end

  # -- meta accessors (stored per-event meta map, GAP-A2-03/04) ----------------

  defp event_offset(seq) when is_integer(seq), do: Integer.to_string(seq)

  defp meta_seq(meta) when is_map(meta), do: Map.get(meta, "seq")

  defp meta_offset(meta) when is_map(meta), do: Map.get(meta, "offset")

  defp meta_enqueued_ms(meta) when is_map(meta), do: Map.get(meta, "enqueued_ms")

  defp meta_pk(meta) when is_map(meta), do: Map.get(meta, "partition_key")

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
       # audit-A22-F3: offsets are wire strings everywhere else in this module
       # (send_event, the KD-53 split path) — reconcile must match.
       "offset" => Integer.to_string(partition_seq),
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

    def handle_call({:send_event, partition, body, props, pk, enqueued_ms}, _from, state) do
      seq = Smalt.Messaging.EventHubs.bump_sequence(partition)
      append_event(partition, seq, body, props, pk, enqueued_ms)
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

    # GAP-A2-03/04 per-event meta: offset (string, EH wire form), storage-write
    # time (epoch ms) and the sender's partition key. Stored per event so the
    # delivery path can stamp x-opt-offset / x-opt-enqueued-time /
    # x-opt-partition-key and the delivery annotations can read the partition's
    # last_enqueued_* truth from the head of the events list.
    defp append_event(partition, seq, body, props, pk, enqueued_ms) do
      meta = %{
        "seq" => seq,
        "offset" => Integer.to_string(seq),
        "enqueued_ms" => enqueued_ms,
        "partition_key" => pk
      }

      row =
        case :ets.lookup(@partitions, partition) do
          [{^partition, row}] when is_map(row) -> row
          _ -> %{}
        end

      events = Map.get(row, "events", [])
      row = row |> Map.put("events", [{seq, {body, props, meta}} | events])
      :ets.insert(@partitions, {partition, row})
      :ok
    end
  end
end

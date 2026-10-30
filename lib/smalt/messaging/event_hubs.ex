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

  ## Consumer groups (engine, v2)

  Consumer groups are first-class engine records keyed `{hub, group}` in the
  `:smalt_eh_cgs` table (name, created-at ms, user metadata), alongside the
  ARM-plane records. `$default` auto-exists on every hub (lazily seeded by the
  serialized server — no caller-side `:ets` writes, same lens-5 discipline as
  checkpoints). `reserve_processing/5` validates the group and returns a typed
  `ConsumerGroupNotFound` face for an unknown group; `reserve_processing/4`
  keeps its legacy claim-blind shape for existing callers. The wire-level
  attach refusal rides `consumer_group_face/1` (echo-attach + typed detach,
  the same shape as the partition-pin refusal in `connection.ex`).
  """


  @partitions :smalt_eh_partitions

  @typedoc "Typed consumer-group face (wire-visible 404-class surface)."
  @type cg_face :: %{
          required(:status) => 404,
          required(:code) => String.t(),
          required(:condition) => String.t(),
          required(:description) => String.t()
        }

  alias Smalt.Messaging.EventHubs.Server, as: EHServer
  alias Smalt.Messaging.EhThrottle

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
  @spec send_event(String.t(), term(), keyword()) ::
          {:ok, pos_integer(), map()} | {:error, {:throttled, map()}}
  def send_event(partition, body, opts \\ []) when is_binary(partition) do
    ensure_tables()

    props = Keyword.get(opts, :properties, %{})
    pk = Keyword.get(opts, :partition_key)
    enqueued_ms = Keyword.get(opts, :enqueued_ms) || now_ms()

    # T30-F1 wiring (retry-after-audit F1): EhThrottle was a dead engine with
    # zero callers. Gate EVERY publish (batch counted as N events) through
    # EhThrottle.admit/2. Default-off by construction: with no quota set —
    # no `set_quota/3`, no hub-record "quota" field, and no
    # `config :smalt, :eh_ingress_quota` — admit/2 returns {:ok, :admitted}
    # without touching any state, so witnessed behavior is byte-identical.
    # Typed choice disclosed: default quota stays OFF (a hard-coded
    # events/second limit would trip soak/stress populations); operators opt
    # in via config :smalt, :eh_ingress_quota, {limit, window_ms}.
    n =
      case batch_inner_messages(body) do
        [_ | _] = inners -> length(inners)
        _ -> 1
      end

    case eh_admit_publish(hub_of(partition), n) do
      {:ok, :admitted} ->
        eh_store_events(partition, body, props, pk, enqueued_ms)

      {:throttled, face} ->
        {:error, {:throttled, face}}
    end
  end

  # First path segment of the storage partition key is the hub name
  # ("hub/partitions/0", "ns/hub/partition" and bare "hub" all reduce to
  # "hub"). Quotas key on this.
  defp hub_of(partition) when is_binary(partition) do
    partition |> String.split("/") |> hd()
  end

  defp eh_admit_publish(hub, n) do
    case Application.get_env(:smalt, :eh_ingress_quota, nil) do
      {limit, window_ms} when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 ->
        EhThrottle.ensure_table()
        EhThrottle.set_quota(hub, limit, window_ms)
        EhThrottle.admit(hub, n)

      _ ->
        EhThrottle.admit(hub, n)
    end
  end

  defp eh_store_events(partition, body, props, pk, enqueued_ms) do
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
  defp pre_body_section?({k, _})
       when k in [
              :header,
              :delivery_annotations,
              :message_annotations,
              :properties,
              :application_properties
            ],
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

  # -- Checkpoint management (T10 tail split: extracted verbatim to
  # Smalt.Messaging.EventHubs.Checkpoints; public surface unchanged)

  defdelegate compare_and_swap(group, partition, expect, new),
    to: Smalt.Messaging.EventHubs.Checkpoints

  defdelegate reserve_processing(group, partition, owner, ttl_ms),
    to: Smalt.Messaging.EventHubs.Checkpoints

  defdelegate reconcile(group, partition), to: Smalt.Messaging.EventHubs.Checkpoints

  # -- Consumer groups (engine, first-class records) -------------------------------

  @doc """
  Create (idempotently) consumer group `name` on `hub`. Returns
  `{:ok, record}` where record carries `"name"`, `"created"` (epoch ms),
  `"user_metadata"`. A re-PUT preserves the original created ts (ARM PUT
  semantics). `$default` cannot be created explicitly beyond its implicit
  seed — re-creating it is a no-op refresh of user metadata only.
  """
  @spec create_consumer_group(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, cg_face()}
  def create_consumer_group(hub, name, opts \\ [])
      when is_binary(hub) and is_binary(name) do
    ensure_tables()
    EHServer.transaction({:cg_create, hub, name, Keyword.get(opts, :user_metadata, "")})
  end

  @doc """
  Delete consumer group `name` on `hub`. `$default` refuses with the typed
  default-group face (real service semantics: the default group is
  undeletable); an unknown group refuses `ConsumerGroupNotFound` (404).
  Deleting a group also drops its `{group, partition}` checkpoint rows.
  """
  @spec delete_consumer_group(String.t(), String.t()) :: :ok | {:error, cg_face()}
  def delete_consumer_group(hub, name) when is_binary(hub) and is_binary(name) do
    ensure_tables()
    EHServer.transaction({:cg_delete, hub, name})
  end

  @doc """
  The group record for `{hub, name}`, with `$default` implicit. Unknown group
  → `{:error, cg_face}` (`ConsumerGroupNotFound`, 404).
  """
  @spec get_consumer_group(String.t(), String.t()) :: {:ok, map()} | {:error, cg_face()}
  def get_consumer_group(hub, name) when is_binary(hub) and is_binary(name) do
    ensure_tables()
    EHServer.transaction({:cg_get, hub, name})
  end

  @doc """
  All group records for `hub`; `$default` always present (prepended when no
  literal `$default` row exists — same synthesis rule as the ARM-plane
  `handle_cg_list`).
  """
  @spec list_consumer_groups(String.t()) :: [map()]
  def list_consumer_groups(hub) when is_binary(hub) do
    ensure_tables()
    EHServer.transaction({:cg_list, hub})
  end

  @doc "Whether consumer group `name` exists on `hub` (`$default` implicit)."
  @spec consumer_group_exists?(String.t(), String.t()) :: boolean()
  def consumer_group_exists?(hub, name) when is_binary(hub) and is_binary(name) do
    ensure_tables()
    EHServer.transaction({:cg_exists, hub, name})
  end

  @doc """
  The typed wire face for an unknown consumer group. Where the AMQP surface
  addresses a group-scoped link (`{hub}/ConsumerGroups/{cg}/Partitions/{n}`),
  the attach path gates with `consumer_group_exists?/2` and, on miss, answers
  the rhea contract (attach echo + typed detach) with this error:

      %{condition: "amqp:not-allowed",
        description: "The consumer group 'X' does not exist ...",
        code: "ConsumerGroupNotFound", status: 404}
  """
  @spec consumer_group_face(String.t()) :: cg_face()
  def consumer_group_face(name) when is_binary(name) do
    %{
      status: 404,
      code: "ConsumerGroupNotFound",
      condition: "amqp:not-allowed",
      description:
        "The consumer group '#{name}' does not exist on the Event Hub. " <>
          "Create it (ARM: PUT .../consumergroups/#{name}) or use an existing group."
    }
  end

  @doc """
  `reserve_processing/4` gated on group existence: unknown group → the typed
  `ConsumerGroupNotFound` face (no claim row is written); known group → the
  same per-`{group, partition}` lease as the legacy `/4` (per-group ownership:
  group A's claim never blocks group B on the same partition).
  """
  @spec reserve_processing(String.t(), String.t(), String.t(), term(), pos_integer()) ::
          :ok | {:error, cg_face()} | {:error, :conflict}
  def reserve_processing(hub, group, partition, owner, ttl_ms)
      when is_binary(hub) and is_binary(group) and is_binary(partition) and
             is_integer(ttl_ms) and ttl_ms > 0 do
    ensure_tables()

    case consumer_group_exists?(hub, group) do
      true -> reserve_processing(group, partition, owner, ttl_ms)
      false -> {:error, consumer_group_face(group)}
    end
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
    @cgs :smalt_eh_cgs
    # NB: module attributes do not leak into a nested defmodule (see
    # do_ensure_tables below) — literal re-bindings, not parent reads.
    @default_group "$default"
    # SCVD backpressure audit MED-3: typed call timeout (same value as the
    # implicit GenServer.call default; semantics unchanged).
    @call_timeout 5_000

    def transaction(request) do
      ensure_started()
      GenServer.call(@name, request, @call_timeout)
    end

    # SPOF-B / A-2: supervised-start contract. The server is a permanent child
    # of IntegrationSupervisor; this child_spec is the lawful start path. The
    # lazy fallback below remains only as a degraded ordering shim (e.g.
    # integration-only plane boots or early test callers before the broker
    # subtree starts) and never mints an unsupervised owner again: the tables
    # are heir'd to :init either way, so an owner crash no longer wipes EH
    # state.
    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.get(opts, :ref, :default)},
        start: {__MODULE__, :start_link, [opts]},
        restart: :permanent,
        type: :worker
      }
    end

    def start_link(opts \\ []) do
      name = Keyword.get(opts, :name, @name)

      case GenServer.start_link(__MODULE__, :ok, name: name) do
        {:error, {:already_started, pid}} when name == @name and is_pid(pid) ->
          # BK-70r orphan-reclaim: the degraded lazy shim (`unlinked_start/1`)
          # can mint an owner OUTSIDE the IntegrationSupervisor (app-down
          # window). Such a holder blocks every supervised boot of this
          # permanent child with :already_started — IntegrationSupervisor
          # exits, the whole plane bounces (witnessed: 4x "Application smalt
          # exited ... already started" + 25-test store_not_ready smear in
          # one full-suite run). SPOF-B contract: the supervisor owns the
          # name; any holder NOT minted by the current IntegrationSupervisor
          # (its pid absent from the holder's proc_lib $ancestors) is a
          # rogue — kill it and retry. Checked from the starting context
          # only (never Supervisor.which_children, which would deadlock:
          # the supervisor is mid-start_child here). Bounded retry loop
          # beats a re-mint race from concurrent lazy callers.
          reap_or_take(name, pid, 5)

        other ->
          other
      end
    end

    defp reap_or_take(_name, _holder, 0), do: {:error, {:eh_name_reclaim_failed, @name}}

    defp reap_or_take(name, holder, attempts) do
      if rogue_holder?(holder) do
        Process.exit(holder, :kill)
        :ok = await_name_released(holder)
        # Small post-kill settle: a concurrent lazy caller may re-mint in
        # the registration gap; re-check and re-reap (bounded).
        # SLEEP-CLASS: POLL-STEP — bounded settle between reclaim attempts.
        Process.sleep(5)

        case GenServer.start_link(__MODULE__, :ok, name: name) do
          {:error, {:already_started, next}} when is_pid(next) ->
            reap_or_take(name, next, attempts - 1)

          other ->
            other
        end
      else
        {:error, {:already_started, holder}}
      end
    end

    defp await_name_released(dead_pid) do
      deadline = System.monotonic_time(:millisecond) + 1_000

      retry = fn
        retry ->
          if Process.whereis(@name) in [nil, dead_pid] do
            :ok
          else
            if System.monotonic_time(:millisecond) < deadline do
              # SLEEP-CLASS: POLL-STEP — bounded poll awaiting name release
              # after the rogue-holder kill (1 s deadline).
              Process.sleep(5)
              retry.(retry)
            else
              :timeout
            end
          end
      end

      retry.(retry)
    end

    # True when the holder was NOT minted by the current IntegrationSupervisor.
    defp rogue_holder?(holder) do
      sup = Process.whereis(Smalt.Plane.IntegrationSupervisor)

      if is_nil(sup) do
        false
      else
        {:dictionary, dict} = :erlang.process_info(holder, :dictionary)

        ancestors =
          case List.keyfind(dict, :"$ancestors", 0) do
            {:"$ancestors", anc} -> anc
            nil -> []
          end

        sup not in ancestors
      end
    end

    defp ensure_started do
      case Process.whereis(@name) do
        nil ->
          # BK-104 (SPOF-B / A-2 residual): the direct GenServer.start here
          # races the supervisor's own restart of the killed permanent child.
          # When the caller's start wins the name, the supervisor's restart
          # attempt fails :already_started, its retry loop blows the restart
          # intensity, and the IntegrationSupervisor exits :shutdown — the
          # whole plane bounces (witnessed: app-exit :shutdown mid-court).
          # Route the lazy start through the supervisor; only when no
          # IntegrationSupervisor is running (integration-only plane, bare
          # test VM) do we fall back to an unlinked self-start, where no
          # supervisor exists to race.
          case supervised_start() do
            :ok ->
              :ok

            {:error, :integration_supervisor_not_running} ->
              unlinked_start({:eh_server_start_failed})

            {:error, reason} ->
              exit({:eh_server_start_failed, reason})
          end

        _pid ->
          :ok
      end
    end

    defp supervised_start do
      sup = Process.whereis(Smalt.Plane.IntegrationSupervisor)

      if is_nil(sup) do
        {:error, :integration_supervisor_not_running}
      else
        case Supervisor.start_child(sup, child_spec([])) do
          {:ok, _pid} -> :ok
          # The supervisor owns the child spec and is (re)starting it — never
          # start under our own process.
          {:error, {:already_started, _pid}} -> :ok
          {:error, {:already_present, _id}} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defp unlinked_start(fail_tag) do
      # BK-70r: start_link, not start — the shim owner is now MORTAL (linked
      # to its caller). An unlinked mint was immortal and, surviving an app
      # stop/start cycle while holding @name, blocked every supervised boot
      # of this permanent child forever (the run-1 app-exit cascade root).
      case GenServer.start_link(__MODULE__, :ok, name: @name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> exit({fail_tag, reason})
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
      Enum.each([@partitions, @checkpoints, @cgs], fn table ->
        if :ets.info(table) == :undefined do
          # NB: literal opts — module attributes do not leak into a nested
          # defmodule (the parent's @table_opts reads nil here).
          # SPOF-B / A-2: heir 3-tuple (shadow-table law, EhThrottle idiom) —
          # even if the owner dies before supervision restarts it, the tables
          # are re-parented to :init and seq/checkpoint/cg state survives.
          :ets.new(table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true,
            heir: Process.whereis(:init) || self()
          ])
        end
      end)

      :ok
    end

    # -- cg helpers (all defp, kept out of the handle_call clause run) -----------

    defp cg_not_found(name), do: Smalt.Messaging.EventHubs.consumer_group_face(name)

    # $default auto-exists: ensure its row before any read/write on the group.
    defp cg_ensure_default(hub) do
      unless :ets.member(@cgs, {hub, @default_group}) do
        :ets.insert(@cgs, {{hub, @default_group}, cg_record(hub, @default_group, "")})
      end
    end

    defp cg_record(hub, name, meta) do
      %{
        "name" => name,
        "hub" => hub,
        "created" => System.system_time(:millisecond),
        "user_metadata" => meta
      }
    end

    defp cg_upsert(hub, name, meta) do
      key = {hub, name}

      case :ets.lookup(@cgs, key) do
        [{^key, rec}] ->
          # Idempotent re-PUT: preserve the original created ts.
          rec = Map.put(rec, "user_metadata", meta)
          :ets.insert(@cgs, {key, rec})
          rec

        [] ->
          rec = cg_record(hub, name, meta)
          :ets.insert(@cgs, {key, rec})
          rec
      end
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
        cp =
          case current["claim"] do
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

    # -- Consumer groups ---------------------------------------------------------
    # All group mutations AND reads route through the serialized server so the
    # `$default` lazy seed is race-free (same lens-5 discipline as checkpoints:
    # no caller-side :ets writes on this table).

    def handle_call({:cg_create, hub, name, meta}, _from, state) do
      cg_ensure_default(hub)

      {:reply, {:ok, cg_upsert(hub, name, meta)}, state}
    end

    def handle_call({:cg_delete, hub, name}, _from, state) do
      cg_ensure_default(hub)

      cond do
        name == @default_group ->
          {:reply,
           {:error,
            %{
              status: 409,
              code: "ConsumerGroupNotDeletable",
              condition: "amqp:not-allowed",
              description: "The default consumer group cannot be deleted."
            }}, state}

        :ets.member(@cgs, {hub, name}) ->
          :ets.delete(@cgs, {hub, name})
          # Cascade: the group's checkpoint namespace drops with the group.
          # Checkpoint keys are {group, partition}; the partition component
          # carries the hub in the storage form "hub/partitions/n", so only
          # rows on the deleted group's hub are removed (legacy bare-partition
          # keys are left to sweep/0 — never a cross-hub delete).
          :ets.tab2list(@checkpoints)
          |> Enum.each(fn
            {{g, p} = cg_key, _cp} when g == name and is_binary(p) ->
              if String.starts_with?(p, "#{hub}/"), do: :ets.delete(@checkpoints, cg_key)

            _ ->
              :ok
          end)

          {:reply, :ok, state}

        true ->
          {:reply, {:error, cg_not_found(name)}, state}
      end
    end

    def handle_call({:cg_get, hub, name}, _from, state) do
      cg_ensure_default(hub)

      case :ets.lookup(@cgs, {hub, name}) do
        [{{^hub, ^name}, rec}] -> {:reply, {:ok, rec}, state}
        _ -> {:reply, {:error, cg_not_found(name)}, state}
      end
    end

    def handle_call({:cg_list, hub}, _from, state) do
      cg_ensure_default(hub)

      items =
        @cgs
        |> :ets.tab2list()
        |> Enum.filter(fn {{h, _g}, _rec} -> h == hub end)
        |> Enum.map(fn {_k, rec} -> rec end)
        |> Enum.sort_by(& &1["created"])

      {:reply, items, state}
    end

    def handle_call({:cg_exists, hub, name}, _from, state) do
      cg_ensure_default(hub)
      {:reply, :ets.member(@cgs, {hub, name}), state}
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

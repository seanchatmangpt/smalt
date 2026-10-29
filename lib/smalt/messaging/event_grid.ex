defmodule Smalt.Messaging.EventGrid do
  @moduledoc """
  Integration-plane Event Grid delivery engine (AZB-07).

  At-least-once fan-out of CloudEvent-shaped events to in-process subscribers,
  acked per event. Contract (ticket spec):

    - dedup key `id`: a re-published event with an already-seen `id` is
      dropped (publish returns `:duplicate` vs `:fresh`); redeliveries carry
      the SAME `id`.
    - subscription survives subscriber crash: un-acked events stay queued and
      are redelivered to the recovered subscriber. Never loss.
    - `delivery_mode` read site (one-source via `Smalt.Config.event_grid/0`):
      `:at_least_once` (or unset) delivers per this contract; any other value
      is typed-refused at delivery. A lossy mode is NOT implemented — the
      anti-vacuity shim (ack-before-dispatch) witnesses why (see receipt
      `azb-07-integration-plane.md`).
    - zero `Process.sleep`: redelivery after recovery is driven by the
      resubscribe itself plus a bounded `Process.send_after` backoff.
    - DLQ blob spillover (G3 / Sovereign Midnight, opt-in): when
      `config :smalt, :event_grid, dlq: [enabled: true]` is set, a subscriber
      whose delivery attempts exhaust `max_delivery_attempts` while DOWN has
      its dead event spilled to the blob engine
      (`Smalt.DataPlane.BlobStorage`) under container `eg-dlq-<subscriber>`
      as `<seq>-<event-id>.json` with metadata `DeadLetterReason=
      MaxDeliveryAttemptsExceeded`, `subscriber`, `attempts`, `last_error`,
      plus a `[:smalt, :event_grid, :dead_lettered]` telemetry event and the
      typed face `{:dead_lettered, ...}`. Default is OFF — byte-identical
      behavior (never loss: events stay queued until recovery) when unset.

  ## Push-contract fidelity (KD-101 in-proc face, v26.10.20)

  Deliveries raise the in-proc face to the Azure Event Grid push contract:

    - every delivery attempt carries Event Grid system properties —
      `aeg-delivery-count` (increments per redelivery: first attempt = 1,
      recovery redelivery = 2, ...) and `aeg-subscription-name`, plus
      `aeg-event-type: Notification` and `aeg-data-version` — delivered as
      the 6th element of `{:event_grid, topic, name, id, envelope, sys}`;
    - the 5th element is the full envelope (CloudEvents 1.0: `specversion`,
      `id`, `source`, `type`, `time`, `subject`, `data`), not the raw body;
      `time` is the publish-time stamp, stable across redeliveries;
    - the subscription's `eventDeliverySchema` (subscribe opts
      `schema: :cloud_event_schema | :event_grid_schema`, default
      `:cloud_event_schema`) routes the envelope shape: CloudEvents 1.0
      (string-keyed) vs Event Grid schema (`id`/`topic`/`subject`/
      `eventTime`/`eventType`/`data`/`dataVersion`). Unknown schemas are
      typed-refused at subscribe. DLQ spill bodies and budget exhaustion
      faces are unchanged.

  ## Backpressure bounds (SCVD-T8 remediation, v26.10.20)

  Two typed capacity bounds close the HIGH findings of the backpressure
  audit (`docs/jira/v26.10.20/receipts/scvd-backpressure-audit.md`):

    - per-subscriber queue cap `:max_queue_len` (default
      10_000): on overflow the OLDEST queued event is
      dropped (drop-oldest policy) with a
      `[:smalt, :event_grid, :queue_overflow_dropped]` telemetry event per
      drop. At-least-once holds within the capacity window; a slow or DOWN
      subscriber can no longer grow its queue without bound.
    - per-topic dedup cap `:max_seen_ids` (default 100_000):
      insertion-ordered eviction of the oldest seen `id` (FIFO prune), with a
      `[:smalt, :event_grid, :dedup_evicted]` telemetry event per eviction.
      A re-publish of an evicted id is admitted again as `:fresh` — the
      dedup window is bounded, not infinite.

  Both caps are configurable via `config :smalt, :event_grid,
  max_queue_len: n, max_seen_ids: n` (emulator-scale overridable; tests set
  them small to exercise the drop paths for real).

  Lazy-started (QueueStore pattern): no application.ex child (AZB-09 owns the
  child-list partition; `:plane` unset = today's child list).
  """

  use GenServer

  require Logger

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.Messaging.EgAdvancedFilters
  alias Smalt.Store

  @name __MODULE__
  @redeliver_backoff_ms 50
  @default_max_delivery_attempts 10

  # SCVD-T8 backpressure bounds (defaults; overridable via config
  # `:smalt, :event_grid, max_queue_len:/max_seen_ids:`).
  @default_max_queue_len 10_000

  # SCVD backpressure audit MED-3: typed call timeout (same value as the
  # implicit GenServer.call default; semantics unchanged).
  @call_timeout 5_000
  @default_max_seen_ids 100_000

  # -- Client API ---------------------------------------------------------------

  @doc "Starts the engine."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc "Child spec (embedder/azsim use; application.ex unchanged this ticket)."
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Ensures the engine runs (lazy-start, QueueStore pattern) — returns the
  server pid.
  """
  @spec server() :: pid()
  def server do
    case Process.whereis(@name) do
      nil ->
        case start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  @doc """
  Publishes `event` (map with mandatory `:id`) to `topic`'s subscribers.
  Dedup key `id` per topic. Returns `:fresh` or `:duplicate`.
  """
  @spec publish(String.t() | atom(), %{required(:id) => term(), optional(term()) => term()}) ::
          :fresh | :duplicate
  def publish(topic, %{id: id} = event) when is_map(event) do
    validate_delivery_mode!()
    GenServer.call(server(), {:publish, topic, event, id}, @call_timeout)
  end

  def publish(_topic, event) do
    raise ArgumentError,
          "EventGrid.publish/2 requires a map with an :id key (dedup key), got: " <>
            inspect(event)
  end

  @doc """
  Subscribes `pid` (default self()) under `name` to `topic`. A subscription
  survives a crash of its pid: after a crash, re-subscribing the same
  `name` redelivers every un-acked event to the new pid.

  Opts: `:schema` — `:cloud_event_schema` (default) or `:event_grid_schema`,
  the subscription's stored `eventDeliverySchema`; routes the delivered
  envelope shape. Any other value is typed-refused. `:advanced_filters` —
  the ARM advancedFilters list (see `Smalt.Messaging.EgAdvancedFilters`);
  a subscription with filters receives only matching events (non-matching
  events are never queued for it; other subscribers unaffected). Malformed
  filters are typed-refused at subscribe (ArgumentError), mirroring real
  Event Grid's subscription-create validation. `:retry_policy` —
  `{max_delivery_attempts, event_time_to_live}`: the subscription's
  retryPolicy. `max_delivery_attempts` is an integer 1..30 (default 30);
  `event_time_to_live` is a positive integer SECONDS (smalt extension —
  real Event Grid uses hours/ISO-8601 durations; seconds accepted here so
  the TTL law is exercisable at emulator scale) or `{:hours, n}` /
  `"PTnH"`-style ISO-8601 duration (default 1 day = 86_400s). Out-of-range
  values are typed-refused at subscribe (ArgumentError), mirroring real
  Event Grid's subscription-create validation.
  """
  @spec subscribe(String.t() | atom(), term(), pid() | nil, keyword()) :: :ok
  def subscribe(topic, name, pid \\ nil, opts \\ []) do
    pid = pid || self()
    schema = validate_schema!(Keyword.get(opts, :schema))
    filters = Keyword.get(opts, :advanced_filters)
    if filters, do: EgAdvancedFilters.validate!(filters)
    policy = validate_retry_policy!(Keyword.get(opts, :retry_policy))
    GenServer.call(server(), {:subscribe, topic, name, pid, schema, filters, policy}, @call_timeout)
  end

  @doc "Acknowledges delivery of `id` by subscriber `name` on `topic`."
  @spec ack(String.t() | atom(), term(), term()) :: :ok
  def ack(topic, name, id) do
    GenServer.call(server(), {:ack, topic, name, id}, @call_timeout)
  end

  @doc "Returns `{pending_count, inflight, alive?}` for subscriber `name` on `topic`."
  @spec status(String.t() | atom(), term()) ::
          {non_neg_integer(), nil | {term(), term(), integer(), pos_integer()}, boolean()}
  def status(topic, name) do
    GenServer.call(server(), {:status, topic, name})
  end

  @doc "Drops a topic (test seam)."
  @spec reset(String.t() | atom()) :: :ok
  def reset(topic) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, {:reset, topic})
    end
  end

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, %{topics: %{}}}
  end

  @impl true
  def handle_call({:publish, topic, event, id}, _from, state) do
    t = topic_state(state, topic)

    if MapSet.member?(t.seen_ids, id) do
      {:reply, :duplicate, put_topic(state, topic, t)}
    else
      t = remember_id(t, id)
      t = Enum.reduce(Map.keys(t.subscribers), t, &enqueue(&2, topic, &1, id, event))
      {:reply, :fresh, put_topic(state, topic, dispatch(t, topic))}
    end
  end

  def handle_call({:subscribe, topic, name, pid, schema, filters, policy}, _from, state) do
    t = topic_state(state, topic)
    prev = t.subscribers[name]

    sub =
      if is_nil(prev) do
        new_sub(pid, schema, filters, policy)
      else
        # Recovery path: same subscription name, new pid. Keep the queue and
        # the seen_ids; replace the pid + monitor, then redeliver. The stored
        # eventDeliverySchema of the existing subscription is honored (the
        # recovery subscribe cannot mutate it).
        if prev[:monitor], do: Process.demonitor(prev.monitor, [:flush])

        # Redelivery: the un-acked inflight event (same id) goes back on the
        # queue so the recovered subscriber receives it (at-least-once). The
        # consumed attempts ride with the entry so the redelivery's
        # aeg-delivery-count continues the sequence.
        case prev.inflight do
          {id, ev, ts, attempts} ->
            prev
            |> Map.put(:alive?, true)
            |> Map.put(:pid, pid)
            |> Map.put(:monitor, Process.monitor(pid))
            |> Map.put(:inflight, nil)
            |> Map.update!(:queue, &:queue.in({id, ev, ts, attempts}, &1))

          _ ->
            prev
            |> Map.put(:alive?, true)
            |> Map.put(:pid, pid)
            |> Map.put(:monitor, Process.monitor(pid))
            |> Map.put(:inflight, nil)
        end
      end

    t = %{t | subscribers: Map.put(t.subscribers, name, sub)}
    {:reply, :ok, put_topic(state, topic, dispatch(t, topic))}
  end

  def handle_call({:ack, topic, name, id}, _from, state) do
    t = topic_state(state, topic)

    t =
      case t.subscribers[name] do
        %{inflight: {^id, _ev, _ts, _attempts}} = sub ->
          put_in(t.subscribers[name], %{sub | inflight: nil})

        _ ->
          t
      end

    {:reply, :ok, put_topic(state, topic, dispatch(t, topic))}
  end

  def handle_call({:status, topic, name}, _from, state) do
    t = topic_state(state, topic)
    sub = t.subscribers[name]
    {:reply, sub_status(sub), put_topic(state, topic, t)}
  end

  def handle_call({:reset, topic}, _from, state) do
    t = topic_state(state, topic)

    Enum.each(Map.values(t.subscribers), fn sub ->
      if sub[:monitor], do: Process.demonitor(sub.monitor, [:flush])
    end)

    {:reply, :ok, %{state | topics: Map.delete(state.topics, topic)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Subscriber crash: keep the subscription (queue + inflight preserved) so
    # the recovered subscriber is redelivered. Never loss. The exit reason is
    # preserved as the DLQ `last_error` witness.
    {:noreply, mark_down(state, ref, reason)}
  end

  def handle_info({:redeliver, topic, name}, state) do
    t = topic_state(state, topic)
    dlq = dlq_config()
    dlq_on? = dlq.enabled

    t =
      case t.subscribers[name] do
        # DLQ path (opt-in): the subscriber is DOWN — advance its delivery
        # budget: count the failed attempt and re-arm the bounded send_after
        # backoff, spill the exhausted event to the blob DLQ (typed
        # {:dead_lettered, ...} face + telemetry), and pull the next queued
        # event into the budget. Never loss when the DLQ write itself fails:
        # the event stays inflight and the timer re-arms it.
        %{alive?: false} = sub when dlq_on? ->
          put_in(t.subscribers[name], dlq_step(topic, name, sub, dlq))

        %{alive?: false} = sub ->
          # DLQ off (default): never loss, no drop — the timer only
          # re-dispatches after recovery. The consumed attempt is still
          # counted (the aeg-delivery-count of the eventual redelivery
          # continues the sequence); no spill, no drop.
          sub =
            case sub.inflight do
              {id, ev, ts, attempts} ->
                %{
                  sub
                  | inflight: {id, ev, ts, attempts + 1},
                    backoff_ref: nil
                }

              _ ->
                %{sub | backoff_ref: nil}
            end

          put_in(t.subscribers[name], sub)
          |> dispatch(topic)

        _ ->
          t
      end

    {:noreply, put_topic(state, topic, t)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals ----------------------------------------------------------------

  defp new_sub(pid, schema, filters, policy),
    do: %{
      pid: pid,
      monitor: Process.monitor(pid),
      alive?: true,
      schema: schema,
      filters: filters,
      retry_policy: policy,
      queue: :queue.new(),
      queued: MapSet.new(),
      inflight: nil,
      max_delivery_attempts: elem(policy, 0),
      event_time_to_live_s: elem(policy, 1),
      backoff_ref: nil,
      dlq_seq: 0,
      last_error: nil
    }

  # -- retryPolicy (w6be) ----------------------------------------------------------
  # Subscription-scoped retryPolicy: {max_delivery_attempts, event_time_to_live_s}.
  # Defaults mirror real Event Grid: 30 attempts, 1 day TTL.

  @retry_policy_defaults {30, 86_400}

  defp validate_retry_policy!(nil), do: @retry_policy_defaults

  defp validate_retry_policy!({max, ttl}) when is_integer(max) and is_integer(ttl) do
    unless max >= 1 and max <= 30 do
      raise ArgumentError,
            "EventGrid.subscribe/4 :retry_policy max_delivery_attempts must be 1..30, got #{max}"
    end

    unless ttl >= 1 do
      raise ArgumentError,
            "EventGrid.subscribe/4 :retry_policy event_time_to_live must be >= 1s, got #{ttl}"
    end

    {max, ttl}
  end

  # `{:hours, n}` and ISO-8601 "PTnH" / "PTnM" / "PTnS" duration forms.
  defp validate_retry_policy!({:hours, n}) when is_integer(n) and n >= 1,
    do: {30, n * 3_600}

  defp validate_retry_policy!(ttl) when is_binary(ttl) do
    case Regex.run(~r/^PT(\d+)([HMS])$/i, ttl) do
      [_, n, unit] ->
        secs =
          case String.upcase(unit) do
            "H" -> String.to_integer(n) * 3_600
            "M" -> String.to_integer(n) * 60
            "S" -> String.to_integer(n)
          end

        if secs < 1,
          do:
            raise(
              ArgumentError,
              "EventGrid.subscribe/4 :retry_policy event_time_to_live must be >= 1s"
            )

        {30, secs}

      nil ->
        raise ArgumentError,
              "EventGrid.subscribe/4 :retry_policy event_time_to_live must be seconds integer, " <>
                "{:hours, n}, or ISO-8601 PTnH/PTnM/PTnS, got #{inspect(ttl)}"
    end
  end

  defp validate_retry_policy!(other),
    do:
      raise(ArgumentError,
        message:
          "EventGrid.subscribe/4 :retry_policy must be {max_delivery_attempts, " <>
            "event_time_to_live_seconds}, got #{inspect(other)}"
      )

  # True when the queue entry's publish-time stamp is past the subscription's
  # event_time_to_live. Expired events are DROPPED at dispatch (never delivered,
  # typed telemetry) — the real Event Grid event-TTL law.
  defp entry_expired?(sub, {_id, _ev, ts, _attempts}) do
    ttl_s = sub[:event_time_to_live_s] || 86_400
    System.system_time(:millisecond) - ts > ttl_s * 1_000
  end

  # Drops every TTL-expired queued event for the subscription. Returns the
  # updated topic state. Each drop emits `[:smalt, :event_grid, :ttl_expired]`
  # (never delivered, never loss-silent — the drop is observed).
  defp drop_expired(t, topic, name) do
    case t.subscribers[name] do
      nil ->
        t

      sub ->
        {kept, dropped} =
          :queue.fold(
            fn entry, {kept, dropped} ->
              if entry_expired?(sub, entry) do
                {kept, [entry | dropped]}
              else
                {:queue.in(entry, kept), dropped}
              end
            end,
            {:queue.new(), []},
            sub.queue
          )

        Enum.each(dropped, fn {id, _ev, _ts, _attempts} ->
          :telemetry.execute(
            [:smalt, :event_grid, :ttl_expired],
            %{count: 1},
            %{topic: topic, subscriber: name, id: id}
          )
        end)

        put_in(t.subscribers[name], %{sub | queue: kept})
    end
  end

  defp topic_state(state, topic) do
    Map.get(state.topics, topic) ||
      %{seen_ids: MapSet.new(), seen_order: :queue.new(), subscribers: %{}}
  end

  defp put_topic(state, topic, t), do: %{state | topics: Map.put(state.topics, topic, t)}

  # -- SCVD-T8 backpressure bounds -------------------------------------------------

  defp max_queue_len,
    do: Keyword.get(Smalt.Config.event_grid(), :max_queue_len, @default_max_queue_len)

  defp max_seen_ids,
    do: Keyword.get(Smalt.Config.event_grid(), :max_seen_ids, @default_max_seen_ids)

  # Remembers a fresh event id under the per-topic dedup cap. Insertion-
  # ordered FIFO: when the cap is exceeded the OLDEST id is evicted from both
  # the membership set and the order queue, each eviction observed via
  # `[:smalt, :event_grid, :dedup_evicted]`. A re-publish of an evicted id is
  # admitted again as :fresh (bounded dedup window, not infinite memory).
  defp remember_id(%{seen_ids: ids, seen_order: order} = t, id) do
    order = :queue.in(id, order)
    {order, evicted} = prune_order(order, max_seen_ids())
    ids = Enum.reduce(evicted, MapSet.put(ids, id), &MapSet.delete(&2, &1))

    Enum.each(evicted, fn eid ->
      :telemetry.execute(
        [:smalt, :event_grid, :dedup_evicted],
        %{count: 1},
        %{id: eid}
      )
    end)

    %{t | seen_ids: ids, seen_order: order}
  end

  defp prune_order(order, cap, dropped \\ []) do
    if :queue.len(order) > cap do
      case :queue.out(order) do
        {{:value, eid}, rest} -> prune_order(rest, cap, [eid | dropped])
        {:empty, _} -> {order, dropped}
      end
    else
      {order, dropped}
    end
  end

  defp prune_queue(q, cap, dropped \\ []) do
    if :queue.len(q) > cap do
      case :queue.out(q) do
        {{:value, entry}, rest} -> prune_queue(rest, cap, [entry | dropped])
        {:empty, _} -> {q, dropped}
      end
    else
      {q, dropped}
    end
  end

  defp sub_status(nil), do: {0, nil, false}
  defp sub_status(sub), do: {:queue.len(sub.queue), sub.inflight, sub.alive?}

  defp enqueue(t, topic, name, id, event) do
    case t.subscribers[name] do
      # Queue for DOWN subscriptions too: the event must be there when the
      # subscriber recovers (never loss).
      %{queue: q, queued: queued} = sub ->
        # Advanced-filter gate (w6af): a subscription with advancedFilters
        # receives only matching events — non-matching events are never
        # queued for it. Other subscribers are unaffected; the event stays
        # fresh on the topic (dedup key is global per topic).
        if filter_rejects?(sub, event) do
          t
        else
          # Wall-clock stamp: becomes the envelope `time`/`eventTime`, stable
          # across every redelivery of the same event id.
          entry = {id, event, System.system_time(:millisecond), 0}

          if MapSet.member?(queued, id) do
            t
          else
            # Capacity bound (SCVD-T8): prune the queue to :max_queue_len by
            # dropping the OLDEST queued entries (drop-oldest policy), each
            # drop observed via typed telemetry. At-least-once holds within
            # the capacity window.
            {q2, dropped} =
              prune_queue(:queue.join(q, :queue.from_list([entry])), max_queue_len())

            queued2 =
              Enum.reduce(dropped, MapSet.put(queued, id), fn {did, _, _, _}, acc ->
                MapSet.delete(acc, did)
              end)

            Enum.each(dropped, fn {did, _ev, _ts, _attempts} ->
              :telemetry.execute(
                [:smalt, :event_grid, :queue_overflow_dropped],
                %{count: 1},
                %{topic: topic, subscriber: name, id: did}
              )
            end)

            put_in(t.subscribers[name], %{
              sub
              | queue: q2,
                queued: queued2
            })
          end
        end

      _ ->
        t
    end
  end

  # True when the subscription's advancedFilters exist and the event does not
  # match. Evaluation input is the normalized envelope attributes (data,
  # subject, type, id) — the ARM advanced-filter lookup surface.
  defp filter_rejects?(%{filters: nil}, _event), do: false

  defp filter_rejects?(%{filters: filters}, event) do
    data = fetch_any(event, [:data, "data"]) || event_without_envelope_keys(event)

    filter_input = %{
      "data" => data,
      "subject" => fetch_any(event, [:subject, "subject"]),
      "eventType" => fetch_any(event, [:type, "type"]),
      "id" => fetch_any(event, [:id, "id"]),
      "dataVersion" => fetch_any(event, [:dataVersion, "dataVersion"])
    }

    not EgAdvancedFilters.matches?(filters, filter_input)
  end

  # Delivery attempt: pops the head, sends to the live subscriber, marks
  # inflight. Called when (a) an event is published/queued, (b) an ack frees
  # the pipe, (c) a subscriber recovers (re-subscribe / redeliver timer).
  defp dispatch(t, topic) do
    Enum.reduce(Map.keys(t.subscribers), t, fn name, t ->
      # Event-TTL law (w6be): expired queued events are dropped before the
      # delivery attempt — never delivered, typed telemetry per drop.
      t = drop_expired(t, topic, name)
      sub = t.subscribers[name]

      case sub do
        %{alive?: true, inflight: nil} ->
          case :queue.out(sub.queue) do
            {{:value, {id, event, ts, prior_attempts}}, rest} ->
              sys = delivery_sys_props(name, prior_attempts + 1)

              send(
                sub.pid,
                {:event_grid, topic, name, id, envelope(event, id, topic, ts, sub.schema), sys}
              )

              put_in(t.subscribers[name], %{
                sub
                | queue: rest,
                  inflight: {id, event, ts, prior_attempts + 1}
              })

            {:empty, _} ->
              t
          end

        _ ->
          t
      end
    end)
  end

  # Retry timer for a DOWN subscriber is armed at recovery detection; the
  # resubscribe path delivers immediately without waiting on the timer.
  defp arm_retry(t, topic, name, sub) do
    if sub.backoff_ref do
      t
    else
      backoff = dlq_config().retry_backoff_ms
      ref = Process.send_after(self(), {:redeliver, topic, name}, backoff)
      put_in(t.subscribers[name], %{sub | backoff_ref: ref})
    end
  end

  defp mark_down(state, ref, reason) do
    Enum.reduce(state.topics, state, fn {topic, t}, state ->
      t =
        Enum.reduce(t.subscribers, t, fn {name, sub}, t ->
          if sub[:monitor] == ref do
            sub = %{sub | alive?: false, monitor: nil, last_error: inspect(reason)}
            # deliverable-while-down guard: nothing is sent to a dead pid; the
            # retry timer only re-dispatches after recovery.
            arm_retry(put_topic_state(t, name, sub), topic, name, sub)
          else
            t
          end
        end)

      put_topic(state, topic, t)
    end)
  end

  defp put_topic_state(t, name, sub), do: put_in(t.subscribers[name], sub)

  # -- DLQ spillover (G3, opt-in) -------------------------------------------------

  defp dlq_config do
    cfg = Smalt.Config.event_grid()[:dlq] || []

    %{
      enabled: Keyword.get(cfg, :enabled, false),
      account: Keyword.get(cfg, :account, "eg-dlq"),
      container: Keyword.get(cfg, :container, "eg-dlq"),
      max_delivery_attempts:
        Keyword.get(cfg, :max_delivery_attempts, @default_max_delivery_attempts),
      retry_backoff_ms: Keyword.get(cfg, :retry_backoff_ms, @redeliver_backoff_ms)
    }
  end

  # Spills the exhausted inflight event to the blob DLQ. Returns
  # `{sub, :spilled}` on a successful write (event removed from
  # inflight/queued; typed `{:dead_lettered, ...}` face + telemetry) or
  # `{sub, :retained}` on a failed write — the event STAYS inflight
  # (never loss) and the timer re-arms it for another attempt.
  # Container-safe subscriber encoding (Azure container grammar: 3-63 bytes,
  # lowercase letters, digits, dashes). The raw subscriber name is preserved
  # verbatim in the `subscriber` metadata.
  defp dlq_container_name(base, name) do
    raw =
      name
      |> to_string_name()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")

    base_container = "#{base}-#{raw}"

    if byte_size(base_container) > 63 do
      binary_part(base_container, 0, 63)
    else
      base_container
    end
  end

  defp spill_to_dlq(topic, name, sub, id, ev, attempts) do
    cfg = dlq_config()
    container = dlq_container_name(cfg.container, name)
    seq = sub[:dlq_seq] || 0
    blob_name = "#{seq}-#{id}.json"

    case write_dlq_blob(cfg, container, blob_name, name, id, ev, attempts, sub[:last_error]) do
      {:ok, {:dead_lettered, _blob_key}} ->
        :telemetry.execute(
          [:smalt, :event_grid, :dead_lettered],
          %{attempts: attempts},
          %{
            topic: topic,
            subscriber: name,
            id: id,
            account: cfg.account,
            container: container,
            blob: blob_name,
            reason: :max_delivery_attempts_exceeded
          }
        )

        {%{
           sub
           | inflight: nil,
             queued: MapSet.delete(sub.queued, id),
             dlq_seq: seq + 1
         }, :spilled}

      {:error, _kind} = failure ->
        report_dlq_write_failure(topic, name, id, blob_name, failure)
        {sub, :retained}

      {:error, _kind, _code, _msg} = failure ->
        report_dlq_write_failure(topic, name, id, blob_name, failure)
        {sub, :retained}

      # put_blob 3-tuples ({:error, :worm_locked | :precondition_failed |
      # :too_large, msg}, blob_storage.ex): the DLQ spill target refused the
      # write. Same DLQ law as the 2/4-tuple arms — log the typed reason,
      # keep the event inflight (never loss), timer re-arms it.
      {:error, _kind, _msg} = failure ->
        report_dlq_write_failure(topic, name, id, blob_name, failure)
        {sub, :retained}
    end
  end

  # Advances one DLQ budget step for a DOWN subscriber: spill exhausted
  # inflight, else count the failed attempt and re-arm, else pull the next
  # queued event into a fresh budget (1st attempt).
  defp dlq_step(topic, name, sub, dlq) do
    # Per-subscription retryPolicy override (w6be): a subscription that set
    # :retry_policy caps ITS budget at its own max_delivery_attempts; unset
    # subscriptions keep the broker-wide DLQ default.
    max = sub[:max_delivery_attempts] || dlq.max_delivery_attempts

    case sub do
      %{inflight: {id, ev, ts, attempts}} when attempts >= max ->
        {sub, spilled} = spill_to_dlq(topic, name, sub, id, ev, attempts)
        sub = %{sub | backoff_ref: nil}

        # Retained (DLQ write failed): re-arm the timer for the retained event
        # instead of recursing; spilled: advance to the next queued event.
        case spilled do
          :spilled ->
            dlq_step(topic, name, sub, dlq)

          :retained ->
            %{
              sub
              | inflight: {id, ev, ts, attempts},
                backoff_ref:
                  Process.send_after(self(), {:redeliver, topic, name}, dlq.retry_backoff_ms)
            }
        end

      %{inflight: {id, ev, ts, attempts}} ->
        ref = Process.send_after(self(), {:redeliver, topic, name}, dlq.retry_backoff_ms)
        %{sub | inflight: {id, ev, ts, attempts + 1}, backoff_ref: ref}

      %{inflight: nil} ->
        case :queue.out(sub.queue) do
          {{:value, {id, ev, ts, prior}}, rest} ->
            ref = Process.send_after(self(), {:redeliver, topic, name}, dlq.retry_backoff_ms)

            %{
              sub
              | queue: rest,
                inflight: {id, ev, ts, prior + 1},
                queued: MapSet.delete(sub.queued, id),
                backoff_ref: ref
            }

          {:empty, _} ->
            %{sub | backoff_ref: nil}
        end
    end
  end

  defp write_dlq_blob(cfg, container, blob_name, name, id, ev, attempts, last_error) do
    with :ok <- ensure_dlq_container(cfg.account, container) do
      body = Jason.encode!(%{"event" => ev, "dead_lettered_at" => DateTime.utc_now()})

      meta = %{
        "x-ms-meta-DeadLetterReason" => "MaxDeliveryAttemptsExceeded",
        "x-ms-meta-subscriber" => to_string_name(name),
        "x-ms-meta-attempts" => Integer.to_string(attempts),
        "x-ms-meta-last_error" => dlq_meta_value(last_error),
        "x-ms-meta-event_id" => to_string_name(id)
      }

      case BlobStorage.put_blob(cfg.account, container, blob_name, body, meta) do
        {:ok, _blob} ->
          {:ok, {:dead_lettered, "#{cfg.account}/#{container}/#{blob_name}"}}

        {:error, _kind, _code, _msg} = err ->
          err

        # put_blob 3-tuple errors (worm-locked DLQ container, precondition
        # failure, 1 MiB cap): pass through typed — spill_to_dlq retains.
        {:error, _kind, _msg} = err ->
          err

        {:error, _kind} = err ->
          err
      end
    end
  end

  defp ensure_dlq_container(account, container) do
    case Store.get(:smalt_blob_containers, "#{account}/#{container}") do
      {:ok, _} ->
        :ok

      :error ->
        case BlobStorage.create_container(account, container) do
          {:ok, _record} -> :ok
          # Raced creation: the container existing is success for our purpose.
          {:error, 409, "ContainerAlreadyExists", _msg} -> :ok
          {:error, _status, _code, _msg} = err -> err
        end
    end
  end

  defp to_string_name(name) when is_binary(name), do: name
  defp to_string_name(name), do: inspect(name)

  # Metadata values must be control-character-free binaries (Azure parity).
  defp dlq_meta_value(nil), do: "unknown"
  defp dlq_meta_value(v) when is_binary(v), do: String.replace(v, ~r/[\x00-\x1F\x7F]/, " ")
  defp dlq_meta_value(v), do: dlq_meta_value(inspect(v))

  defp report_dlq_write_failure(topic, name, id, blob_name, failure) do
    Logger.error(
      "event_grid DLQ write failed (event retained): topic=#{inspect(topic)} " <>
        "subscriber=#{inspect(name)} id=#{inspect(id)} blob=#{blob_name} " <>
        "failure=#{inspect(failure)}"
    )
  end

  # -- Push-contract fidelity (KD-101 in-proc face) --------------------------------

  @schema_values [:cloud_event_schema, :event_grid_schema]
  @default_schema :cloud_event_schema

  defp validate_schema!(nil), do: @default_schema

  defp validate_schema!(schema) when schema in @schema_values, do: schema

  defp validate_schema!(schema),
    do:
      raise(ArgumentError,
        message:
          "EventGrid.subscribe/4 unsupported :schema #{inspect(schema)} " <>
            "(only :cloud_event_schema | :event_grid_schema — the subscription's " <>
            "eventDeliverySchema)"
      )

  # Event Grid system properties carried on EVERY delivery attempt (the
  # in-proc analogue of the aeg-* delivery headers the webhook receiver face
  # records): the delivery count continues across redeliveries (first
  # attempt = 1), the subscription name is verbatim.
  defp delivery_sys_props(name, attempts) do
    %{
      "aeg-delivery-count" => attempts,
      "aeg-subscription-name" => to_string_name(name),
      "aeg-event-type" => "Notification",
      "aeg-data-version" => "1.0"
    }
  end

  # Shapes the delivered envelope per the subscription's eventDeliverySchema.
  # `ts` is the publish-time wall-clock stamp (stable across redeliveries).
  # Publisher-supplied envelope fields (string or atom keys) win; missing
  # CloudEvents mandatory attributes are synthesized (source anchored at the
  # smalt topic, type defaulted) so every delivery exposes a complete
  # envelope (data + time + subject), not just the body.
  defp envelope(event, id, topic, ts, schema) do
    time = ts |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    data = fetch_any(event, [:data, "data"]) || event_without_envelope_keys(event)
    subject = fetch_any(event, [:subject, "subject"])
    type = fetch_any(event, [:type, "type"])

    case schema do
      :cloud_event_schema ->
        %{
          "specversion" => fetch_any(event, [:specversion, "specversion"]) || "1.0",
          "id" => to_string_name(id),
          "source" =>
            fetch_any(event, [:source, "source"]) || "/smalt/eventgrid/" <> to_string_name(topic),
          "type" => type || "smalt.eventgrid.message",
          "time" => time,
          "subject" => subject,
          "data" => data
        }

      :event_grid_schema ->
        %{
          "id" => to_string_name(id),
          "topic" => to_string_name(topic),
          "subject" => subject,
          "eventTime" => time,
          "eventType" => type || "smalt.eventgrid.message",
          "data" => data,
          "dataVersion" => fetch_any(event, [:dataVersion, "dataVersion"]) || "1.0"
        }
    end
  end

  # The body is the publisher's `data` payload when supplied; otherwise the
  # published event minus the envelope attributes (the CloudEvents 1.0
  # extension-attribute allowance — everything else rides as data).
  @envelope_keys [
    :id,
    "id",
    :specversion,
    "specversion",
    :source,
    "source",
    :type,
    "type",
    :time,
    "time",
    :subject,
    "subject",
    :data,
    "data",
    :dataVersion,
    "dataVersion"
  ]

  defp event_without_envelope_keys(event), do: Map.drop(event, @envelope_keys)

  defp fetch_any(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  # AZB-07 :event_grid profile read site (one-source via Smalt.Config.event_grid/0).
  defp delivery_mode do
    case Smalt.Config.event_grid()[:delivery_mode] do
      nil -> :at_least_once
      mode -> mode
    end
  end

  defp validate_delivery_mode! do
    unless delivery_mode() == :at_least_once do
      raise ArgumentError,
            "Smalt.Messaging.EventGrid: unsupported delivery_mode " <>
              "#{inspect(delivery_mode())} (only :at_least_once; a lossy mode is " <>
              "deliberately not implemented)"
    end
  end
end

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

  Lazy-started (QueueStore pattern): no application.ex child (AZB-09 owns the
  child-list partition; `:plane` unset = today's child list).
  """

  use GenServer

  @name __MODULE__
  @redeliver_backoff_ms 50

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
    GenServer.call(server(), {:publish, topic, event, id})
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
  """
  @spec subscribe(String.t() | atom(), term(), pid() | nil) :: :ok
  def subscribe(topic, name, pid \\ nil) do
    pid = pid || self()
    GenServer.call(server(), {:subscribe, topic, name, pid})
  end

  @doc "Acknowledges delivery of `id` by subscriber `name` on `topic`."
  @spec ack(String.t() | atom(), term(), term()) :: :ok
  def ack(topic, name, id) do
    GenServer.call(server(), {:ack, topic, name, id})
  end

  @doc "Returns `{pending_count, inflight, alive?}` for subscriber `name` on `topic`."
  @spec status(String.t() | atom(), term()) ::
          {non_neg_integer(), nil | {term(), pos_integer()}, boolean()}
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
      t = %{t | seen_ids: MapSet.put(t.seen_ids, id)}
      t = Enum.reduce(Map.keys(t.subscribers), t, &enqueue(&2, &1, id, event))
      {:reply, :fresh, put_topic(state, topic, dispatch(t, topic))}
    end
  end

  def handle_call({:subscribe, topic, name, pid}, _from, state) do
    t = topic_state(state, topic)
    prev = t.subscribers[name]

    sub =
      if is_nil(prev) do
        new_sub(pid)
      else
        # Recovery path: same subscription name, new pid. Keep the queue and
        # the seen_ids; replace the pid + monitor, then redeliver.
        if prev[:monitor], do: Process.demonitor(prev.monitor, [:flush])
        prev |> Map.put(:pid, pid) |> Map.put(:monitor, Process.monitor(pid))
      end

    t = %{t | subscribers: Map.put(t.subscribers, name, sub)}
    {:reply, :ok, put_topic(state, topic, dispatch(t, topic))}
  end

  def handle_call({:ack, topic, name, id}, _from, state) do
    t = topic_state(state, topic)

    t =
      case t.subscribers[name] do
        %{inflight: {^id, _attempts}} = sub ->
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
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Subscriber crash: keep the subscription (queue + inflight preserved) so
    # the recovered subscriber is redelivered. Never loss.
    {:noreply, mark_down(state, ref)}
  end

  def handle_info({:redeliver, topic, name}, state) do
    t = topic_state(state, topic)

    t =
      case t.subscribers[name] do
        %{alive?: false} = sub ->
          put_in(t.subscribers[name], %{sub | backoff_ref: nil})
          |> dispatch(topic)

        _ ->
          t
      end

    {:noreply, put_topic(state, topic, t)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals ----------------------------------------------------------------

  defp new_sub(pid),
    do: %{
      pid: pid,
      monitor: Process.monitor(pid),
      alive?: true,
      queue: :queue.new(),
      queued: MapSet.new(),
      inflight: nil,
      backoff_ref: nil
    }

  defp topic_state(state, topic) do
    Map.get(state.topics, topic) ||
      %{seen_ids: MapSet.new(), subscribers: %{}}
  end

  defp put_topic(state, topic, t), do: %{state | topics: Map.put(state.topics, topic, t)}

  defp sub_status(nil), do: {0, nil, false}
  defp sub_status(sub), do: {:queue.len(sub.queue), sub.inflight, sub.alive?}

  defp enqueue(t, name, id, event) do
    case t.subscribers[name] do
      # Queue for DOWN subscriptions too: the event must be there when the
      # subscriber recovers (never loss).
      %{queue: q, queued: queued} = sub ->
        entry = {id, event, System.monotonic_time(:millisecond)}

        if MapSet.member?(queued, id) do
          t
        else
          put_in(t.subscribers[name], %{
            sub
            | queue: :queue.join(q, :queue.from_list([entry])),
              queued: MapSet.put(queued, id)
          })
        end

      _ ->
        t
    end
  end

  # Delivery attempt: pops the head, sends to the live subscriber, marks
  # inflight. Called when (a) an event is published/queued, (b) an ack frees
  # the pipe, (c) a subscriber recovers (re-subscribe / redeliver timer).
  defp dispatch(t, topic) do
    Enum.reduce(Map.keys(t.subscribers), t, fn name, t ->
      sub = t.subscribers[name]

      case sub do
        %{alive?: true, inflight: nil} ->
          case :queue.out(sub.queue) do
            {{:value, {id, event, _ts}}, rest} ->
              send(sub.pid, {:event_grid, topic, name, id, event})
              put_in(t.subscribers[name], %{sub | queue: rest, inflight: {id, 1}})

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
      ref = Process.send_after(self(), {:redeliver, topic, name}, @redeliver_backoff_ms)
      put_in(t.subscribers[name], %{sub | backoff_ref: ref})
    end
  end

  defp mark_down(state, ref) do
    Enum.reduce(state.topics, state, fn {topic, t}, state ->
      t =
        Enum.reduce(t.subscribers, t, fn {name, sub}, t ->
          if sub[:monitor] == ref do
            sub = %{sub | alive?: false, monitor: nil}
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
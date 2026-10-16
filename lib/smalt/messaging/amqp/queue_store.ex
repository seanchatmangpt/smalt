defmodule Smalt.Amqp.QueueStore do
  @moduledoc """
  Queue + DLQ model over `Smalt.Store` ETS tables for the AMQP 1.0 broker.

  Tables (owned by `Smalt.Store`):
    - `:smalt_sb_queues`   key = entity name; counter key `{queue, :seq}`
    - `:smalt_sb_messages` key = `{queue, seq}`
    - `:smalt_sb_locks`    key = lock token (see `Smalt.Amqp.LockManager`)
    - `:smalt_sb_sessions` key = `{queue, session_id}`

  Pure-ish: every function that depends on time takes `now_ms` (default
  `System.system_time(:millisecond)`) so tests are deterministic.

  Concurrency model: state transitions that claim or settle a message
  (dequeue claim, complete, defer, release, deadletter, lock/session sweeps,
  session acquire) are serialized through this module's own named GenServer so
  the scan→lock→mark pipeline is atomic under any number of concurrent
  callers. Readers (peek, messages) are lock-free `:ets.match_object` scans
  (churn-safe: no get-after-match). The server is started lazily on first
  use, so tests and drivers that never boot the full supervision tree still
  work.
  """

  use GenServer

  @capacity 4096
  @max_body 1 * 1024 * 1024
  @max_peek 100

  # -- Queue lifecycle ---------------------------------------------------------

  @spec ensure_queue(String.t()) :: {:ok, map()} | {:error, :capacity}
  def ensure_queue(name) when is_binary(name) do
    case Smalt.Store.get(:smalt_sb_queues, name) do
      {:ok, info} ->
        {:ok, info}

      :error ->
        info = %{name: name, capacity: @capacity, created: System.system_time(:millisecond)}
        Smalt.Store.put(:smalt_sb_queues, name, info)
        {:ok, info}
    end
  end

  @spec queue_info(String.t()) :: {:ok, map()} | :error
  def queue_info(name), do: Smalt.Store.get(:smalt_sb_queues, name)

  # -- Queue settings (ARM-created properties) ----------------------------------

  @default_max_delivery_count 10

  @doc """
  Effective queue settings for `queue`, read from the ARM resource record when
  one exists (`:smalt_resources` key = downcased full ARM id
  `.../namespaces/<ns>/queues/<name>`, written by the ARM gateway when the
  Service Bus queue child is PUT), else defaults:

    - `requires_session: false`
    - `lock_duration_ms: 30000` (clamped to 100..30000 via LockManager)
    - `max_delivery_count: 10`
  """
  @spec queue_settings(String.t()) :: %{
          required(:requires_session) => boolean(),
          required(:lock_duration_ms) => pos_integer(),
          required(:max_delivery_count) => pos_integer()
        }
  def queue_settings(queue) when is_binary(queue) do
    props = arm_queue_properties(queue)

    %{
      requires_session: truthy(props["requiresSession"]),
      lock_duration_ms:
        Smalt.Amqp.LockManager.clamp_duration(parse_iso8601_duration(props["lockDuration"])),
      max_delivery_count: positive_int(props["maxDeliveryCount"]) || @default_max_delivery_count
    }
  end

  defp arm_queue_properties(queue) do
    suffix = "/queues/#{String.downcase(queue)}"

    case :ets.match(:smalt_resources, {:"$1", :"$2"}) do
      [] ->
        %{}

      matches ->
        case Enum.find(matches, fn [key, _record] -> is_binary(key) and String.ends_with?(key, suffix) end) do
          [_key, record] when is_map(record) ->
            case record do
              %{"properties" => props} when is_map(props) -> props
              _ -> %{}
            end

          _ ->
            %{}
        end
    end
  end

  defp truthy(v), do: v == true or v == "true"

  defp positive_int(v) when is_integer(v) and v > 0, do: v
  defp positive_int(_), do: nil

  @doc """
  Parse a subset of ISO8601 durations used by Service Bus lock durations
  ("PT30S", "PT1M30S", "PT2H"). Days are accepted as "P1D"-style prefixes.
  Returns milliseconds, or `nil` when the string is not a valid duration
  (callers apply their default).
  """
  @spec parse_iso8601_duration(term()) :: non_neg_integer() | nil
  def parse_iso8601_duration(d) when is_binary(d) do
    with "P" <> rest <- d,
         {designator, time_part} <- split_date_time(rest),
         {:ok, ms} <- sum_components(designator, time_part) do
      ms
    else
      _ -> nil
    end
  end

  def parse_iso8601_duration(_), do: nil

  defp split_date_time(rest) do
    case String.split(rest, "T", parts: 2) do
      [date, time] -> {date, time}
      [date] -> {date, nil}
    end
  end

  @unit_ms %{"W" => 604_800_000, "D" => 86_400_000, "H" => 3_600_000, "M" => 60_000, "S" => 1_000}

  defp sum_components(designator, nil) do
    # date-only part: Y and M (months) are ambiguous for lock durations; accept
    # only W/D there.
    sum_components(designator, "")
  end

  defp sum_components(designator, time_part) do
    # In the time part "M" means minutes; in the date part it means months
    # (rejected). W/D are only valid in the date part; H/S only in time.
    date_units = if time_part == "", do: ~w(W D H M S), else: ~w(W D)

    if designator == "" and time_part == "" do
      :error
    else
      with {:ok, date_ms} <- sum_section(designator, date_units),
           {:ok, time_ms} <- sum_section(time_part, ~w(H M S)) do
        {:ok, date_ms + time_ms}
      end
    end
  end

  defp sum_section("", _units), do: {:ok, 0}

  defp sum_section(section, units) do
    parts = Regex.scan(~r/(\d+)([A-Z])/, section)

    # every non-empty char of the section must be consumed by a component:
    # a stray token (e.g. "PT1X") leaves a residue and is rejected.
    consumed =
      Enum.map(parts, fn [all, _n, _u] -> all end)
      |> Enum.join()

    if consumed == section do
      Enum.reduce_while(parts, {:ok, 0}, fn [_all, n, unit], {:ok, acc} ->
        {n, _} = Integer.parse(n)

        # runtime check: `unit in units` cannot sit in a guard with a runtime list
        if unit in units and Map.has_key?(@unit_ms, unit) do
          {:cont, {:ok, acc + n * @unit_ms[unit]}}
        else
          {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  # -- Enqueue -----------------------------------------------------------------

  @doc """
  Enqueue `body` on `queue`. Opts: `:session_id` (binary), `:annotations` (map),
  `:now_ms`.

  Returns `{:ok, seq}` or `{:error, :capacity}` (queue at #{@capacity} messages),
  `{:error, :too_large}` (body > #{@max_body} bytes) or
  `{:error, :session_required}` (queue requires sessions per its ARM settings
  and no `:session_id` was given).
  """
  @spec enqueue(String.t(), binary() | {atom(), binary()}, keyword()) ::
          {:ok, integer()} | {:error, :capacity | :too_large | :session_required}
  # body may be a plain binary (EventHubs/legacy callers) or a tagged AMQP
  # body section {:body_data | :body_amqp_value, value} stored as-is so the
  # delivery path can re-emit the section kind the client sent (as-sent body
  # preservation; disclosed cross-lane unblock from the connection lane).
  def enqueue(queue, body, opts \\ []) when is_binary(body) or (is_tuple(body) and tuple_size(body) == 2) do
    {:ok, _} = ensure_queue(queue)

    settings = queue_settings(queue)

    cond do
      settings.requires_session and is_nil(opts[:session_id]) ->
        {:error, :session_required}

      body_size(body) > @max_body ->
        {:error, :too_large}

      capacity_full?(queue) ->
        {:error, :capacity}

      true ->
        do_enqueue(queue, body, opts)
    end
  end

  defp body_size(binary) when is_binary(binary), do: byte_size(binary)

  defp body_size({_kind, value}) do
    if is_binary(value), do: byte_size(value), else: byte_size(:erlang.term_to_binary(value))
  end

  defp capacity_full?(queue) do
    message_count(queue) >= @capacity
  end

  defp message_count(queue) do
    :ets.select_count(:smalt_sb_messages, [{{{queue, :_}, :_}, [], [true]}])
  end

  defp do_enqueue(queue, body, opts) do
    seq = Smalt.Store.update_counter(:smalt_sb_queues, {queue, :seq}, 1)

    msg = %{
      queue: queue,
      seq: seq,
      body: body,
      message_id: opts[:message_id],
      app_props: opts[:app_props] || %{},
      session_id: opts[:session_id],
      annotations: opts[:annotations] || %{},
      delivery_count: 0,
      enqueued: opts[:now_ms] || System.system_time(:millisecond),
      state: :available,
      lock_token: nil,
      locked_until: nil
    }

    Smalt.Store.put(:smalt_sb_messages, {queue, seq}, msg)
    {:ok, seq}
  end

  # -- Dequeue -----------------------------------------------------------------

  @doc """
  Deliver the next matching available message, acquiring a lock on it.

  Opts: `:now_ms`, `:session_id` (session filter — only messages with a matching
  `session_id` match), `:lock_duration_ms`.

  Skips: locked-until > now, `:deferred`, `:dead`. Increments `delivery_count`
  on every delivery (redelivery included).

  Returns `{:ok, msg, lock}` or `:empty`.
  """
  @spec dequeue_matching(String.t(), keyword()) ::
          {:ok, map(), map()} | :empty
  def dequeue_matching(queue, opts \\ []) do
    now = opts[:now_ms] || System.system_time(:millisecond)
    filter_session = opts[:session_id]
    lock_duration = opts[:lock_duration_ms] || queue_settings(queue).lock_duration_ms

    GenServer.call(server(), {:claim, queue, filter_session, now, lock_duration})
  end

  # -- Peek --------------------------------------------------------------------

  @doc """
  Peek messages without changing state. Opts: `:from_sequence_number` (default 1,
  inclusive), `:message_count` clamped to 1..#{@max_peek}, `:now` (unused, kept
  for symmetry with the `$management` peek-message contract).

  Returns `{:ok, messages}` per the `Smalt.Amqp.ManagementRpc` pinned contract
  (empty list surfaces as 204 there).
  """
  @spec peek(String.t(), keyword()) :: {:ok, [map()]}
  def peek(queue, opts \\ []) do
    from = opts[:from_sequence_number] || 1
    count = peek_count(opts[:message_count] || @max_peek)

    messages =
      queue
      |> messages()
      |> Enum.filter(&(&1.seq >= from))
      |> Enum.sort_by(& &1.seq)
      |> Enum.take(count)

    {:ok, messages}
  end

  defp peek_count(n) when is_integer(n), do: n |> max(1) |> min(@max_peek)
  defp peek_count(_), do: 1

  # -- Settlement transitions --------------------------------------------------

  @doc "Complete: delete the message and its lock (serialized)."
  @spec complete(String.t(), integer()) :: :ok
  def complete(queue, seq), do: GenServer.call(server(), {:complete, queue, seq})

  @doc "Defer: keep the message, resurfaceable only by receive-by-sequence (serialized)."
  @spec defer(String.t(), integer(), keyword()) :: :ok | :error
  def defer(queue, seq, _opts \\ []), do: GenServer.call(server(), {:defer, queue, seq})

  @doc """
  Reclaim expired message locks: any message still `:locked` whose
  `locked_until <= now` is released back to `:available` and its lock token
  deleted. Serialized with claims/settlements. Returns the number reclaimed.
  """
  @spec sweep() :: non_neg_integer()
  def sweep, do: GenServer.call(server(), :sweep)

  @doc """
  Abandon/release: lock expiry or explicit abandon returns the message to
  `:available`, lock cleared, delivery_count preserved.

  When the message has already been delivered `max_delivery_count` times (the
  queue's ARM setting, default 10), the abandon deadletters it instead of
  releasing it back to `:available` — reason `MaxDeliveryCountExceeded`.
  """
  @spec release(String.t(), integer(), keyword()) :: :ok | :error
  def release(queue, seq, opts \\ []) do
    GenServer.call(server(), {:release, queue, seq, opts})
  end

  @doc """
  Receive deferred messages by sequence number (Service Bus
  `com.microsoft:receive-by-sequence-number`). Only messages currently in
  `:deferred` state qualify; every requested sequence number must qualify or
  the batch fails atomically with `{:error, {:not_deferred, missing}}` (no
  partial lock — the caller surfaces 410 MESSAGE_NOT_DEFERRED for the whole
  batch). Qualifying messages re-enter the normal lock path: a fresh
  LockManager lock is acquired at the queue's configured lock duration, so
  complete/abandon/renew behave identically to a live delivery. Delivery
  count is incremented (deferred receive is a delivery).

  Returns `{:ok, [msg]}` in the order of the request.
  """
  @spec receive_deferred(String.t(), [integer()], keyword()) ::
          {:ok, [map()]} | {:error, {:not_deferred, [integer()]}}
  def receive_deferred(queue, sequence_numbers, opts \\ []) when is_list(sequence_numbers) do
    now = opts[:now_ms] || System.system_time(:millisecond)
    GenServer.call(server(), {:receive_deferred, queue, sequence_numbers, now})
  end

  @doc """
  Deadletter: move to `{queue}/$deadletterqueue` with a fresh per-DLQ sequence,
  preserving body/annotations/session and stamping `DeadLetterReason` /
  `DeadLetterErrorDescription` properties. Opts: `:properties` — custom
  dead-letter properties map (update-disposition `dead-letter-properties`)
  merged into the DLQ message's application properties. Returns
  `{:ok, dlq_seq}` or `:error`.
  """
  @spec deadletter(String.t(), integer(), String.t(), String.t() | nil, keyword()) ::
          {:ok, integer()} | :error
  def deadletter(queue, seq, reason, description \\ nil, opts \\ []) do
    GenServer.call(server(), {:deadletter, queue, seq, reason, description, opts})
  end

  @doc "Deadletter entity name for a queue."
  @spec deadletter_queue(String.t()) :: String.t()
  def deadletter_queue(queue), do: queue <> "/$deadletterqueue"

  # -- Internals ---------------------------------------------------------------

  defp messages(queue) do
    # Keys are {queue, seq} tuples. Store.keys/list_prefix cannot be used here:
    # prefix_keys/2 starts from :ets.prev(table, "") which raises badarg on an
    # empty table, and its bitstring upper bound never bounds tuple keys.
    # match_object fetches key+value atomically, so a concurrent complete/2 can
    # no longer raise MatchError on a get-after-match (the ST4 read race).
    :ets.match_object(:smalt_sb_messages, {{queue, :_}, :_})
    |> Enum.map(fn {_key, val} -> val end)
  end

  # -- GenServer (serialized claim/settle) --------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @doc "Start the serialized claim/settle server (idempotent, lazily used)."
  def start_link(opts \\ []) do
    _ = opts
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc false
  def server do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case start_link() do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:claim, queue, filter_session, now, lock_duration}, _from, state) do
    reply =
      queue
      |> claim_candidates(now, filter_session)
      |> claim_next(queue, now, lock_duration)

    {:reply, reply, state}
  end

  def handle_call({:complete, queue, seq}, _from, state) do
    {:reply, do_complete(queue, seq), state}
  end

  def handle_call({:defer, queue, seq}, _from, state) do
    {:reply, do_defer(queue, seq), state}
  end

  def handle_call({:release, queue, seq, opts}, _from, state) do
    {:reply, do_release(queue, seq, opts), state}
  end

  def handle_call({:receive_deferred, queue, sequence_numbers, now}, _from, state) do
    {:reply, do_receive_deferred(queue, sequence_numbers, now), state}
  end

  def handle_call({:deadletter, queue, seq, reason, description, opts}, _from, state) do
    {:reply, do_deadletter(queue, seq, reason, description, opts), state}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, do_sweep(), state}
  end

  def handle_call({:session_claim, queue, session_id, now, opts}, _from, state) do
    # LockManager.session_acquire/3 serializes its TOCTOU-prone
    # get-check-put through here: exactly one racer can observe the
    # absent-or-expired window and win.
    {:reply, Smalt.Amqp.LockManager.do_session_claim(queue, session_id, now, opts), state}
  end

  def handle_call({:session_release, queue, session_id}, _from, state) do
    # LockManager.session_release/2 serializes its get+delete pair through the
    # same server as session_claim (V261014-04 F3): a concurrent acquire can
    # never interleave between the get and the deletes, closing the ST4
    # release-vs-claim lost-lock window.
    {:reply, Smalt.Amqp.LockManager.do_session_release(queue, session_id), state}
  end

  def handle_call({:lock_sweep, now}, _from, state) do
    # LockManager.sweep/0 GC of expired lock/session records, serialized with
    # claims so a lock deleted here can never belong to an in-flight claim.
    {:reply, Smalt.Amqp.LockManager.do_sweep_expired(now), state}
  end

  # -- claim (runs inside the server) -------------------------------------------

  defp claim_candidates(queue, now, filter_session) do
    queue
    |> messages()
    |> Enum.sort_by(& &1.seq)
    |> Enum.reject(fn m -> m.state == :deferred or m.state == :dead end)
    |> Enum.reject(fn m -> locked_now?(m, now) end)
    |> Enum.reject(fn m ->
      filter_session != nil and m.session_id != filter_session
    end)
  end

  defp claim_next([], _queue, _now, _lock_duration), do: :empty

  defp claim_next([m | _], queue, now, lock_duration) do
    case Smalt.Amqp.LockManager.acquire(queue, m.seq,
           now_ms: now,
           duration_ms: lock_duration
         ) do
      {:ok, lock} ->
        msg =
          m
          |> Map.update!(:delivery_count, &(&1 + 1))
          |> Map.merge(%{state: :locked, lock_token: lock.lock_token, locked_until: lock.locked_until})

        Smalt.Store.put(:smalt_sb_messages, {queue, m.seq}, msg)
        {:ok, msg, lock}
    end
  end

  defp locked_now?(%{state: :locked, locked_until: until}, now) when is_integer(until), do: until > now
  defp locked_now?(_, _), do: false

  # -- settlement internals (run inside the server) -----------------------------

  defp do_complete(queue, seq) do
    case Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      {:ok, m} ->
        if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)
        Smalt.Store.delete(:smalt_sb_messages, {queue, seq})

      :error ->
        :ok
    end
  end

  defp do_defer(queue, seq) do
    with {:ok, m} <- Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)
      Smalt.Store.put(:smalt_sb_messages, {queue, seq}, %{m | state: :deferred, lock_token: nil, locked_until: nil})
      :ok
    else
      :error -> :error
    end
  end

  # Receive-by-sequence-number: two-pass so a bad sequence anywhere in the
  # batch fails the whole batch atomically (no partial lock), then each
  # qualifying message re-locks at the queue's configured duration.
  defp do_receive_deferred(queue, sequence_numbers, now) do
    duration = queue_settings(queue).lock_duration_ms

    loaded =
      Enum.map(sequence_numbers, fn seq -> {seq, Smalt.Store.get(:smalt_sb_messages, {queue, seq})} end)

    missing =
      for {seq, {:ok, m}} <- loaded,
          m.state != :deferred,
          do: seq

    missing = missing ++ for {seq, :error} <- loaded, do: seq

    if missing == [] do
      {:ok,
       Enum.map(loaded, fn {_seq, {:ok, m}} ->
         {:ok, lock} = Smalt.Amqp.LockManager.acquire(queue, m.seq, now_ms: now, duration_ms: duration)

         msg =
           m
           |> Map.update!(:delivery_count, &(&1 + 1))
           |> Map.merge(%{state: :locked, lock_token: lock.lock_token, locked_until: lock.locked_until})

         Smalt.Store.put(:smalt_sb_messages, {queue, m.seq}, msg)
         msg
       end)}
    else
      {:error, {:not_deferred, Enum.sort(missing)}}
    end
  end

  defp do_release(queue, seq, opts) do
    with {:ok, m} <- Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      max_delivery = queue_settings(queue).max_delivery_count

      if m.delivery_count >= max_delivery do
        do_deadletter(queue, seq, "MaxDeliveryCountExceeded",
          "delivery_count #{m.delivery_count} >= max_delivery_count #{max_delivery}",
          now_ms: opts[:now_ms]
        )

        :ok
      else
        if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)

        Smalt.Store.put(:smalt_sb_messages, {queue, seq}, %{
          m
          | state: :available,
            lock_token: nil,
            locked_until: nil
        })

        :ok
      end
    else
      :error -> :error
    end
  end

  defp do_deadletter(queue, seq, reason, description, opts) do
    dlq = queue <> "/$deadletterqueue"

    case Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      {:ok, m} ->
        {:ok, dlq_seq} = do_enqueue(dlq, m.body,
          session_id: m.session_id,
          # SDK parity: deadLetterReason/deadLetterErrorDescription are read
          # from the DLQ message's APPLICATION PROPERTIES
          # (serviceBusMessage.js:302), not message annotations. They were
          # previously merged into annotations, so the census dead-letter
          # probe read undefined.
          app_props:
            (m[:app_props] || %{})
            |> Map.merge(%{
              "DeadLetterReason" => reason,
              "DeadLetterErrorDescription" => description
            })
            |> Map.merge(opts[:properties] || %{}),
          annotations:
            m.annotations
            |> Map.merge(%{
              "DeadLetterReason" => reason,
              "DeadLetterErrorDescription" => description
            }),
          now_ms: opts[:now_ms]
        )

        Smalt.Store.delete(:smalt_sb_messages, {queue, seq})
        if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)
        {:ok, dlq_seq}

      :error ->
        :error
    end
  end

  # Expired message-lock reclamation: back to :available, token deleted.
  defp do_sweep do
    now = System.system_time(:millisecond)

    reclaimed =
      :ets.match_object(:smalt_sb_messages, {{:_, :_}, :_})
      |> Enum.flat_map(fn {_k, m} ->
        if m.state == :locked and is_integer(m.locked_until) and m.locked_until <= now do
          [m]
        else
          []
        end
      end)
      |> Enum.reduce(0, fn m, n ->
        Smalt.Amqp.LockManager.release(m.lock_token)

        Smalt.Store.put(:smalt_sb_messages, {m.queue, m.seq}, %{
          m
          | state: :available,
            lock_token: nil,
            locked_until: nil
        })

        n + 1
      end)

    # session locks are LockManager's records; delegate the lock/session table GC
    Smalt.Amqp.LockManager.do_sweep_expired(now)
    reclaimed
  end
end

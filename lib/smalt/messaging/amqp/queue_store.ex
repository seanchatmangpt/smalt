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
  # Layering: the AMQP connection layer clamps outbound bodies to the peer's
  # max_frame_size and chunked-transfers the remainder (more=true), so a body
  # up to the decode cap can arrive here intact. The store cap must sit ABOVE
  # the frame-layer clamp, not at it: a 1.5MB body is legal post-chunking and
  # was being refused before the clamp path ever ran.
  @max_body 4 * 1024 * 1024
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
        case Enum.find(matches, fn [key, _record] ->
               is_binary(key) and String.ends_with?(key, suffix)
             end) do
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
  def enqueue(queue, body, opts \\ [])
      when is_binary(body) or (is_tuple(body) and tuple_size(body) == 2) do
    {:ok, _} = ensure_queue(queue)

    settings = queue_settings(queue)

    cond do
      settings.requires_session and is_nil(opts[:session_id]) ->
        {:error, :session_required}

      body_size(body) > @max_body ->
        {:error, :too_large}

      true ->
        # Capacity gate lives inside the serialized server (see do_enqueue):
        # a client-side check-then-insert raced 32 concurrent enqueues past
        # the 4096 cap (A5 F3 TOCTOU).
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
    # Capacity check + counter bump + insert must be one serialized step.
    # Running it inside the claim/settle server closes the TOCTOU window.
    GenServer.call(server(), {:enqueue, queue, body, opts})
  end

  # Runs inside the server: atomic with respect to every other enqueue.
  defp do_enqueue_locked(queue, body, opts) do
    seq = Smalt.Store.update_counter(:smalt_sb_queues, {queue, :seq}, 1)

    msg = %{
      queue: queue,
      seq: seq,
      body: body,
      message_id: opts[:message_id],
      app_props: opts[:app_props] || %{},
      session_id: opts[:session_id],
      annotations: opts[:annotations] || %{},
      # SB parity: the DLQ copy is the SAME message — its delivery count must
      # survive the move (real Azure keeps counting; a reset count hides how
      # many deliveries preceded deadlettering).
      delivery_count: opts[:delivery_count] || 0,
      enqueued: opts[:now_ms] || System.system_time(:millisecond),
      # SHIM-COURT lane M5: scheduled messages (Service Bus
      # scheduledEnqueueTimeUtc). A message enqueued with a future
      # :scheduled_enqueue_time (epoch ms) starts in :scheduled state and is
      # invisible to receivers until the time arrives; cancel_scheduled/2
      # removes it by sequence number.
      # R142 (W5-9): a non-integer or negative :scheduled_enqueue_time (float/
      # string/DateTime from an unmarshal bug) would store the row as
      # :scheduled while claim_candidates' is_integer guard let it deliver
      # immediately AND leave it un-cancellable after claim. Validate here:
      # only a non-negative integer schedules; anything else falls back to
      # :available immediate delivery (enqueue's {:ok, seq} contract has no
      # bad-timestamp error shape, and graceful degradation beats dropping
      # the body).
      state:
        if(is_integer(opts[:scheduled_enqueue_time]) and opts[:scheduled_enqueue_time] >= 0,
          do: :scheduled,
          else: :available
        ),
      scheduled_enqueue_time: opts[:scheduled_enqueue_time],
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

  @doc """
  Complete: delete the message and its lock (serialized).

  Token-scoped settlement (audit Finding 2, lane R244): when
  `opts[:lock_token]` is supplied, the settle is a compare-and-settle against
  the message row's CURRENT stored token — a mismatch (a stale/zombie token
  whose lock was lost and re-claimed by a new owner) refuses typed
  `{:error, :lock_lost}` and leaves both the message and the new owner's lock
  untouched. Callers that omit the token get the historical unscoped settle
  (connection.ex seam — disclosed, another lane owns that file).
  """
  @spec complete(String.t(), integer(), keyword()) :: :ok | {:error, :lock_lost}
  def complete(queue, seq, opts \\ []) do
    GenServer.call(server(), {:complete, queue, seq, opts})
  end

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
  @spec release(String.t(), integer(), keyword()) ::
          :ok | :error | {:error, :lock_lost | :capacity}
  def release(queue, seq, opts \\ []) do
    GenServer.call(server(), {:release, queue, seq, opts})
  end

  @doc """
  Receive deferred messages by sequence number (Service Bus
  `com.microsoft:receive-by-sequence-number`). Only messages currently in
  `:deferred` state qualify; every requested sequence number must qualify or
  the batch fails atomically with `{:error, {:not_deferred, refused}}` (no
  partial lock — the caller surfaces 410 MESSAGE_NOT_DEFERRED for the whole
  batch). Qualifying messages re-enter the normal lock path: a fresh
  LockManager lock is acquired at the queue's configured lock duration, so
  complete/abandon/renew behave identically to a live delivery. Delivery
  count is incremented (deferred receive is a delivery).

  Returns `{:ok, [msg]}` in the order of the request. Duplicate sequence
  numbers are deduplicated (R160b) — one message, one lock, one delivery.

  Opts: `:session_id` — when supplied (sessionful receive-by-sequence), every
  requested row's `session_id` must match or the row joins the atomic refusal
  list (same `{:error, {:not_deferred, refused}}` shape, no partial lock).
  """
  @spec receive_deferred(String.t(), [integer()], keyword()) ::
          {:ok, [map()]} | {:error, {:not_deferred, [integer()]}}
  def receive_deferred(queue, sequence_numbers, opts \\ []) when is_list(sequence_numbers) do
    now = opts[:now_ms] || System.system_time(:millisecond)
    GenServer.call(server(), {:receive_deferred, queue, sequence_numbers, now, opts[:session_id]})
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
          {:ok, integer()} | :error | {:error, :lock_lost | :capacity | :scheduled}
  def deadletter(queue, seq, reason, description \\ nil, opts \\ []) do
    GenServer.call(server(), {:deadletter, queue, seq, reason, description, opts})
  end

  @doc "Deadletter entity name for a queue."
  @spec deadletter_queue(String.t()) :: String.t()
  def deadletter_queue(queue), do: queue <> "/$deadletterqueue"

  # -- Session state / session enumeration / batch delete (GAP-A2-05/06/07) -----

  @doc """
  Fail-closed gate: both tables the session-state / enumeration / batch-delete
  surface reads and writes are materialized. `Smalt.Amqp.ManagementRpc` refuses
  typed 404 when this is false.
  """
  def tables_ready? do
    :ets.info(:smalt_sb_messages) != :undefined and
      :ets.info(:smalt_sb_sessions) != :undefined
  end

  @doc """
  Read the opaque session state for `{queue, session_id}` (field on the session
  lock record). `{:ok, state}` (state may be nil) or `{:error, :not_found}`
  when no session record exists.
  """
  @spec session_state_get(String.t(), String.t()) :: {:ok, binary() | nil} | {:error, :not_found}
  def session_state_get(queue, session_id) do
    case Smalt.Store.get(:smalt_sb_sessions, {queue, session_id}) do
      {:ok, %{session_state: state}} -> {:ok, state}
      {:ok, _other} -> {:ok, nil}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Persist opaque `state` bytes on the `{queue, session_id}` session record.
  Requires an existing session record (the SDK only sets state on an
  accepted session receiver, which holds the lock). `:ok` or
  `{:error, :not_found}`. Serialized through the claim/settle server.
  """
  @spec session_state_put(String.t(), String.t(), binary()) :: :ok | {:error, :not_found}
  def session_state_put(queue, session_id, state) do
    GenServer.call(server(), {:session_state_put, queue, session_id, state})
  end

  @doc """
  Enumerate session ids for `queue` (ordered_set key order = lexicographic by
  session id). Opts: `:skip` (default 0), `:top` (default 100). Returns
  `{:ok, ids}`.
  """
  @spec list_sessions(String.t(), keyword()) :: {:ok, [String.t()]}
  def list_sessions(queue, opts \\ []) do
    skip = max(opts[:skip] || 0, 0)
    top = (opts[:top] || 100) |> max(1)

    ids =
      (
        locked =
          :smalt_sb_sessions
          |> :ets.match_object({{queue, :_}, :_})
          |> Enum.map(fn {{_q, sid}, _lock} -> sid end)

        # Real Azure enumerates sessions that have messages, not only ones
        # with a live lock: a session receiver closed long ago leaves its
        # messages (and session state) behind, and get-message-sessions must
        # still list the session (repair lane R96).
        with_messages =
          :smalt_sb_messages
          |> :ets.match_object({{queue, :_}, :_})
          |> Enum.map(fn {{_q, _seq}, m} -> Map.get(m, :session_id) end)
          |> Enum.reject(&is_nil/1)

        (locked ++ with_messages)
        |> Enum.uniq()
        |> Enum.sort()
      )
      |> Enum.drop(skip)
      |> Enum.take(top)

    {:ok, ids}
  end

  @doc """
  Batch delete: remove every PRESENT `{queue, seq}` message row; absent
  sequence numbers are skipped (they do not fail the batch). Returns
  `{:ok, deleted_count}`. Serialized through the claim/settle server.
  """
  @spec delete_by_sequence(String.t(), [integer()]) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def delete_by_sequence(queue, seqs) when is_list(seqs) do
    GenServer.call(server(), {:delete_by_sequence, queue, seqs})
  end

  # Repair lane R70 (audit A19 F2): implement cancel_scheduled/2 — the enqueue
  # comment promised it. Deletes a still-scheduled row by sequence number.
  # No KD row (lane R70, internal repair, not a divergence).
  @doc """
  Cancel a scheduled message by sequence number (Service Bus
  `ScheduledEnqueueTimeUtc` cancel). Only rows still in `:scheduled` state
  cancel; anything else (or absent) returns `{:error, :not_scheduled}` /
  `{:error, :not_found}`.
  """
  @spec cancel_scheduled(String.t(), integer()) :: :ok | {:error, :not_found | :not_scheduled}
  def cancel_scheduled(queue, seq) do
    GenServer.call(server(), {:cancel_scheduled, queue, seq})
  end

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
  def handle_call({:enqueue, queue, body, opts}, _from, state) do
    if capacity_full?(queue) do
      {:reply, {:error, :capacity}, state}
    else
      {:reply, do_enqueue_locked(queue, body, opts), state}
    end
  end

  def handle_call({:claim, queue, filter_session, now, lock_duration}, _from, state) do
    reply =
      queue
      |> claim_candidates(now, filter_session)
      |> claim_next(queue, now, lock_duration)

    {:reply, reply, state}
  end

  def handle_call({:complete, queue, seq, opts}, _from, state) do
    {:reply, do_complete(queue, seq, opts), state}
  end

  def handle_call({:defer, queue, seq}, _from, state) do
    {:reply, do_defer(queue, seq), state}
  end

  def handle_call({:release, queue, seq, opts}, _from, state) do
    {:reply, do_release(queue, seq, opts), state}
  end

  def handle_call({:receive_deferred, queue, sequence_numbers, now, filter_session}, _from, state) do
    {:reply, do_receive_deferred(queue, sequence_numbers, now, filter_session), state}
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

  def handle_call({:session_release, queue, session_id, expected_token}, _from, state) do
    # LockManager.session_release/2 serializes its token-scoped
    # compare-and-delete through the same server as session_claim (V261014-04
    # F3, A32 fix 1): a concurrent acquire can never interleave, and the
    # releaser can only delete the row whose lock_token it actually observed —
    # B's fresh lock survives a late releaser (ABA guard).
    {:reply, Smalt.Amqp.LockManager.do_session_release(queue, session_id, expected_token), state}
  end

  def handle_call({:message_renew, token, now_ms, opts}, _from, state) do
    # Message-lock renew serialized with claims/settlements/sweeps: the token
    # put and the message-row mirror land atomically against do_sweep, so a
    # renewed lock is never reclaimed at its original (stale) expiry.
    {:reply, Smalt.Amqp.LockManager.do_message_renew(token, now_ms, opts), state}
  end

  def handle_call({:session_renew, queue, session_id, now_ms, opts}, _from, state) do
    # LockManager.session_renew/4 serializes its get+put pair through the
    # claim server (A32 fix 2): no interleaving acquire between read and write.
    {:reply, Smalt.Amqp.LockManager.do_session_renew(queue, session_id, now_ms, opts), state}
  end

  def handle_call({:session_state_put, queue, session_id, state}, _from, state_store) do
    {:reply, do_session_state_put(queue, session_id, state), state_store}
  end

  def handle_call({:delete_by_sequence, queue, seqs}, _from, state_store) do
    {:reply, do_delete_by_sequence(queue, seqs), state_store}
  end

  def handle_call({:cancel_scheduled, queue, seq}, _from, state_store) do
    {:reply, do_cancel_scheduled(queue, seq), state_store}
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
    # No KD row (repair lane R70, audit A19 F2 — internal repair, not a
    # divergence). SHIM-COURT: scheduled
    # messages stay invisible until their scheduled_enqueue_time arrives.
    |> Enum.reject(fn m ->
      m.state == :scheduled and is_integer(m.scheduled_enqueue_time) and
        m.scheduled_enqueue_time > now
    end)
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
          |> Map.merge(%{
            state: :locked,
            lock_token: lock.lock_token,
            locked_until: lock.locked_until
          })

        Smalt.Store.put(:smalt_sb_messages, {queue, m.seq}, msg)
        {:ok, msg, lock}
    end
  end

  defp locked_now?(%{state: :locked, locked_until: until}, now) when is_integer(until),
    do: until > now

  defp locked_now?(_, _), do: false

  # -- settlement internals (run inside the server) -----------------------------

  # Token-scoped settlement CAS (audit Finding 2, lane R244). SHIM-COURT:
  # when a disposition token is supplied it must equal the message row's
  # CURRENT stored token — a stale/zombie token (lock lost, message
  # re-claimed by a new owner) refuses typed :lock_lost and touches nothing,
  # so it can never complete out from under the new owner or delete the new
  # owner's token row. Runs inside the serialized claim/settle server, so
  # the compare and the settle are atomic against claims/sweeps.
  defp settle_token_ok?(%{lock_token: stored}, expected) when is_binary(expected),
    do: stored == expected

  defp settle_token_ok?(_m, _nil_or_absent), do: true

  defp do_complete(queue, seq, opts) do
    case Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      {:ok, m} ->
        if settle_token_ok?(m, opts[:lock_token]) do
          if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)
          Smalt.Store.delete(:smalt_sb_messages, {queue, seq})
        else
          {:error, :lock_lost}
        end

      :error ->
        :ok
    end
  end

  defp do_defer(queue, seq) do
    with {:ok, m} <- Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)

      Smalt.Store.put(:smalt_sb_messages, {queue, seq}, %{
        m
        | state: :deferred,
          lock_token: nil,
          locked_until: nil
      })

      :ok
    else
      :error -> :error
    end
  end

  # Receive-by-sequence-number: two-pass so a bad sequence anywhere in the
  # batch fails the whole batch atomically (no partial lock), then each
  # qualifying message re-locks at the queue's configured duration.
  defp do_receive_deferred(queue, sequence_numbers, now, filter_session) do
    duration = queue_settings(queue).lock_duration_ms

    # R160b / SHIM-COURT: a duplicate sequence number in the batch must not
    # acquire two independent locks for one message (double delivery in one
    # 200, first token stranded, delivery_count double-incremented). Dedup
    # here — the store seam — keeps the batch-atomic contract ("no partial
    # lock") intact and covers the sole caller (management_rpc
    # receive-by-sequence-number) plus any future direct QueueStore consumer.
    sequence_numbers = Enum.uniq(sequence_numbers)

    loaded =
      Enum.map(sequence_numbers, fn seq ->
        {seq, Smalt.Store.get(:smalt_sb_messages, {queue, seq})}
      end)

    refused =
      for {seq, {:ok, m}} <- loaded,
          # R150: DLQ-full parked rows (:deferred + dlq_full_park) are not
          # receivable by sequence — they return to rotation only via do_sweep's
          # deadletter-retry when DLQ capacity frees. SHIM-COURT R150.
          m.state != :deferred or m[:dlq_full_park] == true,
          do: seq

    refused = refused ++ for {seq, :error} <- loaded, do: seq

    # Sessionful receive-by-sequence: a session filter refuses rows that
    # belong to another session (atomic batch, no partial lock).
    refused =
      (refused ++
         if filter_session do
           for {seq, {:ok, m}} <- loaded,
               m.state == :deferred and m.session_id != filter_session,
               do: seq
         else
           []
         end)
      |> Enum.uniq()

    if refused == [] do
      # The unguarded {:ok, lock} match is safe: the two-pass precheck above
      # guarantees every sequence is present and lockable before we get here.
      {:ok,
       Enum.map(loaded, fn {_seq, {:ok, m}} ->
         {:ok, lock} =
           Smalt.Amqp.LockManager.acquire(queue, m.seq, now_ms: now, duration_ms: duration)

         msg =
           m
           |> Map.update!(:delivery_count, &(&1 + 1))
           |> Map.merge(%{
             state: :locked,
             lock_token: lock.lock_token,
             locked_until: lock.locked_until,
             # Deferred receipt marker: abandon/lock-expiry must return the
             # row to :deferred (receivable only by sequence), never back to
             # the normal :available rotation.
             deferred_receipt: true
           })

         Smalt.Store.put(:smalt_sb_messages, {queue, m.seq}, msg)
         msg
       end)}
    else
      {:error, {:not_deferred, Enum.sort(refused)}}
    end
  end

  defp do_release(queue, seq, opts) do
    with {:ok, m} <- Smalt.Store.get(:smalt_sb_messages, {queue, seq}),
         :ok <- if(settle_token_ok?(m, opts[:lock_token]), do: :ok, else: {:error, :lock_lost}) do
      max_delivery = queue_settings(queue).max_delivery_count

      if m.delivery_count >= max_delivery do
        # SHIM-COURT R64 (F3): propagate DLQ-capacity failure — a deadletter
        # that cannot land in the DLQ must not be reported as :ok, or the
        # message is stranded with a lying receipt.
        case do_deadletter(
               queue,
               seq,
               "MaxDeliveryCountExceeded",
               "delivery_count #{m.delivery_count} >= max_delivery_count #{max_delivery}",
               # Thread the disposition token: the internal deadletter settles
               # under the same CAS the release was admitted by (R244).
               now_ms: opts[:now_ms],
               lock_token: opts[:lock_token]
             ) do
          {:error, :capacity} ->
            # R128 (W5-2): DLQ full — park the maxed message as :deferred
            # (non-claimable by dequeue_matching) instead of leaving it
            # :locked with an expired lock. Stops the poison redelivery
            # livelock; do_sweep retries the deadletter when capacity frees.
            if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)

            Smalt.Store.put(
              :smalt_sb_messages,
              {queue, seq},
              m
              |> Map.merge(%{
                state: :deferred,
                lock_token: nil,
                locked_until: nil
              })
              |> Map.put(:dlq_full_park, true)
            )

            {:error, :capacity}

          _ ->
            :ok
        end
      else
        if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)

        # Deferred receipt (receive-by-sequence): abandon returns the row to
        # :deferred — it stays receivable only by sequence number, never back
        # in the normal :available rotation. A plain (non-deferred) abandon
        # restores :available as before.
        restored_state = if m[:deferred_receipt], do: :deferred, else: :available

        Smalt.Store.put(:smalt_sb_messages, {queue, seq}, %{
          m
          | state: restored_state,
            lock_token: nil,
            locked_until: nil
        })

        :ok
      end
    else
      :error -> :error
      # Token CAS refusal (R244) falls through the with unchanged.
      {:error, :lock_lost} -> {:error, :lock_lost}
    end
  end

  defp do_deadletter(queue, seq, reason, description, opts) do
    dlq = queue <> "/$deadletterqueue"

    case Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      # R142 (W5-9): a still-:scheduled row must not be deadlettered — the
      # management path would silently drop the schedule and materialize an
      # immediately-available DLQ copy. Mirrors do_cancel_scheduled's state
      # guard (max-delivery deadlettering only ever targets locked rows).
      {:ok, %{state: :scheduled}} ->
        {:error, :scheduled}

      {:ok, m} ->
        # Token-scoped CAS (audit Finding 2, lane R244): a stale disposition
        # token must never move a message a new owner holds.
        cond do
          not settle_token_ok?(m, opts[:lock_token]) ->
            {:error, :lock_lost}

          # SHIM-COURT R6: do_deadletter runs INSIDE the serialized QueueStore
          # server, so do_enqueue/3's GenServer.call(server(), ...) would call
          # the server from itself and crash. Use do_enqueue_locked/3 directly,
          # applying the same capacity_full?/1 check the enqueue path applies.
          capacity_full?(dlq) ->
            {:error, :capacity}

          true ->
            {:ok, dlq_seq} =
              do_enqueue_locked(dlq, m.body,
                # DLQ copy preserves the message id (SB parity: the DLQ
                # message is the same message — witnessed by the s5 e2e
                # court, probe 5 messageId assert).
                message_id: m.message_id,
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
                delivery_count: m.delivery_count,
                now_ms: opts[:now_ms]
              )

            Smalt.Store.delete(:smalt_sb_messages, {queue, seq})
            if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)
            {:ok, dlq_seq}
        end

      :error ->
        :error
    end
  end

  # GAP-A2-05: state lives on the session lock record; requires the record.
  defp do_session_state_put(queue, session_id, state) do
    case Smalt.Store.get(:smalt_sb_sessions, {queue, session_id}) do
      {:ok, lock} ->
        Smalt.Store.put(
          :smalt_sb_sessions,
          {queue, session_id},
          Map.put(lock, :session_state, state)
        )

        :ok

      :error ->
        {:error, :not_found}
    end
  end

  # Repair lane R70 (audit A19 F2). SHIM-COURT: cancel only a row still in
  # :scheduled state; a delivered/locked/available row is never cancellable.
  defp do_cancel_scheduled(queue, seq) do
    case Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
      {:ok, %{state: :scheduled} = m} ->
        if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)
        Smalt.Store.delete(:smalt_sb_messages, {queue, seq})
        :ok

      {:ok, _} ->
        {:error, :not_scheduled}

      :error ->
        {:error, :not_found}
    end
  end

  # GAP-A2-07: delete-present semantics (absent seqs are skipped, not fatal).
  defp do_delete_by_sequence(queue, seqs) do
    deleted =
      Enum.count(seqs, fn seq ->
        case Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
          {:ok, m} ->
            if m.lock_token, do: Smalt.Amqp.LockManager.release(m.lock_token)
            Smalt.Store.delete(:smalt_sb_messages, {queue, seq})
            true

          :error ->
            false
        end
      end)

    {:ok, deleted}
  end

  # Expired message-lock reclamation: back to :available, token deleted.
  defp do_sweep do
    now = System.system_time(:millisecond)

    reclaimed =
      :ets.match_object(:smalt_sb_messages, {{:_, :_}, :_})
      |> Enum.flat_map(fn {_k, m} ->
        # R128 (W5-2): DLQ-full parked messages (:deferred + dlq_full_park)
        # are swept too — deadletter retried when capacity frees.
        parked = m[:dlq_full_park] == true and m.state == :deferred

        if parked or (m.state == :locked and is_integer(m.locked_until) and m.locked_until <= now) do
          [m]
        else
          []
        end
      end)
      |> Enum.reduce(0, fn m, n ->
        # SHIM-COURT R64 (F1): expired-lock sweep enforces MaxDeliveryCount
        # like do_release — deadletter at max, else re-avail. Previously the
        # sweep restored unconditionally, so delivery_count grew unbounded.
        max_delivery = queue_settings(m.queue).max_delivery_count

        if m[:dlq_full_park] == true or m.delivery_count >= max_delivery do
          case do_deadletter(
                 m.queue,
                 m.seq,
                 "MaxDeliveryCountExceeded",
                 "delivery_count #{m.delivery_count} >= max_delivery_count #{max_delivery} on lock expiry",
                 now_ms: now
               ) do
            {:ok, _} -> n + 1
            _ -> n
          end
        else
          Smalt.Amqp.LockManager.release(m.lock_token)

          # Deferred receipt: lock expiry returns the row to :deferred
          # (sequence-only receivability), matching do_release's abandon path.
          restored_state = if m[:deferred_receipt], do: :deferred, else: :available

          Smalt.Store.put(:smalt_sb_messages, {m.queue, m.seq}, %{
            m
            | state: restored_state,
              lock_token: nil,
              locked_until: nil
          })

          n + 1
        end
      end)

    # session locks are LockManager's records; delegate the lock/session table GC
    Smalt.Amqp.LockManager.do_sweep_expired(now)
    reclaimed
  end
end

defmodule Smalt.Messaging.SbDelivery do
  @moduledoc """
  Service Bus delivery control surface (T-08): native dead-letter queue,
  scheduled messages, and message deferral — the store-backed engine behind
  the broker facade (`Smalt.AmqpBroker`).

  Storage: NO new tables. Reuses the existing QueueStore ensemble (tables
  created by `Smalt.Store`, state transitions serialized through the
  `Smalt.Amqp.QueueStore` claim/settle server):

  | Table | Key | Reuse |
  |---|---|---|
  | `:smalt_sb_queues` | entity name; counter `{entity, :seq}` | DLQ subqueue entity rows + per-entity sequence counters |
  | `:smalt_sb_messages` | `{entity, seq}` | message rows (body/app-props/annotations, `:state`, `:seq`, `:scheduled_enqueue_time`) |
  | `:smalt_sb_locks` | lock token | settlement locks (LockManager-owned, untouched here) |

  ## Subqueue law (scope 1)

  Every queue's dead-letter subqueue is `"<queue>/$deadletterqueue"` and
  every subscription's is `"<topic>/Subscriptions/<sub>/$deadletterqueue"`
  (`dlq_name/1`, `subscription_dlq_name/2`) — a real, AMQP-receivable
  entity: receiver links attach to the subqueue address directly (the
  connection lane already normalizes the SDK's `$DeadLetterQueue` casing on
  attach). A dead-letter move stamps `DeadLetterReason` /
  `DeadLetterErrorDescription` into the DLQ copy's application properties
  AND annotations, carries the original application properties, body,
  session id and message id over intact, and keeps the delivery count
  counting (SB parity: the DLQ copy is the same message).

  ## Scheduled law (scope 2)

  A message enqueued with `QueueStore.enqueue/3`'s `:scheduled_enqueue_time`
  opt (epoch ms — fed by the send annotations / REST
  `ScheduledEnqueueTimeUtc`) starts in `:scheduled` state and is invisible
  to receivers until the timestamp (`visible?/2`), then receivable exactly
  on time. `schedule_cancel/2` kills a still-scheduled row by sequence
  number. Sequence numbers surface on every delivered row
  (`sequence_number/1`).

  ## Deferral law (scope 3)

  The defer settlement (`QueueStore.defer/3`, wired from the AMQP modified
  disposition's `undeliverable-here`) flags the row `:deferred`; the normal
  receive path never surfaces it again — only `receive_deferred/3` by
  sequence number re-locks and re-delivers it (abandon/lock-expiry return
  the row to `:deferred`, never to the available rotation).

  ## Time discipline (event_hubs injected-clock pattern)

  Every function that depends on time takes an injected `now_ms` /
  forwards the caller's `opts[:now_ms]` to the store, so courts are
  deterministic and zero-sleep: a scheduled row is fenced with
  `now_ms: due - 1` (invisible) vs `now_ms: due` (receivable).
  """

  alias Smalt.Amqp.QueueStore

  @dlq_suffix "/$deadletterqueue"
  @subscriptions_segment "/Subscriptions/"
  @dlq_reason_key "DeadLetterReason"
  @dlq_description_key "DeadLetterErrorDescription"

  # -- DLQ naming ----------------------------------------------------------------

  @doc """
  Dead-letter subqueue entity name for `entity` (scope 1). A queue `"q"`
  gets `"q/$deadletterqueue"`; a subscription address
  `"<topic>/Subscriptions/<sub>"` gets
  `"<topic>/Subscriptions/<sub>/$deadletterqueue"`.
  """
  @spec dlq_name(String.t()) :: String.t()
  def dlq_name(entity) when is_binary(entity), do: entity <> @dlq_suffix

  @doc """
  Subscription DLQ from its parts:
  `subscription_dlq_name("t", "s") == "t/Subscriptions/s/$deadletterqueue"`.
  """
  @spec subscription_dlq_name(String.t(), String.t()) :: String.t()
  def subscription_dlq_name(topic, sub) when is_binary(topic) and is_binary(sub) do
    topic <> @subscriptions_segment <> sub <> @dlq_suffix
  end

  # -- Message record extensions ---------------------------------------------------

  @doc """
  Sequence number of a stored QueueStore row (scope 3: surfaces on every
  received message). A DLQ copy carries its own fresh per-DLQ sequence.
  """
  @spec sequence_number(map()) :: integer() | nil
  def sequence_number(%{seq: seq}) when is_integer(seq), do: seq
  def sequence_number(_), do: nil

  @doc """
  Scheduled-enqueue timestamp (epoch ms) of a stored row (scope 2), or nil
  when the row is not scheduled.
  """
  @spec scheduled_enqueue_at(map()) :: non_neg_integer() | nil
  def scheduled_enqueue_at(%{scheduled_enqueue_time: t}) when is_integer(t), do: t
  def scheduled_enqueue_at(_), do: nil

  @doc "True when the row carries the Service Bus deferral flag (scope 3)."
  @spec deferred?(map()) :: boolean()
  def deferred?(%{state: :deferred}), do: true
  def deferred?(_), do: false

  # -- Visibility gate ---------------------------------------------------------------

  @doc """
  Receive-visibility gate (scopes 2+3): true exactly when a stored row is
  receivable by the normal receive path at `now_ms` —

    * `:deferred` rows — never (sequence-only receivability);
    * `:dead` rows — never (already dead-lettered);
    * `:scheduled` rows — only at/after their `scheduled_enqueue_time`;
    * anything else — yes.

  This is the testable form of the predicate
  `Smalt.Amqp.QueueStore.claim_candidates/3` applies on every receiver-link
  delivery (`Smalt.Amqp.Connection` receive path) — the receive path excludes
  scheduled-future and deferred messages by construction.
  """
  @spec visible?(map(), integer()) :: boolean()
  def visible?(msg, now_ms) when is_map(msg) and is_integer(now_ms) do
    case msg do
      %{state: :deferred} -> false
      %{state: :dead} -> false
      %{state: :scheduled} -> scheduled_due?(msg, now_ms)
      _ -> true
    end
  end

  defp scheduled_due?(%{scheduled_enqueue_time: t}, now) when is_integer(t), do: t <= now

  # A :scheduled row without a usable timestamp is due (matches the enqueue
  # fallback: only a non-negative integer ever schedules).
  defp scheduled_due?(_, _), do: true

  @doc false
  def now_ms, do: System.system_time(:millisecond)

  # -- Dead-letter (scope 1) ---------------------------------------------------------

  # Defaults declared once for the multi-clause body below.
  @doc """
  Dead-letter `entity`'s message into its DLQ subqueue (`dlq_name/1`) with
  `DeadLetterReason` / `DeadLetterErrorDescription` (SDK
  `receiver.deadLetterMessage(msg, {deadLetterReason, deadLetterErrorDescription})`).

  Two forms:

    * `dead_letter(entity, seq, reason, description \\ nil, opts \\ [])` —
      a STORED row: the move is the settlement outcome
      (`QueueStore.deadletter/5`, serialized, token-scoped via
      `opts[:lock_token]`). Returns `{:ok, dlq_seq}` (fresh per-DLQ
      sequence), `:error` (row gone), or
      `{:error, :lock_lost | :capacity | :scheduled}`.

    * `dead_letter(entity, msg_map, reason, description \\ nil, opts \\ [])` —
      a message NOT yet stored in `entity` (the rule fan-out no-match face):
      enqueue a fresh DLQ copy. `msg_map` keys: `:body`, `:message_id`,
      `:app_props` (original application properties — carried intact),
      `:annotations`, `:session_id`, `:delivery_count`; `opts[:now_ms]`
      injects the clock. Returns `{:ok, dlq_seq}` or the enqueue error.

  Both forms stamp the reason/description into application properties (SDK
  parity: `serviceBusMessage.js` reads them from application properties)
  and annotations.
  """
  def dead_letter(entity, msg_or_seq, reason, description \\ nil, opts \\ [])

  def dead_letter(entity, seq, reason, description, opts)
      when is_binary(entity) and is_integer(seq) and is_binary(reason) do
    QueueStore.deadletter(entity, seq, reason, description, opts)
  end

  def dead_letter(entity, msg, reason, description, opts)
      when is_binary(entity) and is_map(msg) and is_binary(reason) do
    # Seam tolerance (L8, v26.10.29): the rule fan-out caller passes the FULL
    # DLQ entity name (`subscription_dlq_name/2` output); this form resolves the
    # target by appending @dlq_suffix. Idempotent for the suffix so both
    # spellings (raw entity address and full DLQ name) name the same subqueue —
    # the first no-match copy was landing in "<dlq>/$deadletterqueue".
    dlq = if String.ends_with?(entity, @dlq_suffix), do: entity, else: dlq_name(entity)

    _ = QueueStore.ensure_queue(dlq)

    QueueStore.enqueue(dlq, msg[:body] || "",
      message_id: msg[:message_id],
      app_props: dlq_stamp(msg[:app_props] || %{}, reason, description),
      annotations: dlq_stamp(msg[:annotations] || %{}, reason, description),
      session_id: msg[:session_id],
      delivery_count: msg[:delivery_count] || 0,
      now_ms: opts[:now_ms]
    )
  end

  defp dlq_stamp(map, reason, description) do
    Map.merge(map, %{
      @dlq_reason_key => reason,
      @dlq_description_key => description
    })
  end

  # -- Scheduled cancel (scope 2) ----------------------------------------------------

  @doc """
  Cancel a scheduled message by sequence number (SDK
  `cancelScheduledMessage`). Only rows still in `:scheduled` state cancel
  (`:ok`); an absent row is `{:error, :not_found}`; a row already
  live/delivered is `{:error, :not_scheduled}`.
  """
  @spec schedule_cancel(String.t(), integer()) ::
          :ok | {:error, :not_found | :not_scheduled}
  def schedule_cancel(entity, seq) when is_binary(entity) and is_integer(seq),
    do: QueueStore.cancel_scheduled(entity, seq)

  # -- Receive deferred (scope 3) ------------------------------------------------------

  @doc """
  Receive deferred messages by sequence number (SDK
  `receiveDeferredMessages(sequenceNumbers)`). Only `:deferred` rows
  qualify; the whole batch fails atomically with
  `{:error, {:not_deferred, refused}}` — no partial lock. Qualifying rows
  re-lock at the queue's configured lock duration (complete/abandon/renew
  behave as a live delivery; abandon returns the row to `:deferred`).
  Delivery count increments — a deferred receive is a delivery.

  Opts: `:now_ms` (injected clock for the lock), `:session_id` (sessionful
  receive-by-sequence filter).
  """
  @spec receive_deferred(String.t(), [integer()], keyword()) ::
          {:ok, [map()]} | {:error, {:not_deferred, [integer()]}}
  def receive_deferred(entity, sequence_numbers, opts \\ [])
      when is_binary(entity) and is_list(sequence_numbers) do
    QueueStore.receive_deferred(entity, sequence_numbers, opts)
  end
end

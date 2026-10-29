defmodule Smalt.AmqpBroker do
  @moduledoc """
  Facade supervisor for the AMQP 1.0 broker (Service Bus on 5672, Event Hubs on 5673).

  Supervises two listeners (Service Bus mode `:sb` on `Application.get_env(:smalt, :amqp_port, 5672)`,
  Event Hubs mode `:eh` on `Application.get_env(:smalt, :event_hubs_port, 5673)`), the 250 ms
  `Smalt.Amqp.Sweeper`, and a `DynamicSupervisor` that owns one
  `Smalt.Amqp.Connection` process per accepted socket.

  A connection crash is contained by the DynamicSupervisor (`:temporary` children);
  the listeners and the sweeper survive. Listener bind failures stop the listener
  child only — never the whole application.

  Legacy compatibility: `{Smalt.AmqpBroker, 5672}` (integer argument) is still
  accepted and pins the Service Bus port; `{Smalt.AmqpBroker, []}` reads ports
  from application env.
  """

  use Supervisor

  @doc "Starts the broker facade supervisor. Accepts `[]` (ports from app env) or a legacy integer SB port."
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, normalize(arg), name: __MODULE__)
  end

  defp normalize(port) when is_integer(port), do: [sb_port: port]
  defp normalize(opts) when is_list(opts), do: opts

  @doc """
  The supervised children: SB listener, EH listener, Sweeper, and the per-connection
  DynamicSupervisor. Exposed so tests and embedders can inspect the tree without
  starting fixed ports.
  """
  def children(opts \\ []) do
    sb_port = opts[:sb_port] || Application.get_env(:smalt, :amqp_port, 5672)
    eh_port = opts[:eh_port] || Application.get_env(:smalt, :event_hubs_port, 5673)

    [
      {Smalt.Amqp.Listener, {:sb, sb_port}},
      {Smalt.Messaging.EventHubs.Listener, {:eh, eh_port}},
      Smalt.Amqp.Sweeper,
      {DynamicSupervisor, name: conn_sup_name(), strategy: :one_for_one}
    ]
  end

  @doc "Name of the DynamicSupervisor that owns accepted `Smalt.Amqp.Connection` processes."
  def conn_sup_name, do: Smalt.AmqpBroker.ConnSup

  # -- SB delivery control surface (T-08) ---------------------------------------
  #
  # Native DLQ / scheduled messages / message deferral, engine in
  # `Smalt.Messaging.SbDelivery` (store-backed: `:smalt_sb_queues`,
  # `:smalt_sb_messages`, `:smalt_sb_locks` — no new tables). The delegates
  # below expose the semantics on the broker facade; the AMQP wire paths
  # already route through the same seams (connection.ex is T-12's file):
  #   * receive paths exclude scheduled-future and :deferred rows —
  #     `QueueStore.dequeue_matching/2` -> `claim_candidates/3` applies
  #     exactly `SbDelivery.visible?/2` on every receiver-link delivery;
  #   * a dead-letter settle (rejected outcome / max-delivery) moves the row
  #     to `<entity>/$deadletterqueue` via `QueueStore.deadletter/5`
  #     (`Smalt.Amqp.Connection.settle/3`), reason/description riding the
  #     rejected outcome's error info, original properties intact;
  #   * scheduled send rides `QueueStore.enqueue/3`'s `:scheduled_enqueue_time`
  #     opt (send annotations / REST ScheduledEnqueueTimeUtc); cancel and
  #     receive-by-sequence ride the `$management` RPC
  #     (`com.microsoft:cancel-scheduled-message`,
  #     `com.microsoft:receive-by-sequence-number`).
  defdelegate sb_visible?(msg, now_ms), to: Smalt.Messaging.SbDelivery, as: :visible?

  defdelegate dead_letter(entity, msg_or_seq, reason, description \\ nil),
    to: Smalt.Messaging.SbDelivery

  defdelegate schedule_cancel(entity, seq), to: Smalt.Messaging.SbDelivery

  defdelegate receive_deferred(entity, sequence_numbers, opts \\ []),
    to: Smalt.Messaging.SbDelivery

  @impl true
  def init(opts) do
    Supervisor.init(children(opts), strategy: :one_for_one)
  end
end

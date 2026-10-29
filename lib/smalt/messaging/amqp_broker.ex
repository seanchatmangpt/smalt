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

  @impl true
  def init(opts) do
    Supervisor.init(children(opts), strategy: :one_for_one)
  end
end

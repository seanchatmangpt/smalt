defmodule Smalt.Plane.IntegrationSupervisor do
  @moduledoc """
  Supervision subtree for the Integration Plane:
  - Smalt.AmqpBroker (AMQP 1.0 Service Bus, Event Hubs)
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Smalt.AmqpBroker, []}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end
end

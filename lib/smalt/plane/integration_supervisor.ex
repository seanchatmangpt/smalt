defmodule Smalt.Plane.IntegrationSupervisor do
  @moduledoc """
  Supervision subtree for the Integration Plane:
  - Smalt.Store — the queue/DLQ model (Smalt.Amqp.QueueStore) reads and
    writes the `:smalt_sb_queues` Store table; without a local Store the
    integration-only plane cannot serve queues at all (witnessed AZB-17
    matrix defect 2026-10-19: `:ets.lookup(:smalt_sb_queues, ...)` on a
    table that only the data subtree opens — s4-amqp-capacity refused).
  - Smalt.AmqpBroker (AMQP 1.0 Service Bus, Event Hubs)
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Store is owned by the Data plane (DataSupervisor). On a full-plane
    # boot the data subtree has already started it by supervision order
    # (Data -> Control -> Integration), so re-listing it here would fail
    # the whole app with {:error, {:already_started, pid}}. Include it
    # only when no instance is running (integration-only plane boot).
    store_child =
      if Process.whereis(Smalt.Store) == nil do
        [Smalt.Store]
      else
        []
      end

    children = store_child ++ [{Smalt.AmqpBroker, []}]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end
end

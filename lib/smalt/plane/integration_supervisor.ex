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

    children = store_child ++ eh_state_children() ++ broker_children() ++ redis_wire_children()

    spec =
      Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)

    spec
  end

  # BOOTPROF cut #2: deferred AMQP-broker (5672/5673) start, invoked by
  # Smalt.Application.ListenerDeferral on the tick after the front door is
  # already bound and accepting.
  @doc false
  def start_deferred_listener do
    Supervisor.start_child(__MODULE__, {Smalt.AmqpBroker, []})
  end

  # BOOTPROF cut #2 (RELCUT, NFR-FOOTPRINT): AMQP (5672/5673) listeners are
  # deferred under :deferred_listeners - the broker starts on a 0 ms tick
  # after the front-door listeners accept. Default mode is byte-identical.
  defp broker_children do
    if Smalt.Application.deferred_listeners?() do
      []
    else
      [{Smalt.AmqpBroker, []}]
    end
  end

  # SPOF-B / A-2 + A-4: EH state owners as supervised children (was: lazy
  # first-caller start with heir-less tables — owner death silently wiped seq/
  # checkpoint/cg state). Tables are heir'd to :init inside each init, so an
  # owner crash no longer drops data; supervision adds the missing restart.
  defp eh_state_children do
    [
      {Smalt.Messaging.EventHubs.Server, []},
      {Smalt.Messaging.EhGeoDr, []}
    ]
  end

  # T01 (v26.10.29): RESP2 wire listener facade over AzureCache — non-deferred
  # (the broker_children/0 precedent). Bind failure is contained INSIDE the
  # facade init (the listener child is skipped; the app boots).
  defp redis_wire_children do
    [{Smalt.DataPlane.RedisWire, []}]
  end
end

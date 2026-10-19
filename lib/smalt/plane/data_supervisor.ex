defmodule Smalt.Plane.DataSupervisor do
  @moduledoc """
  Supervision subtree for the Data Plane:
  - Smalt.Store
  - Bandit egress router (Cosmos DB SQL AST & Blob Storage)
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Smalt.Store,
      # AZB-22b: bound graceful-stop. Bandit's own child_spec omits
      # `shutdown`, so with type :supervisor it defaults to :infinity —
      # a stuck ThousandIsland listener hung the whole tree's stop
      # (>60s witnessed in the burn ring). 10s bounds the wait; the
      # supervisor then brutal-kills and stop completes.
      Supervisor.child_spec(
        {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: egress_port(), ip: bind_ip()},
        shutdown: 10_000
      )
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end

  defp egress_port, do: Application.get_env(:smalt, :egress_port, 8443)

  defp bind_ip do
    case Application.get_env(:smalt, :bind_all_interfaces, false) do
      true -> {0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end
  end
end

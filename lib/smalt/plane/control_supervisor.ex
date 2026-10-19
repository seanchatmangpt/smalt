defmodule Smalt.Plane.ControlSupervisor do
  @moduledoc """
  Supervision subtree for the Control Plane:
  - ARM Gateway HTTP router (9443)
  - ARM Gateway TLS twin (9444)
  - LRO Notifier and Sweeper
  - WasmEngine Supervisor
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Bandit, plug: Smalt.ArmGateway.Router, scheme: :http, port: arm_port(), ip: bind_ip()},
      {Bandit, arm_tls_opts() ++ [ip: bind_ip()]},
      Smalt.ArmGateway.LRO.Notifier,
      Smalt.ArmGateway.LRO.Sweeper,
      Smalt.Affidavit.WasmEngine.Supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end

  defp arm_port, do: Smalt.Config.arm_port()
  defp arm_tls_port, do: Application.get_env(:smalt, :arm_tls_port, 9444)

  defp arm_tls_opts do
    Smalt.TLS.bandit_opts(Smalt.Application.TlsTwinDispatch, arm_tls_port())
  end

  defp bind_ip do
    case Application.get_env(:smalt, :bind_all_interfaces, false) do
      true -> {0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end
  end
end

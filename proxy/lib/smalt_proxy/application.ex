defmodule SmaltProxy.Application do
  @moduledoc """
  Standalone proxy OTP application (WO v26.10.15/23 scaffold).
  Independent of the root :smalt project by construction — `cd proxy && mix compile`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {SmaltProxy.Router, port: Application.get_env(:smalt_proxy, :port, 9460)}
    ]

    opts = [strategy: :one_for_one, name: SmaltProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

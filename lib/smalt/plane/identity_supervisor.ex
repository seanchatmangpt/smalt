defmodule Smalt.Plane.IdentitySupervisor do
  @moduledoc """
  Supervision subtree for the Identity Plane:
  - KeyVault data plane and STS token endpoints (hosted across ARM TLS twin / Egress router)
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Identity endpoints are served over TLS twin and egress router.
    # The supervisor maintains identity state and token rotation lifecycle.
    children = []
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end
end

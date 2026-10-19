defmodule Smalt.Plane.IdentitySupervisor do
  @moduledoc """
  Supervision subtree for the Identity Plane:
  - `Smalt.Plane.Identity.StsGate` — the killable identity-plane child whose
    liveness gates NEW STS token mints (AZB-15 DR contract: subtree killed ⇒
    mint 503 `StsUnavailable` typed; cached-valid tokens stay accepted —
    bearer validation is local, never an identity-plane runtime call).
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Smalt.Plane.Identity.StsGate
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end
end

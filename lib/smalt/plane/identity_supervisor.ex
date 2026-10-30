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
      Smalt.Plane.Identity.StsGate,
      # T02: SAML 2.0 IdP face (Bandit plug, :saml_idp_port default 9445).
      # one_for_one: a bind failure stops only this child; the identity
      # plane (StsGate) and the app survive.
      Smalt.Identity.SamlIdp,
      # T05 (lane L17): OIDC IdP face (Bandit plug, :oidc_port default 9446,
      # :oidc_scheme :http|:https with the dev cert). Same one_for_one law.
      Smalt.Identity.OidcIdp
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end
end

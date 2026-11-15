defmodule Smalt.H18.PlaneTable do
  @moduledoc """
  Single declarative plane table. `Smalt.H18.Router` generates its dispatch
  clauses from this list at compile time and `GET /planes` reads the same
  list, so the inventory cannot drift from the routes.
  """

  @planes [
    %{prefix: "treasury", module: Smalt.Treasury.Router},
    %{prefix: "erp", module: Smalt.Erp.Router},
    %{prefix: "twilio", module: Smalt.Planes.Router.Twilio},
    %{prefix: "tax", module: Smalt.TaxSanctions.Http},
    %{prefix: "rates", module: Smalt.Rates.Http}
  ]

  def all, do: @planes
  def prefixes, do: Enum.map(@planes, & &1.prefix)

  def fetch(prefix), do: Enum.find(@planes, &(&1.prefix == prefix))

  @doc "Readiness: the plane's handler module is loadable and exports call/2."
  def ready?(%{module: m}), do: Code.ensure_loaded?(m) and function_exported?(m, :call, 2)
end

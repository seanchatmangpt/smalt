defmodule Smalt.Network.ExpressRouteCrossConnection do
  @moduledoc """
  Microsoft.Network/expressRouteCrossConnections (api-version 2026-03-01)

  Projected from the smalt ARM type ontology by `mix smalt.gen.ash`.
  DO NOT EDIT — regenerate with `mix smalt.gen.ash <ontology.ttl>`.
  """

  use Ash.Resource, domain: Smalt.Network, data_layer: Ash.DataLayer.Ets

  attributes do
    attribute(:arm_id, :string, primary_key?: true, allow_nil?: false)
    attribute(:name, :string)
    attribute(:location, :string)
    attribute(:tags, :map, default: %{})
    attribute(:properties, :map, default: %{})
    attribute(:provisioning_state, :string, default: "Succeeded")
  end

  actions do
    defaults([:read])
    read(:get_by_arm_id, get_by: [:arm_id])

    create :arm_put do
      accept([:arm_id, :name, :location, :tags, :properties])
      upsert?(true)
    end

    destroy(:arm_delete)
  end
end

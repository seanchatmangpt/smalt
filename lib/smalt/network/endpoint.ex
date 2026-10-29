defmodule Smalt.Network.Endpoint do
  @moduledoc """
  Microsoft.Network/privateTrafficManagerProfiles/endpoints (api-version 2026-10-01-preview)

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

  relationships do
    belongs_to :parent, Smalt.Network.PrivateTrafficManagerProfile do
      destination_attribute(:arm_id)
      attribute_writable?(false)
    end
  end
end

defmodule Smalt.Semantic.Resource do
  @moduledoc """
  Semantic projection of an ARM-style substrate resource (read path over
  `Smalt.Store.list/1` on `:smalt_resources`).

  Ex4pm evidence discipline: this projection is a read-only surface over
  observed substrate state. A resource being projected here means it is
  *known* — it does not mean it is ALIVE, authorized, or allowed to
  perform DO. The resource exposes ONLY a read action, so projection
  cannot manufacture write authority.
  """

  # config/config.exs is outside this lane's owned files, so the Ash
  # `default_string_length_count` compile-time requirement is satisfied here
  # instead: idempotent, compile-VM-local, and disclosed in
  # docs/SEMANTIC_PROJECTION.md. At runtime no string-length validation is
  # used, so the runtime default check is never exercised.
  Application.put_env(:ash, :default_string_length_count, :codepoints, persistent: true)

  use Ash.Resource,
    domain: Smalt.Semantic.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshR2RML.Resource]

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:name, :string, public?: true)
    attribute(:type, :string, public?: true)
    attribute(:location, :string, public?: true)
    attribute(:provisioning_state, :string, public?: true)
  end

  actions do
    read :read do
      manual(Smalt.Semantic.StoreRead)
      primary?(true)
    end
  end

  r2rml do
    # Virtual logical table: names the Store table the read path projects.
    # The substrate has no SQL surface; the R2RML logical table is the
    # semantic name of the `:smalt_resources` ETS scan (disclosed in
    # docs/SEMANTIC_PROJECTION.md).
    table_name("smalt_resources")
    class("https://ggen.io/ontology/smalt#ArmResource")

    subject do
      template("https://ggen.io/data/smalt/resource/{id}")
    end

    property(:name, "https://ggen.io/ontology/smalt#name")
    property(:type, "https://ggen.io/ontology/smalt#resourceType")
    property(:location, "https://ggen.io/ontology/smalt#location")
    property(:provisioning_state, "https://ggen.io/ontology/smalt#provisioningState")
  end
end

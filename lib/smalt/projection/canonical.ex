# Canonical public projection of the smalt capability registry (SMALT v26.10.14).
# Pattern carried over from ggen-marketplace packs (canonical-ash-projection-generator
# + xaas-public-ash-projection-pack): admitted surface only, rendered public map,
# zero internal state leakage. This file is NOT ggen-projected (the packs' query
# vocabulary — apg:* — does not match smalt's ontology vocabulary; see
# docs/PACK_INTEGRATION/canonical-projection.md). It derives from
# `Smalt.Registry`, which IS ggen-projected from the ontology — so the projection
# chain ontology -> Registry -> Canonical stays intact with no hand-typed truth.
defmodule Smalt.Projection.Canonical do
  @moduledoc """
  Canonical PUBLIC projection surface of `Smalt.Registry`.

  Emits a deterministic, secret-free capability document (types, SHACL shape
  bindings, api-versions, plane endpoints) intended to back `GET /capabilities`.
  Determinism matters: `docs/capability.json` is generated from this module and
  a fence test compares the committed artifact against Registry-derived truth so
  public docs cannot drift from the ontology projection.

  Public by construction: nothing from `Smalt.Store` (tables, keys, secrets)
  enters this surface — enforced by a grep fence in
  `test/canonical_projection_test.exs`.
  """

  @schema_version "v1"
  @doc_path "docs/capabilities.json"

  @doc "Relative path of the generated public capability document."
  def doc_path, do: @doc_path

  @doc """
  Registry-derived capability document (plain terms, deterministic order).
  Only Registry accessors are consulted — no Store, no env, no wall clock.
  """
  def capability_document do
    %{
      "schemaVersion" => @schema_version,
      "name" => "smalt",
      "capabilities" =>
        Enum.map(Smalt.Registry.admitted_resource_types(), fn type ->
          %{
            "type" => type,
            "shape" => Smalt.Registry.shape_for(type),
            "apiVersion" => Smalt.Registry.latest_version(type)
          }
        end),
      "endpoints" => %{
        "controlPlane" => Smalt.Registry.control_plane_port(),
        "dataPlane" => Smalt.Registry.data_plane_port(),
        # R83 disclosure: canonical defaults, not get_env — the capability
        # document is the env-independent substrate contract (drift fence
        # renders in test env where ports are dynamic).
        "amqp" => Smalt.Registry.amqp_port_default(),
        "eventHubs" => Smalt.Registry.event_hubs_port_default()
      }
    }
  end

  @doc "Rendered JSON (deterministic key order via Jason on sorted-key maps)."
  def json do
    capability_document() |> sort_keys() |> Jason.encode!(pretty: true, indent: "  ")
  end

  @doc "Write the generated capability document to #{@doc_path}."
  def write do
    path = Path.expand(@doc_path, File.cwd!())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json() <> "\n")
    {:ok, path}
  end

  defp sort_keys(term) when is_map(term) do
    term |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end) |> Map.new()
  end

  defp sort_keys(term) when is_list(term), do: Enum.map(term, &sort_keys/1)
  defp sort_keys(term), do: term
end

defmodule Smalt.Projection.Canonical.Entry do
  @moduledoc """
  (a) Ash read resource over the Registry (compile-time attrs).

  Read-only, simple data layer, manual read over compile-time Registry data —
  the same read-path pattern as `Smalt.Semantic.Resource`, but over the
  Registry (admitted capability surface) instead of Store state. A capability
  appearing here is *admitted*; it is not authority to actuate (Ex4pm
  discipline: observed != authorized).
  """

  use Ash.Resource,
    domain: Smalt.Projection.Canonical.Domain,
    data_layer: Ash.DataLayer.Simple

  attributes do
    attribute(:type, :string, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:shape, :string, public?: true)
    attribute(:api_version, :string, public?: true)
  end

  actions do
    read :read do
      manual(Smalt.Projection.Canonical.RegistryRead)
      primary?(true)
    end
  end
end

defmodule Smalt.Projection.Canonical.RegistryRead do
  @moduledoc """
  Manual read over compile-time Registry attrs (no Store involvement).
  """

  @behaviour Ash.Resource.ManualRead

  @impl true
  def read(_query_or_data_layer_query, _query, _opts, _context) do
    rows =
      Enum.map(Smalt.Registry.admitted_resource_types(), fn type ->
        %Smalt.Projection.Canonical.Entry{
          type: type,
          shape: Smalt.Registry.shape_for(type),
          api_version: Smalt.Registry.latest_version(type)
        }
        |> Ash.Resource.set_metadata(%{})
      end)

    {:ok, rows}
  end
end

defmodule Smalt.Projection.Canonical.Domain do
  @moduledoc """
  Domain for the canonical public projection surface. Separate from
  `Smalt.Semantic.Domain` (which owns the Store read path) so the public
  surface can never inherit a Store-backed action.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Smalt.Projection.Canonical.Entry)
  end
end

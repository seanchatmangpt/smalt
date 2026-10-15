defmodule Smalt.AshExtension.SubstrateResource.ManualRead do
  @moduledoc """
  Generic Store-backed manual read for `substrate_resource` extensions.

  This module is HAND-ADAPTED (disclosed): the ash-extension-pack templates
  manufacture the extension/transformer/verifier/Info family from an
  `aex:AshExtensionSpec`, but no template in the pack covers the
  `Ash.Resource.ManualRead` behaviour, so this module adapts the repo's existing
  Store-read idiom (`Smalt.Semantic.StoreRead`) to the extension's compiled
  configuration instead of the per-resource hardcoded match in
  `lib/smalt/semantic/store_read.ex`.

  Contract (same as the semantic projection):

    * NO second store — the read scans the substrate's own `Smalt.Store` ETS
      table named by the resource's `substrate do store_table ... end` block.
    * Row projection contract: for every Ash attribute on the resource, the row
      map's value under the matching atom or string key is projected; absent
      keys project as nil.
    * Matter-scope: the resource's declared `matter_scope` tags are projected
      into each record's `__metadata__`, so downstream surfaces can enforce the
      matter-isolation law without re-deriving the scope.
  """

  @behaviour Ash.Resource.ManualRead

  alias Smalt.AshExtension.SubstrateResource.Info
  alias Smalt.Store

  @impl true
  def read(_data_layer_query, query, _opts, _context) do
    case Info.store_table_result(query.resource) do
      {:ok, table} ->
        rows = Store.list(table)

        {:ok, Enum.map(rows, fn row -> build(query.resource, row) end)}

      {:error, reason} ->
        {:error,
         "substrate_resource: #{inspect(query.resource)} has no compiled store_table " <>
           "(#{inspect(reason)}) -- extension not applied or verifier never ran"}
    end
  end

  defp build(resource, row) when is_map(row) do
    attrs =
      resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(fn attr ->
        name = attr.name

        {name,
         Map.get(row, name) || Map.get(row, Atom.to_string(name))}
      end)

    metadata =
      case Info.matter_scope_result(resource) do
        {:ok, scopes} -> %{matter_scope: scopes}
        :error -> %{}
      end

    resource
    |> struct(attrs)
    |> Ash.Resource.set_metadata(metadata)
  end
end
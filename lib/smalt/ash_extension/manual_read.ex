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

        case Enum.find(rows, &(!is_map(&1))) do
          nil ->
            # Lens-3 cycle 5: same vacuous-identity class as
            # Smalt.Semantic.StoreRead (lens-3 cycle 2) — struct/2 does not
            # enforce allow_nil?, so a row with a nil or blank primary key
            # projected an identity-less Ash struct. Fence on the resource's
            # compiled primary-key attributes; refuse typed.
            pk_names = primary_key_names(query.resource)

            case Enum.find(rows, fn row ->
                   Enum.any?(pk_names, fn k ->
                     not identity?(Map.get(row, k) || Map.get(row, Atom.to_string(k)))
                   end)
                 end) do
              nil ->
                {:ok, Enum.map(rows, fn row -> build(query.resource, row) end)}

              bad_row ->
                {:error,
                 "substrate_resource: vacuous identity under #{inspect(table)} " <>
                   "(primary key #{inspect(pk_names)} = #{inspect(bad_row)}) — refusing read " <>
                   "instead of projecting an identity-less row"}
            end

          bad ->
            # Lens-2 cycle 4: Store is an untyped key-value table; a
            # non-map value under a substrate key crashed the WHOLE Ash
            # read with FunctionClauseError (the boundary crash class
            # lens-1 closed at the ledger boundaries). Same discipline:
            # a malformed row refuses the read typed — never a crash,
            # never a silent skip.
            {:error,
             "substrate_resource: non-map Store row under #{inspect(table)} " <>
               "(#{inspect(bad)}) — refusing read instead of projecting garbage"}
        end

      {:error, reason} ->
        {:error,
         "substrate_resource: #{inspect(query.resource)} has no compiled store_table " <>
           "(#{inspect(reason)}) -- extension not applied or verifier never ran"}
    end
  end

  defp primary_key_names(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(& &1.primary_key?)
    |> Enum.map(& &1.name)
  end

  # Lens-4 cycle 1: identity?/1 generalizes to Smalt.Projection.Identity
  # (whitespace-only / invisible-format-only ids carry zero visible
  # identity bits).
  defp identity?(id), do: Smalt.Projection.Identity.valid?(id)

  defp build(resource, row) when is_map(row) do
    attrs =
      resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(fn attr ->
        name = attr.name

        {name, field_value(attr, Map.get(row, name) || Map.get(row, Atom.to_string(name)))}
      end)

    metadata =
      case Info.matter_scope_result(resource) do
        {:ok, scopes} -> %{matter_scope: scopes}
        # generated_info.ex's matter_scope_result/1 returns
        # {:ok, matter_scope} | {:error, :not_found} — never bare :error.
        {:error, _} -> %{}
      end

    resource
    |> struct(attrs)
    |> Ash.Resource.set_metadata(metadata)
  end

  # Lens-7 cycle 5: field-VALUE policy, same as Smalt.Semantic.StoreRead
  # (cycle 3): row structure + identity refuse typed; a non-conformant
  # VALUE under a declared :string attribute follows the lenient-nil
  # precedent — it projects nil, never a raw type-lie (witnessed there:
  # a list passed through RAW into a String.t() attribute). Non-string
  # attribute types project their raw value unchanged (their type contract
  # is the resource's own, not this read path's).
  defp field_value(%{type: Ash.Type.String}, v), do: bin_or_nil(v)
  defp field_value(%{type: :string}, v), do: bin_or_nil(v)
  defp field_value(_attr, v), do: v

  defp bin_or_nil(v) when is_binary(v), do: v
  defp bin_or_nil(_), do: nil
end

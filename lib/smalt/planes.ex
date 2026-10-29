defmodule Smalt.Planes do
  @moduledoc """
  Plane selection + validation (AZB-04, lane planes).

  `SMALT_PLANES` (comma list) or `config :smalt, :planes, [...]`; default
  `:all` (today's boot, byte-identical). Selection is resolved at runtime
  config time (config/runtime.exs) — releases honor it. The parsed list is
  written back to `Application` env `:planes`, so `Smalt.Config.planes()`
  is the single read surface.

  With `:all` no `config/env/az_prod_<plane>.exs` profile is imported:
  profiles are opt-in per explicitly selected plane. This keeps the default
  boot byte-identical to the pre-AZB-04 behavior (AZB-04 falsifier).

  Unknown plane name ⇒ boot refuses with `{:invalid_plane, name}` via
  `Smalt.Planes.InvalidPlane`.
  """

  @known [:control, :data, :integration, :identity]

  defmodule InvalidPlane do
    @moduledoc false
    defexception [:plane]

    @known [:control, :data, :integration, :identity]

    @impl true
    def message(%__MODULE__{plane: plane}) do
      # Renders the refusal exactly in the ticket vocabulary: {:invalid_plane, name}
      "{:invalid_plane, #{inspect(plane)}} (known planes: #{inspect(@known)})"
    end
  end

  @doc "Known plane names."
  def known, do: @known

  @doc """
  Resolve the plane selection from SMALT_PLANES / app env :planes, validating
  every name. Returns `:all` or a list of known plane atoms.
  """
  def resolve do
    case raw() do
      :all -> :all
      names when is_list(names) ->
        # EXPL-11 F4: an empty selection boots zero plane surfaces — a
        # "successful" emulator with no planes. Refuse typed, like an
        # unknown name.
        case names do
          [] -> raise InvalidPlane, plane: []
          _ -> Enum.map(names, &validate/1)
        end

      csv when is_binary(csv) -> parse_csv(csv)
      other -> raise InvalidPlane, plane: other
    end
  end

  defp raw do
    case System.get_env("SMALT_PLANES") do
      nil -> Application.get_env(:smalt, :planes, :all)
      "" -> :all
      csv -> csv
    end
  end

  defp parse_csv(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&validate_name(String.trim(&1)))
  end

  # JA-R1 (V1): validate against the known plane set BEFORE any atomize —
  # malformed SMALT_PLANES input must refuse with {:invalid_plane, name}
  # without minting an arbitrary atom at boot.
  @known_strings Enum.map(@known, &Atom.to_string/1)

  defp validate_name(name) when name in @known_strings, do: String.to_existing_atom(name)

  defp validate_name(name), do: raise(InvalidPlane, plane: name)

  defp validate(name) when name in @known, do: name

  defp validate(name), do: raise(InvalidPlane, plane: name)
end

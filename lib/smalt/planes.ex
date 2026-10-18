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
      names when is_list(names) -> Enum.map(names, &validate/1)
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
    |> Enum.map(&validate(atomize(String.trim(&1))))
  end

  defp atomize(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> String.to_atom(name)
  end

  defp validate(name) when name in @known, do: name

  defp validate(name), do: raise(InvalidPlane, plane: name)
end

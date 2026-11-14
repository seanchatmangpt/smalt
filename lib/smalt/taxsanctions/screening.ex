defmodule Smalt.TaxSanctions.Screening do
  @moduledoc "OFAC SDN / Consolidated Screening List match over a caller-supplied list."

  @doc "list entries: %{id, name, aliases, program}. Hits sorted by score desc."
  def screen(name, list, threshold \\ 0.85) when is_binary(name) do
    q = tokens(name)

    list
    |> Enum.flat_map(fn e ->
      best = [e.name | Map.get(e, :aliases, [])] |> Enum.map(&score(q, tokens(&1))) |> Enum.max()
      if best >= threshold, do: [%{id: e.id, name: e.name, program: e.program, score: best}], else: []
    end)
    |> Enum.sort_by(&(-&1.score))
  end

  def result(name, list, threshold \\ 0.85) do
    case screen(name, list, threshold) do
      [] -> %{status: :clear, hits: []}
      hits -> %{status: :potential_match, hits: hits}
    end
  end

  defp score([], _), do: 0.0
  defp score(_, []), do: 0.0

  defp score(a, b) do
    sa = MapSet.new(a)
    sb = MapSet.new(b)
    MapSet.size(MapSet.intersection(sa, sb)) / MapSet.size(MapSet.union(sa, sb))
  end

  defp tokens(s) do
    s |> String.normalize(:nfd) |> String.replace(~r/\p{Mn}/u, "") |> String.upcase()
    |> String.replace(~r/[^A-Z0-9 ]/, " ") |> String.split(" ", trim: true)
  end
end

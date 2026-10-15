defmodule Smalt.GraphLaw.NtSerializer do
  @moduledoc """
  Deterministic map -> N-Triples text.

  Used by the wasm/ash_graphlaw fast-path to feed a byte-stable payload graph
  to the engine. Every call with semantically equal input produces the exact
  same bytes: keys are sorted, arrays become repeated triples preserving array
  order, nested maps recurse via dotted-path predicates.

  * subject: `<urn:smalt:payload>`
  * predicates: `<https://ggen.io/ontology/smalt#dotted.path>`
  * arrays: one triple per element, in array order
  * strings -> plain literals, integers -> xsd:integer, floats -> xsd:decimal,
    booleans -> xsd:boolean
  * `nil` values are skipped entirely (absence carries no triple)
  """

  @subject "<urn:smalt:payload>"
  @ns "https://ggen.io/ontology/smalt#"
  @xsd "http://www.w3.org/2001/XMLSchema#"

  @doc "Serialize a payload map to deterministic N-Triples text."
  @spec serialize(map()) :: String.t()
  def serialize(payload) when is_map(payload) do
    payload
    |> triples([])
    |> Enum.sort()
    |> Enum.map(&line/1)
    |> Enum.join("\n")
    |> append_trailing_newline()
  end

  defp append_trailing_newline(""), do: ""
  defp append_trailing_newline(text), do: text <> "\n"

  defp triples(map, prefix) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.flat_map(fn {k, v} -> triples(v, prefix ++ [to_string(k)]) end)
  end

  defp triples(list, path) when is_list(list) do
    Enum.flat_map(list, &triples(&1, path))
  end

  defp triples(nil, _path), do: []

  defp triples(value, path), do: [{@subject, path_to_iri(path), literal(value)}]

  defp path_to_iri(path), do: "<" <> @ns <> Enum.join(path, ".") <> ">"

  defp literal(value) when is_binary(value), do: inspect(value)
  defp literal(value) when is_integer(value), do: typed(value, "integer")
  defp literal(value) when is_float(value), do: typed(value, "decimal")

  defp literal(true), do: typed("true", "boolean")
  defp literal(false), do: typed("false", "boolean")
  defp literal(value), do: inspect(to_string(value))

  defp typed(value, type), do: ~s("#{value}"^^<#{@xsd}#{type}>)

  defp line({s, p, o}), do: s <> " " <> p <> " " <> o <> " ."
end

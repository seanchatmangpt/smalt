defmodule Smalt.Rates.OpenCorporates do
  @moduledoc "OpenCorporates twin: parent-subsidiary tree (corporate_groupings shape)."

  # {company_number, name, parent_number | nil}
  @nodes [
    {"US-001", "Example Holdings Inc.", nil},
    {"US-002", "Example Capital LLC", "US-001"},
    {"US-003", "Example Auto Receivables LLC", "US-002"},
    {"GB-101", "Example UK Ltd", "US-001"}
  ]

  def tree(root \\ "US-001") do
    case Enum.find(@nodes, fn {n, _, _} -> n == root end) do
      nil -> {:error, :not_found}
      {n, name, _} -> {:ok, node(n, name)}
    end
  end

  def descendants(root \\ "US-001") do
    with {:ok, t} <- tree(root), do: {:ok, flatten(t["children"])}
  end

  defp node(n, name) do
    kids = for {cn, cname, parent} <- @nodes, parent == n, do: node(cn, cname)

    %{
      "company_number" => n,
      "name" => name,
      "jurisdiction_code" => n |> String.slice(0, 2) |> String.downcase(),
      "children" => kids
    }
  end

  defp flatten(kids), do: Enum.flat_map(kids, fn k -> [k["company_number"] | flatten(k["children"])] end)
end

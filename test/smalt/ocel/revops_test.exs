defmodule Smalt.Ocel.RevOpsTest do
  @moduledoc """
  C9 lane court for `Smalt.Ocel.RevOps.trace_groups/1` — the cons + single
  reverse at materialization must preserve source event order within each
  trace, and first-appearance group order.
  """

  use ExUnit.Case, async: false

  alias Smalt.Ocel.RevOps

  defp ev(rel_id, extra \\ %{}) do
    Map.merge(
      %{"relationships" => [%{"objectId" => rel_id} | rest_rels(extra)]},
      Map.drop(extra, [:rel])
    )
  end

  defp rest_rels(%{rel: ids}), do: Enum.map(ids, &%{"objectId" => &1})
  defp rest_rels(_), do: []

  test "groups by first relationship objectId; group order = first appearance" do
    doc = %{
      "ocel:events" => [
        ev("b", %{"i" => 1}),
        ev("a", %{"i" => 2}),
        ev("b", %{"i" => 3}),
        ev("c", %{"i" => 4})
      ]
    }

    groups = RevOps.trace_groups(doc)
    assert Enum.map(groups, &elem(&1, 0)) == ["b", "a", "c"]
    assert Enum.map(groups, &length(elem(&1, 1))) == [2, 1, 1]
  end

  test "within-trace event order follows source order (cons+reverse law)" do
    doc = %{
      "ocel:events" => [
        ev("t", %{"n" => 1}),
        ev("t", %{"n" => 2}),
        ev("t", %{"n" => 3}),
        ev("t", %{"n" => 4})
      ]
    }

    [{_, events}] = RevOps.trace_groups(doc)
    assert Enum.map(events, & &1["n"]) == [1, 2, 3, 4]
  end

  test "events without relationships become positional singleton traces" do
    doc = %{
      "ocel:events" => [
        %{"ocel:activity" => "orphan-1"},
        ev("k", %{"n" => 2}),
        %{"ocel:activity" => "orphan-2"}
      ]
    }

    groups = RevOps.trace_groups(doc)
    keys = Enum.map(groups, &elem(&1, 0))
    assert keys == ["trace-0", "k", "trace-2"]
    assert Enum.all?(groups, fn {_, es} -> length(es) == 1 end)
  end

  test "empty/missing first objectId falls under the positional key" do
    doc = %{
      "ocel:events" => [
        %{"relationships" => [%{"objectId" => ""}]},
        %{"relationships" => []}
      ]
    }

    groups = RevOps.trace_groups(doc)
    assert Enum.map(groups, &elem(&1, 0)) == ["trace-0", "trace-1"]
  end

  test "non-map document -> []" do
    assert RevOps.trace_groups(%{}) == []
    assert RevOps.trace_groups(nil) == []
  end
end

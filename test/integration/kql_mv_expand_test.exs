# Integration-tier witness (T-05 increments 3+4, v26.10.28): KQL mv-expand
# and cross-workspace workspace("id") sources.

defmodule Smalt.Internal.KqlMvExpandTest do
  use ExUnit.Case, async: true

  alias Smalt.DataPlane.KQL

  @rows [
    %{"Name" => "one", "Tags" => ["a", "b"], "Nums" => [1, 2]},
    %{"Name" => "two", "Tags" => ["c"], "Nums" => [3]},
    %{"Name" => "three", "Tags" => "not-a-list", "Nums" => nil}
  ]

  test "single column: one row per element, other columns duplicated" do
    assert {:ok, rows} = KQL.run(@rows, "| mv-expand Tags")

    tags = Enum.map(rows, & &1["Tags"])
    # not-a-list wraps to a singleton (Kusto treats scalars as singletons).
    assert tags == ["a", "b", "c", "not-a-list"]
    assert Enum.all?(rows, &is_binary(&1["Name"]))
    assert Enum.at(rows, 0)["Name"] == "one"
  end

  test "multiple columns expand element-wise (zip, not cartesian)" do
    assert {:ok, rows} = KQL.run(@rows, "| mv-expand Tags, Nums")

    pairs = Enum.map(rows, &{&1["Tags"], &1["Nums"]})
    assert Enum.take(pairs, 3) == [{"a", 1}, {"b", 2}, {"c", 3}]
    assert {"not-a-list", nil} in pairs
  end

  test "mv-expand composes downstream with summarize" do
    assert {:ok, rows} = KQL.run(@rows, "| mv-expand Tags | summarize count() by Tags")

    counts = Map.new(rows, fn row -> {row["Tags"], row["count_"]} end)
    assert counts == %{"a" => 1, "b" => 1, "c" => 1, "not-a-list" => 1}
  end

  test "mv-expand without a column refuses" do
    assert {:error, {:parse, msg}} = KQL.run(@rows, "| mv-expand | take 1")
    assert msg =~ "SYN"
  end

  test "mv-expand with a non-word token refuses SYN0002" do
    # A string literal is not a column reference — typed refusal. (A bare
    # number like 5 lexes as a WORD in this engine and is a column name,
    # same as everywhere else, so it is not a refusal case.)
    assert {:error, {:parse, msg}} = KQL.run(@rows, ~S(| mv-expand "lit"))
    assert msg =~ "SYN0002"
  end
end

defmodule Smalt.Internal.KqlWorkspaceTest do
  use ExUnit.Case, async: true

  alias Smalt.DataPlane.KQL

  @ws_a [%{"tenantId" => "t1"}, %{"tenantId" => "t2"}]
  @ws_b [%{"tenantId" => "t2"}, %{"tenantId" => "t3"}]
  @tables %{"ws-a" => @ws_a, "ws-b" => @ws_b, "ws-a.Perf" => [%{"tenantId" => "t9"}]}

  test "cross-workspace: union stamped with the Workspace column" do
    assert {:ok, rows} =
             KQL.run(
               [],
               ~S{workspace("ws-a"), workspace("ws-b") | summarize count() by Workspace},
               @tables
             )

    counts = Map.new(rows, fn row -> {row["Workspace"], row["count_"]} end)
    assert counts == %{"ws-a" => 2, "ws-b" => 2}
  end

  test "workspace with .Table suffix resolves the table key" do
    assert {:ok, rows} =
             KQL.run([], ~S{workspace("ws-a").Perf | take 1}, @tables)

    assert [%{"Workspace" => "ws-a", "tenantId" => "t9"}] = rows
  end

  test "missing workspace is a typed eval error" do
    assert {:error, {:eval, msg}} = KQL.run([], ~S{workspace("nope") | take 1}, @tables)
    assert msg =~ "nope"
  end

  test "workspace sources must be followed by a pipe (fail-closed)" do
    assert {:error, {:parse, msg}} = KQL.run([], ~S{workspace("ws-a") take 1}, @tables)
    assert msg =~ "SYN0002"
  end

  test "no leading workspace clause is fully backward compatible" do
    assert {:ok, rows} = KQL.run(@ws_a, "| take 1")
    assert length(rows) == 1
  end
end

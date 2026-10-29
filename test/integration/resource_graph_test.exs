defmodule SmaltTest.Integration.ResourceGraphTest do
  @moduledoc """
  AZURE-FIDELITY lane 3 — Resource Graph surface over the real Store.

  Real queries against seeded `:smalt_resources` rows (Chicago: real store, real
  evaluator, no mocks) through the arm_gateway seam
  (`Smalt.ArmGateway.ResourceGraph.query/2`): projection, where-comparisons,
  order+top, count() aggregate, `$skipToken` pagination, subscription scoping,
  and typed clause-whitelist refusals.
  """

  use ExUnit.Case, async: false

  alias Smalt.ArmGateway.ResourceGraph
  alias Smalt.Store

  @sub "00000000-0000-0000-0000-0000000000rg"
  @rg "rg-graph-lane3"

  setup context do
    resources = [
      %{
        "id" => res_id("disk", "disk-b"),
        "name" => "disk-b",
        "type" => "Microsoft.Compute/disks",
        "location" => "westus",
        "priority" => 1,
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{"env" => "prod"}
      },
      %{
        "id" => res_id("disk", "disk-a"),
        "name" => "disk-a",
        "type" => "Microsoft.Compute/disks",
        "location" => "eastus",
        "priority" => 2,
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{"env" => "dev"}
      },
      %{
        "id" => res_id("sa", "sagraph"),
        "name" => "sagraph",
        "type" => "Microsoft.Storage/storageAccounts",
        "location" => "eastus",
        "priority" => 3,
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{"env" => "prod"}
      },
      %{
        "id" => res_id("vault", "kv-graph"),
        "name" => "kv-graph",
        "type" => "Microsoft.KeyVault/vaults",
        "location" => "westus",
        "priority" => 4,
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{}
      }
    ]

    Enum.each(resources, fn r -> Store.put(:smalt_resources, r["id"], r) end)

    on_exit(fn ->
      Enum.each(resources, fn r -> Store.delete(:smalt_resources, r["id"]) end)
    end)

    {:ok, resources: resources, test: context.test}
  end

  defp res_id(kind, name) do
    String.downcase(
      "/subscriptions/#{@sub}/resourcegroups/#{@rg}/providers/microsoft.storage/#{kind}/#{name}"
    )
  end

  defp run(query, opts \\ %{}) do
    ResourceGraph.query(
      %{"query" => query, "options" => opts, "subscriptions" => [@sub]},
      "2022-10-01"
    )
  end

  # -- Envelope + projection ---------------------------------------------------

  test "project name and location returns exactly those columns with envelope" do
    {:ok, 200, env} = run("| project name, location")

    # 2022-10-01 envelope: count/data/facets/$skipToken — no totalRecords key.
    assert Map.has_key?(env, "totalRecords") == false
    assert env["count"] == length(env["data"])

    # V20b: id is the row's identity — real ResourceGraph never drops it, so a
    # `project` that omits it gets it re-stamped from the stored record; the
    # projected data columns stay exactly the requested ones.
    assert Enum.all?(env["data"], fn row ->
             Map.keys(row) |> Enum.sort() == ["id", "location", "name"]
           end)

    names = Enum.map(env["data"], & &1["name"]) |> Enum.sort()
    assert "disk-a" in names and "disk-b" in names and "sagraph" in names and "kv-graph" in names
  end

  test "V20b: every row carries the stored record's ARM id, default and projected", %{
    resources: resources
  } do

    # Default (unprojected) scan: rows carry id matching the stored record.
    {:ok, 200, default_env} = run("")
    stored_by_name = Map.new(resources, fn r -> {r["name"], r["id"]} end)

    assert Enum.all?(default_env["data"], fn row ->
             row["id"] == Map.fetch!(stored_by_name, row["name"])
           end)

    # Projected name-only: the requested column is honored and no other data
    # column leaks (location/properties/tags stay off the row); id remains.
    {:ok, 200, env} = run("| project name")


    assert Enum.all?(env["data"], fn row ->
             Map.keys(row) |> Enum.sort() == ["id", "name"] and
               row["id"] == Map.fetch!(stored_by_name, row["name"])
           end)
  end

  test "V20b: aggregate rows are never stamped with a fabricated id" do
    {:ok, 200, env} = run("| summarize count()")

    assert [%{"count_" => _} = agg] = env["data"]
    refute Map.has_key?(agg, "id")
  end

  # -- where --------------------------------------------------------------------

  test "where type == filters to matching type" do
    {:ok, 200, env} = run("| where type == 'Microsoft.Storage/storageAccounts'")

    assert [%{"name" => "sagraph"}] = env["data"]
    assert env["count"] == 1
  end

  test "where type =~ is case-insensitive equality" do
    {:ok, 200, env} = run("| where type =~ 'microsoft.compute/disks'")

    assert length(env["data"]) == 2
    assert Enum.all?(env["data"], fn r -> r["type"] == "Microsoft.Compute/disks" end)
  end

  test "where name contains matches substring case-insensitively" do
    {:ok, 200, env} = run("| where name contains 'graph'")

    names = Enum.map(env["data"], & &1["name"]) |> Enum.sort()
    assert names == ["kv-graph", "sagraph"]
  end

  test "numeric comparison filters on a numeric column" do
    {:ok, 200, env} = run("| where priority >= 3")

    names = Enum.map(env["data"], & &1["name"]) |> Enum.sort()
    assert names == ["kv-graph", "sagraph"]
  end

  test "!= excludes the matched row" do
    {:ok, 200, env} = run("| where type != 'Microsoft.Compute/disks'")

    refute Enum.any?(env["data"], fn r -> r["type"] == "Microsoft.Compute/disks" end)
    assert env["count"] == 2
  end

  # -- order by + top ------------------------------------------------------------

  test "order by name desc with $top 2 returns the page and full count" do
    {:ok, 200, env} = run("| order by name desc", %{"$top" => 2})

    assert Enum.map(env["data"], & &1["name"]) == ["sagraph", "kv-graph"]
    assert env["count"] == 2
    assert env["resultTruncated"] == false
    # A second page remains -> $skipToken present.
    assert is_binary(env["$skipToken"])
  end

  test "order by asc sorts numerically on priority" do
    {:ok, 200, env} = run("| order by priority asc | project name, priority")

    assert Enum.map(env["data"], & &1["name"]) == ["disk-b", "disk-a", "sagraph", "kv-graph"]
  end

  # -- count() aggregate -----------------------------------------------------------

  test "summarize count() returns one row with count_" do
    {:ok, 200, env} = run("| summarize count()")

    assert env["count"] == 1
    assert [%{"count_" => 4}] = env["data"]
  end

  test "count() after where reflects the filtered set" do
    {:ok, 200, env} = run("| where location == 'westus' | summarize count()")

    assert [%{"count_" => 2}] = env["data"]
  end

  # -- facets -----------------------------------------------------------------------

  test "facet buckets the result set by tags.env" do
    {:ok, 200, env} =
      ResourceGraph.query(
        %{
          "query" => "| project name, tags",
          "facets" => [%{"expression" => "tags.env", "options" => %{"top" => 5}}],
          "subscriptions" => [@sub]
        },
        "2022-10-01"
      )

    assert [facet] = env["facets"]
    assert facet["expression"] == "tags.env"
    assert %{"count" => 2, "value" => "prod"} = Enum.find(facet["data"], &(&1["value"] == "prod"))
  end

  # -- pagination via $skipToken -------------------------------------------------

  test "pagination walks all rows via $skipToken without $top on continuation" do
    {:ok, 200, page1} = run("", %{"$top" => 2})
    assert page1["count"] == 2
    token = page1["$skipToken"]
    assert is_binary(token)

    {:ok, 200, page2} = run("", %{"$skipToken" => token})
    assert page2["count"] == 2
    # Pages are disjoint and together cover the set.
    n1 = MapSet.new(Enum.map(page1["data"], & &1["id"]))
    n2 = MapSet.new(Enum.map(page2["data"], & &1["id"]))
    assert MapSet.size(MapSet.union(n1, n2)) == 4
  end

  # -- subscription scoping ---------------------------------------------------------

  test "foreign subscription filter yields zero rows" do
    {:ok, 200, env} =
      ResourceGraph.query(
        %{"query" => "", "subscriptions" => ["ffffffff-ffff-ffff-ffff-ffffffffffff"]},
        "2022-10-01"
      )

    assert env["count"] == 0
    assert env["data"] == []
  end

  # -- query-gate refusals (typed, clause named) ----------------------------------

  test "unsupported clause is a typed 400 naming the clause" do
    {:error, 400, err} = run("| mv-expand tags.env")

    assert %{"error" => %{"code" => "UnsupportedClause", "message" => msg}} = err
    assert msg =~ "mv-expand"
    assert msg =~ "supported clauses:"
  end

  test "another unsupported clause (union) is refused with the clause named" do
    {:error, 400, err} = run("| union (Resources)")

    assert %{"error" => %{"code" => "UnsupportedClause", "message" => msg}} = err
    assert msg =~ "union"
  end

  test "bare table reference 'Resources' is admitted as an unfiltered scan" do
    {:ok, 200, env} = run("Resources")

    assert env["count"] >= 4
  end

  test "unterminated string literal is a typed 400 BadQuery" do
    {:error, 400, err} = run("| where type == 'unterminated")

    assert %{"error" => %{"code" => "BadQuery", "message" => msg}} = err
    assert msg =~ "unterminated"
  end

  test "unsupported evaluator-level operator (extend accepted; unknown refused)" do
    # extend is admitted by the gate and evaluated by the evaluator.
    {:ok, 200, env} = run("| extend Double = priority * 2 | project name, Double")

    assert Enum.all?(env["data"], fn row -> Map.has_key?(row, "Double") end)

    # An unknown pipeline operator is refused by the gate itself, typed with
    # the clause named (fail-closed, never 500).
    {:error, 400, err} = run("| frobnicate x")
    assert %{"error" => %{"code" => "UnsupportedClause", "message" => msg}} = err
    assert msg =~ "frobnicate"
  end

  # -- api-version gate ---------------------------------------------------------------

  test "wrong api-version is a typed 400 InvalidApiVersion" do
    {:error, 400, err} =
      ResourceGraph.query(%{"query" => ""}, "2019-04-01")

    assert %{"error" => %{"code" => "InvalidApiVersion", "message" => msg}} = err
    assert msg =~ "2022-10-01"
  end

  test "non-map body behaves like an empty envelope, not a 500" do
    {:ok, 200, env} = ResourceGraph.query(nil, "2022-10-01")

    assert Map.has_key?(env, "totalRecords") == false
  end
end

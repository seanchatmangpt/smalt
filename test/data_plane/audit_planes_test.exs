defmodule Smalt.DataPlane.AuditPlanesTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.{Purview, ResourceGraph, Sentinel}
  alias Smalt.Store

  setup do
    case Store.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Store.clear()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Sentinel
  # ---------------------------------------------------------------------------

  describe "Sentinel ingest" do
    test "ingests rows with seq and registers the stream" do
      # Real Log Analytics DCR ingest answers 204 No Content (x-ms-request-id
      # rides the HTTP response headers at the router seam).
      assert {:ok, 204, ""} = Sentinel.ingest("dcr-1", "Custom-Logs", [%{"msg" => "a"}, %{"msg" => "b"}], "2023-01-01")

      assert {:ok, stream} = Store.get(:smalt_sentinel_streams, "dcr-1/Custom-Logs")
      assert stream["dcr"] == "dcr-1"

      keys = Store.list_prefix(:smalt_sentinel_rows, "dcr-1/Custom-Logs/") |> length()
      assert keys == 2

      assert {:ok, _} = Store.get(:smalt_sentinel_rows, "dcr-1/Custom-Logs/" <> String.pad_leading("1", 20, "0"))
      assert {:ok, _} = Store.get(:smalt_sentinel_rows, "dcr-1/Custom-Logs/" <> String.pad_leading("2", 20, "0"))
    end

    test "continues seq numbering across ingests" do
      Sentinel.ingest("dcr-1", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")
      Sentinel.ingest("dcr-1", "Custom-Logs", [%{"msg" => "b"}], "2023-01-01")

      assert {:ok, row} = Store.get(:smalt_sentinel_rows, "dcr-1/Custom-Logs/" <> String.pad_leading("2", 20, "0"))
      assert row["msg"] == "b"
    end

    test "rejects wrong or missing api-version with 400" do
      assert {:error, 400, %{"error" => %{"code" => "InvalidApiVersion"}}} =
               Sentinel.ingest("dcr-1", "Custom-Logs", [%{}], "2022-01-01")

      assert {:error, 400, %{"error" => _}} = Sentinel.ingest("dcr-1", "Custom-Logs", [%{}], nil)
    end

    test "augments every row with the five string columns" do
      {:ok, 204, ""} =
        Sentinel.ingest("dcr-1", "Custom-Logs", [%{"msg" => "a", "subject" => "alice"}], "2023-01-01")

      {:ok, row} = Store.get(:smalt_sentinel_rows, "dcr-1/Custom-Logs/" <> String.pad_leading("1", 20, "0"))

      for col <- ~w(ledgerId tenantId subjectSha256 eventId sha256Hash) do
        assert is_binary(row[col]), "expected #{col} to be a string, got: #{inspect(row[col])}"
      end

      expected_hash =
        :crypto.hash(:sha256, Sentinel.canonical_json(%{"msg" => "a", "subject" => "alice"}))
        |> Base.encode16(case: :lower)

      assert row["sha256Hash"] == expected_hash
      assert row["subjectSha256"] == Base.encode16(:crypto.hash(:sha256, "alice"), case: :lower)
    end

    test "existing five columns are preserved" do
      {:ok, 204, ""} =
        Sentinel.ingest("dcr-1", "Custom-Logs", [%{"tenantId" => "my-tenant"}], "2023-01-01")

      {:ok, row} = Store.get(:smalt_sentinel_rows, "dcr-1/Custom-Logs/" <> String.pad_leading("1", 20, "0"))
      assert row["tenantId"] == "my-tenant"
    end
  end

  describe "Sentinel query" do
    test "returns PrimaryResult envelope with stored rows" do
      Sentinel.ingest("ws-1", "Custom-Logs", [%{"msg" => "a"}, %{"msg" => "b"}], "2023-01-01")

      {:ok, 200, resp} = Sentinel.query("ws-1", %{"query" => "Custom-Logs | take 10"})

      assert [%{"name" => "PrimaryResult", "columns" => columns, "rows" => rows}] = resp["tables"]
      assert %{"name" => "sha256Hash", "type" => "string"} in columns
      assert length(rows) == 2
    end

    test "take limit caps rows at N (max 101)" do
      rows = Enum.map(1..150, fn i -> %{"msg" => "row-#{i}"} end)
      Sentinel.ingest("ws-1", "Custom-Logs", rows, "2023-01-01")

      {:ok, 200, resp} = Sentinel.query("ws-1", %{"query" => "Custom-Logs | take 5"})
      assert length(hd(resp["tables"])["rows"]) == 5

      {:ok, 200, resp} = Sentinel.query("ws-1", %{"query" => "Custom-Logs | take 1000"})
      assert length(hd(resp["tables"])["rows"]) == 101
    end

    test "empty result -> rows []" do
      {:ok, 200, resp} = Sentinel.query("ws-unknown", %{"query" => "Custom-Logs"})

      assert [%{"name" => "PrimaryResult", "rows" => []}] = resp["tables"]
    end

    test "where filters on eventId via KQL engine" do
      rows = [%{"msg" => "hit", "eventId" => "x"}, %{"msg" => "miss", "eventId" => "y"}]
      Sentinel.ingest("ws-kql", "Custom-Logs", rows, "2023-01-01")

      {:ok, 200, resp} = Sentinel.query("ws-kql", %{"query" => "Custom-Logs | where eventId == 'x'"})

      table = hd(resp["tables"])
      assert table["name"] == "PrimaryResult"
      assert cell_column(table, "eventId") == ["x"]
    end

    test "where + order by + take pipeline" do
      rows = [
        %{"eventId" => "e1", "msg" => "a"},
        %{"eventId" => "e2", "msg" => "b"},
        %{"eventId" => "e3", "msg" => "c"},
        %{"eventId" => "e4", "msg" => "d"}
      ]

      Sentinel.ingest("ws-kql", "Custom-Logs", rows, "2023-01-01")

      {:ok, 200, resp} =
        Sentinel.query("ws-kql", %{
          "query" => "Custom-Logs | where eventId != 'e1' | order by eventId desc | take 2"
        })

      assert cell_column(hd(resp["tables"]), "eventId") == ["e4", "e3"]
    end

    test "malformed pipeline -> 400 BadQuery" do
      Sentinel.ingest("ws-kql", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")

      assert {:error, 400, %{"error" => %{"code" => "BadQuery"}}} =
               Sentinel.query("ws-kql", %{"query" => "Custom-Logs | where bogus =="})
    end
  end

  # ---------------------------------------------------------------------------
  # Resource Graph
  # ---------------------------------------------------------------------------

  defp seed_resources(count, sub \\ "sub-1") do
    for i <- 1..count do
      Store.put(:smalt_resources, "sub-1/rg#{rem(i, 3)}/res#{i}", %{
        "id" => "/subscriptions/#{sub}/resourceGroups/rg#{rem(i, 3)}/providers/Microsoft.Compute/vm#{i}",
        "name" => "res#{i}",
        "type" => "Microsoft.Compute/virtualMachines",
        "subscriptionId" => sub
      })
    end
  end

  describe "Resource Graph query" do
    test "rejects wrong api-version with 400" do
      assert {:error, 400, %{"error" => %{"code" => "InvalidApiVersion"}}} =
               ResourceGraph.query(nil, %{}, "2021-01-01")
    end

    test "returns first page with count, data, totalRecords, no truncation" do
      seed_resources(10)

      {:ok, 200, resp} = ResourceGraph.query(["sub-1"], %{"$top" => 4}, "2022-10-01")

      assert resp["count"] == 4
      assert resp["totalRecords"] == 10
      assert resp["resultTruncated"] == false
      assert length(resp["data"]) == 4
      assert is_binary(resp["$skipToken"])
    end

    test "pagination yields no dupes or overlap and terminates" do
      seed_resources(105)

      {names, last_had_token?} = collect_pages(["sub-1"])

      assert length(names) == 105
      assert length(Enum.uniq(names)) == 105
      refute last_had_token?
    end

    test "defaults $top to 100" do
      seed_resources(150)

      {:ok, 200, resp} = ResourceGraph.query(["sub-1"], %{}, "2022-10-01")

      assert resp["count"] == 100
      assert resp["totalRecords"] == 150
      assert resp["$skipToken"]
    end

    test "filters by subscriptions" do
      Store.put(:smalt_resources, "s1/a/r1", %{"name" => "r1", "subscriptionId" => "s1"})
      Store.put(:smalt_resources, "s2/a/r2", %{"name" => "r2", "subscriptionId" => "s2"})

      {:ok, 200, resp} = ResourceGraph.query(["s2"], %{}, "2022-10-01")

      assert resp["totalRecords"] == 1
      assert hd(resp["data"])["name"] == "r2"
    end

    # Regression: resources stored by the router's PUT carry no "subscriptionId"
    # field; the subscription filter must be derived from the stored id instead
    # of silently emptying the result.
    test "subscription filter matches router-created resources lacking subscriptionId" do
      sub = "11111111-2222-3333-4444-555555555555"

      Store.put(:smalt_resources, "#{sub}/rg1/vault1", %{
        "id" => "/subscriptions/#{sub}/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/vault1",
        "name" => "vault1",
        "type" => "Microsoft.KeyVault/vaults"
      })

      Store.put(:smalt_resources, "other-sub/rg1/vault2", %{
        "id" => "/subscriptions/other-sub/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/vault2",
        "name" => "vault2",
        "type" => "Microsoft.KeyVault/vaults"
      })

      {:ok, 200, resp} = ResourceGraph.query([sub], %{}, "2022-10-01")

      assert resp["totalRecords"] == 1
      assert hd(resp["data"])["name"] == "vault1"
    end

    test "unknown skiptoken falls back to first page" do
      seed_resources(5)

      {:ok, 200, resp} = ResourceGraph.query(["sub-1"], %{"skiptoken" => "bogus"}, "2022-10-01")

      assert resp["count"] == 5
    end

    test "query field where-clause filters rows before pagination" do
      for i <- 1..6 do
        Store.put(:smalt_resources, "sub-1/rg0/res#{i}", %{
          "name" => "res#{i}",
          "type" => "Microsoft.Compute/virtualMachines",
          "subscriptionId" => "sub-1"
        })
      end

      {:ok, 200, resp} =
        ResourceGraph.query(["sub-1"], %{"query" => "where name startswith 'res3'"}, "2022-10-01")

      assert resp["totalRecords"] == 1
      assert hd(resp["data"])["name"] == "res3"
    end

    test "filtered pagination applies filter before paging, no dupes across pages" do
      for i <- 1..7 do
        Store.put(:smalt_resources, "sub-1/rg0/res#{i}", %{
          "name" => "res#{i}",
          "type" => "Microsoft.Storage/storageAccounts",
          "subscriptionId" => "sub-1"
        })
      end

      {names, last_had_token?} = collect_pages(["sub-1"], %{"$top" => 3, "query" => "where type == 'Microsoft.Storage/storageAccounts'"})

      assert length(names) == 7
      assert length(Enum.uniq(names)) == 7
      refute last_had_token?
    end

    test "invalid query -> 400 BadQuery" do
      seed_resources(3)

      assert {:error, 400, %{"error" => %{"code" => "BadQuery"}}} =
               ResourceGraph.query(["sub-1"], %{"query" => "where name =="}, "2022-10-01")
    end
  end

  defp collect_pages(subs, body \\ %{}) do
    do_collect(subs, body, [], true, 0)
  end

  defp cell_column(table, col) do
    idx = Enum.find_index(table["columns"], &(&1["name"] == col))
    Enum.map(table["rows"], &Enum.at(&1, idx))
  end

  # returns {all names, did last page still carry a $skipToken}
  defp do_collect(_subs, _body, acc, _had_token, n) when n > 20, do: {acc, true}

  defp do_collect(subs, body, acc, _had_token, n) do
    {:ok, 200, resp} = ResourceGraph.query(subs, body, "2022-10-01")
    acc = acc ++ Enum.map(resp["data"], & &1["name"])

    case resp["$skipToken"] do
      nil -> {acc, false}
      token -> do_collect(subs, %{"skiptoken" => token}, acc, true, n + 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Purview
  # ---------------------------------------------------------------------------

  describe "Purview entities" do
    test "create_entity assigns guid and returns 201" do
      {:ok, 201, entity} = Purview.create_entity(%{"entity" => %{"typeName" => "azure_sql_table"}}, %{})

      assert entity["guid"]
      assert {:ok, _} = Store.get(:smalt_purview_entities, entity["guid"])
    end

    test "bulk of exactly 100 succeeds" do
      entities = Enum.map(1..100, fn i -> %{"typeName" => "t#{i}"} end)

      {:ok, 201, resp} = Purview.bulk_entities(%{"entities" => entities}, %{})

      assert map_size(resp["guidAssignments"]) == 100
      assert Store.list(:smalt_purview_entities) |> length() == 100
    end

    test "bulk of 101 rejected with 400 and no partial insert" do
      entities = Enum.map(1..101, fn i -> %{"typeName" => "t#{i}"} end)

      assert {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001"}}} =
               Purview.bulk_entities(%{"entities" => entities}, %{})

      assert Store.list(:smalt_purview_entities) == []
    end

    test "get_entity 404 for unknown guid" do
      assert {:error, 404, _} = Purview.get_entity("nope", %{})
    end
  end

  describe "Purview lineage" do
    setup :lineage_graph

    test "output direction at depth 1 follows outgoing edges only", %{g: g} do
      {:ok, 200, resp} = Purview.lineage(g["a"], "output", 1)

      assert resp["baseEntityGuid"] == g["a"]
      rels = resp["relations"]
      assert [%{"fromEntityId" => a_guid, "toEntityId" => to}] = rels
      assert a_guid == g["a"]
      assert to == g["b"]
    end

    test "input direction at depth 1 follows incoming edges only", %{g: g} do
      {:ok, 200, resp} = Purview.lineage(g["b"], "input", 1)

      assert [%{"fromEntityId" => from, "toEntityId" => to}] = resp["relations"]
      assert {from, to} == {g["a"], g["b"]}
    end

    test "both direction includes upstream and downstream at depth 1", %{g: g} do
      {:ok, 200, resp} = Purview.lineage(g["b"], "both", 1)

      rels = Enum.map(resp["relations"], &{&1["fromEntityId"], &1["toEntityId"]})
      assert Enum.sort(rels) == Enum.sort([{g["a"], g["b"]}, {g["b"], g["c"]}])
    end

    test "depth 2 traverses transitively", %{g: g} do
      {:ok, 200, resp} = Purview.lineage(g["a"], "output", 2)

      rels = Enum.map(resp["relations"], &{&1["fromEntityId"], &1["toEntityId"]})
      assert {g["a"], g["b"]} in rels
      assert {g["b"], g["c"]} in rels
    end

    test "depth caps traversal at the given level", %{g: g} do
      {:ok, 200, resp} = Purview.lineage(g["a"], "output", 1)

      refute {g["b"], g["c"]} in Enum.map(resp["relations"], &{&1["fromEntityId"], &1["toEntityId"]})
    end

    test "guidEntityMap carries reached entities", %{g: g} do
      {:ok, 200, resp} = Purview.lineage(g["a"], "output", 2)

      assert Map.has_key?(resp["guidEntityMap"], g["c"])
    end

    test "bad direction -> 400", %{g: g} do
      assert {:error, 400, %{"error" => _}} = Purview.lineage(g["a"], "sideways", 1)
    end

    test "unknown guid -> empty relations, base still present" do
      {:ok, 200, resp} = Purview.lineage("ghost", "output", 1)

      assert resp["baseEntityGuid"] == "ghost"
      assert resp["relations"] == []
    end
  end

  defp lineage_graph(_ctx) do
    g = %{
      "a" => "11111111-1111-1111-1111-111111111111",
      "b" => "22222222-2222-2222-2222-222222222222",
      "c" => "33333333-3333-3333-3333-333333333333"
    }

    for {id, name} <- [a: "table_a", b: "table_b", c: "table_c"] do
      Store.put(:smalt_purview_entities, g[id], %{"guid" => g[id], "typeName" => "azure_sql_table", "name" => name})
    end

    Purview.put_edge(g["a"], g["b"], "process", %{"relationshipId" => "e1"})
    Purview.put_edge(g["b"], g["c"], "process", %{"relationshipId" => "e2"})

    {:ok, g: g}
  end
end

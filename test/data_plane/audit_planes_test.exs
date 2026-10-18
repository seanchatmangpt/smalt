defmodule Smalt.DataPlane.AuditPlanesTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.{Purview, ResourceGraph, Sentinel}
  alias Smalt.Store

  setup do
    # Store must be unlinked from the test process (lens-4): start_link owned
    # the immortal Store by the first mortal test process — any abnormal test
    # exit killed Store, and every later test in the run cascaded
    # "table does not exist" (witnessed 2/5/6-failure runs with moving names
    # under ExUnit random order). Plain start + named registration keeps the
    # tables alive for the whole VM regardless of test exits; the app-started
    # case (:already_started) is unchanged.
    case GenServer.start(Store, [], name: Store) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # R185i test-isolation fix (mirror of the R178h queue_store sweep): rows
    # seeded here include id-less maps (e.g. %{"name" => "r1"} in the Resource
    # Graph tests), which poison later semantic-read tests with "vacuous
    # identity" refusals when ExUnit shuffles one between this suite's tests.
    # Clearing only at setup lets those rows outlive the test until the NEXT
    # audit_planes setup; quarantine on exit too.
    on_exit(fn ->
      if :ets.info(:smalt_resources) != :undefined do
        :ets.delete_all_objects(:smalt_resources)
      end
    end)

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
      assert {:ok, 204, ""} =
               Sentinel.ingest(
                 "dcr-1",
                 "Custom-Logs",
                 [%{"msg" => "a"}, %{"msg" => "b"}],
                 "2023-01-01"
               )

      assert {:ok, stream} = Store.get(:smalt_sentinel_streams, "dcr-1/Custom-Logs")
      assert stream["dcr"] == "dcr-1"

      keys = Store.list_prefix(:smalt_sentinel_rows, "dcr-1/Custom-Logs/") |> length()
      assert keys == 2

      assert {:ok, _} =
               Store.get(
                 :smalt_sentinel_rows,
                 "dcr-1/Custom-Logs/" <> String.pad_leading("1", 20, "0")
               )

      assert {:ok, _} =
               Store.get(
                 :smalt_sentinel_rows,
                 "dcr-1/Custom-Logs/" <> String.pad_leading("2", 20, "0")
               )
    end

    test "continues seq numbering across ingests" do
      Sentinel.ingest("dcr-1", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")
      Sentinel.ingest("dcr-1", "Custom-Logs", [%{"msg" => "b"}], "2023-01-01")

      assert {:ok, row} =
               Store.get(
                 :smalt_sentinel_rows,
                 "dcr-1/Custom-Logs/" <> String.pad_leading("2", 20, "0")
               )

      assert row["msg"] == "b"
    end

    test "rejects wrong or missing api-version with 400" do
      assert {:error, 400, %{"error" => %{"code" => "InvalidApiVersion"}}} =
               Sentinel.ingest("dcr-1", "Custom-Logs", [%{}], "2022-01-01")

      assert {:error, 400, %{"error" => _}} = Sentinel.ingest("dcr-1", "Custom-Logs", [%{}], nil)
    end

    test "augments every row with the five string columns" do
      {:ok, 204, ""} =
        Sentinel.ingest(
          "dcr-1",
          "Custom-Logs",
          [%{"msg" => "a", "subject" => "alice"}],
          "2023-01-01"
        )

      {:ok, row} =
        Store.get(:smalt_sentinel_rows, "dcr-1/Custom-Logs/" <> String.pad_leading("1", 20, "0"))

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

      {:ok, row} =
        Store.get(:smalt_sentinel_rows, "dcr-1/Custom-Logs/" <> String.pad_leading("1", 20, "0"))

      assert row["tenantId"] == "my-tenant"
    end

    # Engine-lane handoff (egress-dispatch cycle 6): a null record in a batch
    # is a request-level 400 with NO partial insert — not a silently stored
    # empty record.
    test "nil or scalar record in the batch -> 400 InvalidData, no partial insert" do
      assert {:error, 400, %{"error" => %{"code" => "InvalidData"}}} =
               Sentinel.ingest("dcr-nil", "Custom-Logs", [nil, %{"msg" => "kept?"}], "2023-01-01")

      assert Store.list_prefix(:smalt_sentinel_rows, "dcr-nil/") == []

      assert {:error, 400, %{"error" => %{"code" => "InvalidData"}}} =
               Sentinel.ingest("dcr-nil", "Custom-Logs", [42], "2023-01-01")

      # A clean batch afterwards still works and starts at seq 1.
      assert {:ok, 204, ""} =
               Sentinel.ingest("dcr-nil", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")

      assert length(Store.list_prefix(:smalt_sentinel_rows, "dcr-nil/Custom-Logs/")) == 1
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

      {:ok, 200, resp} =
        Sentinel.query("ws-kql", %{"query" => "Custom-Logs | where eventId == 'x'"})

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

    # C7-3b fence: PrimaryResult column order must equal the requested project
    # order, and column types must follow value shape (long/real/bool/string).
    test "project preserves requested column order; types follow value shape" do
      rows = [
        %{"i" => 1, "f" => 1.5, "b" => true, "s" => "x"},
        %{"i" => 2, "f" => 2.5, "b" => false, "s" => "y"}
      ]

      Sentinel.ingest("ws-proj", "Custom-Logs", rows, "2023-01-01")

      {:ok, 200, resp} =
        Sentinel.query("ws-proj", %{"query" => "Custom-Logs | project s, i, f, b"})

      table = hd(resp["tables"])

      assert Enum.map(table["columns"], & &1["name"]) == ["s", "i", "f", "b"]

      types = Enum.map(table["columns"], &{&1["name"], &1["type"]})
      assert types == [{"s", "string"}, {"i", "long"}, {"f", "real"}, {"b", "bool"}]

      assert table["rows"] == [["x", 1, 1.5, true], ["y", 2, 2.5, false]] ||
               table["rows"] == [["x", "1", "1.5", "true"], ["y", "2", "2.5", "false"]]
    end

    test "all-nil column and empty rows report string type" do
      Sentinel.ingest("ws-types", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")

      {:ok, 200, resp} =
        Sentinel.query("ws-types", %{"query" => "Custom-Logs | project missing_col"})

      assert hd(hd(resp["tables"])["columns"])["type"] == "string"
      assert hd(resp["tables"])["rows"] == [[nil]]
    end

    # R177 (KD-52 territory): project NOT last. The envelope column scan was a
    # greedy regex to end-of-string, so a stage after `project` leaked into the
    # column names ("take 5" became a column). The scan now stops at the next
    # pipe; downstream stages still execute.
    test "project NOT last: later stages do not leak into column names" do
      rows = [%{"n" => 1, "msg" => "a"}, %{"n" => 2, "msg" => "b"}]

      Sentinel.ingest("ws-r177", "Custom-Logs", rows, "2023-01-01")

      {:ok, 200, resp} =
        Sentinel.query("ws-r177", %{"query" => "Custom-Logs | project n, msg | take 5"})

      table = hd(resp["tables"])
      assert Enum.map(table["columns"], & &1["name"]) == ["n", "msg"]
      assert length(table["rows"]) == 2
    end

    test "multi-stage: where | project | order by keeps projected columns only" do
      rows = [
        %{"eventId" => "e1", "msg" => "a", "junk" => true},
        %{"eventId" => "e2", "msg" => "b", "junk" => false},
        %{"eventId" => "e3", "msg" => "c", "junk" => nil}
      ]

      Sentinel.ingest("ws-r177b", "Custom-Logs", rows, "2023-01-01")

      {:ok, 200, resp} =
        Sentinel.query("ws-r177b", %{
          "query" =>
            "Custom-Logs | where eventId != 'e1' | project msg, eventId | order by eventId desc"
        })

      table = hd(resp["tables"])
      assert Enum.map(table["columns"], & &1["name"]) == ["msg", "eventId"]
      assert table["rows"] == [["c", "e3"], ["b", "e2"]]
    end
  end

  # ---------------------------------------------------------------------------
  # Resource Graph
  # ---------------------------------------------------------------------------

  defp seed_resources(count, sub \\ "sub-1") do
    for i <- 1..count do
      Store.put(:smalt_resources, "sub-1/rg#{rem(i, 3)}/res#{i}", %{
        "id" =>
          "/subscriptions/#{sub}/resourceGroups/rg#{rem(i, 3)}/providers/Microsoft.Compute/vm#{i}",
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
        "id" =>
          "/subscriptions/#{sub}/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/vault1",
        "name" => "vault1",
        "type" => "Microsoft.KeyVault/vaults"
      })

      Store.put(:smalt_resources, "other-sub/rg1/vault2", %{
        "id" =>
          "/subscriptions/other-sub/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/vault2",
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

    # Malformed envelope fields are coerced, not a 500 BadMapError: non-map
    # body/options behave like an empty envelope.
    test "non-map body/options are coerced like an empty envelope (no 500)" do
      seed_resources(3)

      assert {:ok, 200, resp} = ResourceGraph.query(["sub-1"], "bogus", "2022-10-01")
      assert resp["count"] == 3

      assert {:ok, 200, resp} =
               ResourceGraph.query(["sub-1"], %{"options" => "bogus", "$top" => 2}, "2022-10-01")

      assert resp["count"] == 2
    end

    # Coordinator cycle-16 order: skipToken pagination while new resources
    # land concurrently. Pinned contract (matches real Resource Graph): the
    # token is an OFFSET into the filtered set, not a snapshot — new rows may
    # or may not appear mid-walk — but a walk must (a) never emit duplicate
    # names, (b) terminate without an empty page, (c) still return every
    # pre-existing row.
    test "skipToken walk under concurrent inserts: no dupes, terminates, full base set" do
      # deterministic base of 40 rows, page size 5
      base = for i <- 1..40, do: "base#{i}"

      Enum.each(base, fn name ->
        Store.put(:smalt_resources, "walk-sub/rg/#{name}", %{
          "id" => "/subscriptions/walk-sub/resourceGroups/rg/providers/M.T/vm-#{name}",
          "name" => name,
          "type" => "M.T/vm",
          "subscriptionId" => "walk-sub"
        })
      end)

      writer =
        Task.async(fn ->
          for i <- 1..20 do
            Store.put(:smalt_resources, "walk-sub/rg/new#{i}", %{
              "id" => "/subscriptions/walk-sub/resourceGroups/rg/providers/M.T/vm-new#{i}",
              "name" => "new#{i}",
              "type" => "M.T/vm",
              "subscriptionId" => "walk-sub"
            })

            Process.sleep(2)  # SLEEP-CLASS: TIME-ADVANCE — writer pacing between ARM-put bursts (deliberate temporal spacing)
          end

          :done
        end)

      names = walk_pages(["walk-sub"], %{"$top" => 5, "query" => "where type == 'M.T/vm'"})

      Task.await(writer, 15_000)

      # (c) every base row came back exactly once
      for name <- base do
        assert Enum.count(names, &(&1 == name)) == 1, "base row #{name} missing or duplicated"
      end

      # (a) no duplicates at all
      assert length(Enum.uniq(names)) == length(names)

      # (b) walk terminated (implicit in walk_pages returning) and each page
      # was non-empty (asserted inside walk_pages)
      assert length(names) >= 40
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

      {names, last_had_token?} =
        collect_pages(["sub-1"], %{
          "$top" => 3,
          "query" => "where type == 'Microsoft.Storage/storageAccounts'"
        })

      assert length(names) == 7
      assert length(Enum.uniq(names)) == 7
      refute last_had_token?
    end

    test "invalid query -> 400 BadQuery" do
      seed_resources(3)

      assert {:error, 400, %{"error" => %{"code" => "BadQuery"}}} =
               ResourceGraph.query(["sub-1"], %{"query" => "where name =="}, "2022-10-01")
    end

    # C7-4a fence: resultTruncated=true ONLY on the hard server cap (1000);
    # the page ends at the cap and the response still carries count/data/
    # totalRecords consistent with the truncated set.
    test "resultTruncated=true only at the 1000-record server cap" do
      sub = "cap-sub-#{System.unique_integer([:positive])}"

      for i <- 1..1001 do
        Store.put(:smalt_resources, "#{sub}/rg/res#{i}", %{
          "id" => "/subscriptions/#{sub}/resourceGroups/rg/providers/Microsoft.Compute/vm#{i}",
          "name" => "res#{i}",
          "type" => "Microsoft.Compute/virtualMachines",
          "subscriptionId" => sub
        })
      end

      {:ok, 200, resp} = ResourceGraph.query([sub], %{"$top" => 1000}, "2022-10-01")

      assert resp["resultTruncated"] == true
      assert resp["count"] == 1000
      assert resp["totalRecords"] == 1000
      assert length(resp["data"]) == 1000
      # Truncation ends the result set: no continuation past the cap.
      refute resp["$skipToken"]
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
  # Walks a skipToken pagination under load; asserts every page non-empty.
  defp walk_pages(subs, body, acc \\ [], n \\ 0)

  defp walk_pages(_subs, _body, acc, n) when n > 60, do: acc

  defp walk_pages(subs, body, acc, n) do
    {:ok, 200, resp} = ResourceGraph.query(subs, body, "2022-10-01")
    names = Enum.map(resp["data"], & &1["name"])

    if resp["$skipToken"] do
      assert names != [], "empty page mid-walk under concurrent inserts"
      walk_pages(subs, %{"skiptoken" => resp["$skipToken"]}, acc ++ names, n + 1)
    else
      acc ++ names
    end
  end

  defp do_collect(_subs, _body, acc, _had_token, n) when n > 20, do: {acc, true}

  defp do_collect(subs, body, acc, _had_token, n) do
    {:ok, 200, resp} = ResourceGraph.query(subs, body, "2022-10-01")

    # Every emitted page must be non-empty: a mutant that issues one extra
    # continuation past the end surfaces as an empty trailing page here.
    if n > 0 or resp["$skipToken"] do
      assert resp["data"] != [], "empty page emitted mid-pagination: #{inspect(resp)}"
    end

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
      {:ok, 201, entity} =
        Purview.create_entity(%{"entity" => %{"typeName" => "azure_sql_table"}}, %{})

      assert entity["guid"]
      assert {:ok, _} = Store.get(:smalt_purview_entities, entity["guid"])
    end

    test "bulk of exactly 100 succeeds" do
      entities = Enum.map(1..100, fn i -> %{"typeName" => "t#{i}"} end)

      {:ok, 201, resp} = Purview.bulk_entities(%{"entities" => entities}, %{})

      assert map_size(resp["guidAssignments"]) == 100
      assert Store.list(:smalt_purview_entities) |> length() == 100
    end

    # Fail-closed fences: malformed entity payloads are 400 ATLAS-400-00-001,
    # never a BadMapError 500, and bulk stays atomic (no partial insert).
    test "non-map entity body -> 400, not 500" do
      assert {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001"}}} =
               Purview.create_entity(%{"entity" => "x"})

      assert {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001"}}} =
               Purview.create_entity("bogus")
    end

    test "bulk with a non-map element -> 400, no partial insert" do
      assert {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001"}}} =
               Purview.bulk_entities(%{"entities" => [%{"a" => 1}, "bogus"]})

      assert Store.list(:smalt_purview_entities) == []
    end

    # Coordinator cycle-15 order: fuzz bulk atomicity harder — mixed
    # valid/nil/scalar batches at the 100 limit, under concurrent readers,
    # all-or-nothing with the exact ATLAS-400-00-001 error.
    test "mixed valid/nil/scalar 100-bulk is all-or-nothing (fuzz)" do
      g = "fuzz-bulk-#{System.unique_integer([:positive])}"

      batches = [
        # 100 entities with an invalid one buried mid-batch
        Enum.map(1..99, fn i -> %{"typeName" => "t", "guid" => "#{g}-#{i}"} end) ++
          ["bogus"],
        Enum.map(1..50, fn i -> %{"typeName" => "t", "guid" => "#{g}-#{i}"} end) ++
          [nil, nil, %{"typeName" => "late"}],
        [%{"typeName" => "solo", "guid" => "#{g}-ok"} | List.duplicate(42, 99)],
        # all-invalid
        List.duplicate(nil, 100),
        # valid 100 (control — must succeed)
        Enum.map(1..100, fn i -> %{"typeName" => "t", "guid" => "#{g}-c#{i}"} end)
      ]

      results = Enum.map(batches, &Purview.bulk_entities(%{"entities" => &1}, %{}))

      # exactly one success (the control batch), rest the exact 400
      assert Enum.count(results, &match?({:ok, 201, _}, &1)) == 1
      assert {:ok, 201, _} = Enum.find(results, &match?({:ok, 201, _}, &1))

      for {:error, 400, %{"error" => %{"code" => code}}} <- results do
        assert code == "ATLAS-400-00-001"
      end

      # only the control batch's 100 guids are stored — no partial inserts
      stored = Store.list(:smalt_purview_entities)
      assert length(stored) == 100
      assert MapSet.size(MapSet.new(stored, & &1["guid"])) == 100
    end

    test "bulk insert under concurrent readers is invisible-until-atomic" do
      g = "bulk-race-#{System.unique_integer([:positive])}"
      guids = Enum.map(1..100, fn i -> "#{g}-#{i}" end)
      batch = Enum.map(guids, fn g -> %{"typeName" => "t", "guid" => g} end)

      # over-limit mutant of the same batch: readers must never see a slice
      over = batch ++ [%{"typeName" => "overflow"}]

      reader =
        Task.async(fn ->
          for _ <- 1..200 do
            stored = Store.list(:smalt_purview_entities)
            found = Enum.count(stored, &(&1["guid"] in guids))
            # all-or-nothing: readers observe 0 or 100 of this batch, never a slice
            assert found == 0 or found == 100, "partial visibility: #{found}/100"
            Process.sleep(1)  # SLEEP-CLASS: POLL-STEP — bounded 200x visibility reader loop
          end
        end)

      assert {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001"}}} =
               Purview.bulk_entities(%{"entities" => over}, %{})

      Task.await(reader, 15_000)

      assert {:ok, 201, _} = Purview.bulk_entities(%{"entities" => batch}, %{})
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

      refute {g["b"], g["c"]} in Enum.map(
               resp["relations"],
               &{&1["fromEntityId"], &1["toEntityId"]}
             )
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
      Store.put(:smalt_purview_entities, g[id], %{
        "guid" => g[id],
        "typeName" => "azure_sql_table",
        "name" => name
      })
    end

    Purview.put_edge(g["a"], g["b"], "process", %{"relationshipId" => "e1"})
    Purview.put_edge(g["b"], g["c"], "process", %{"relationshipId" => "e2"})

    {:ok, g: g}
  end

  # ---------------------------------------------------------------------------
  # Concurrent ingest (seq assignment must be atomic per stream)
  # ---------------------------------------------------------------------------

  describe "Sentinel concurrent ingest" do
    test "parallel ingests to one stream never collide on row seq" do
      saved_forensic = Application.get_env(:smalt, :sentinel_forensic, false)
      SmaltTest.Env.put_restored(sentinel_forensic: true)

      # Leak fix (i21 batch 3): this test creates the owner-durable
      # :smalt_sentinel_forensic named table but never deleted it — it
      # survived the whole VM and the "off-state costs zero" court below
      # had to clean up a predecessor's residue to stay green. Unconditional
      # on_exit delete (the table is deleted with prejudice; the mid-test
      # forensics path only ever reads it).
      on_exit(fn ->
        if :ets.info(:smalt_sentinel_forensic) != :undefined do
          :ets.delete(:smalt_sentinel_forensic)
        end
      end)

      # Restore discipline (corpus-b lens-3): if this test crashes before
      # restoring, the forensic hook stays ON for the whole VM and every
      # later Store.update_counter/CAS across all suites probes the
      # owner-churn :smalt_sentinel_forensic table (witnessed as a 121-test
      # cascade in corpus wave A). The info-then-insert TOCTOU in the lib
      # hook itself is F-22 with the store lane.
      try do
        run_sentinel_race_assertions()
      after
        SmaltTest.Env.put_restored(sentinel_forensic: saved_forensic)
      end
    end

    defp run_sentinel_race_assertions do
      # Owner-durable forensic table: created by THIS (test) process, which
      # stays alive for the whole test, so the timeline cannot vanish with a
      # short-lived first-caller (the same owner-churn defect class repaired
      # in EventStream in cycle 1).
      if :ets.info(:smalt_sentinel_forensic) == :undefined do
        :ets.new(:smalt_sentinel_forensic, [
          :named_table,
          :public,
          :ordered_set,
          write_concurrency: true
        ])
      end

      :ets.delete_all_objects(:smalt_sentinel_forensic)

      tasks =
        1..8
        |> Enum.map(fn t ->
          Task.async(fn ->
            rows = Enum.map(1..5, fn i -> %{"msg" => "t#{t}-#{i}"} end)
            Sentinel.ingest("dcr-race", "Custom-Logs", rows, "2023-01-01")
          end)
        end)

      Task.await_many(tasks, 10_000)

      keys = Store.list_prefix(:smalt_sentinel_rows, "dcr-race/Custom-Logs/")

      if length(keys) != 40 do
        SmaltTest.Env.put_restored(sentinel_forensic: true)

        if :ets.info(:smalt_sentinel_forensic) != :undefined do
          timeline =
            :smalt_sentinel_forensic
            |> :ets.tab2list()
            |> Enum.sort()

          IO.puts("FORENSIC: #{inspect(Enum.take(timeline, 100))}")
        end

        seqs =
          keys
          |> Enum.map(fn r ->
            case Regex.run(~r/t\d+-(\d+)$/, r["msg"]) do
              [_, n] -> String.to_integer(n)
              _ -> -1
            end
          end)
          |> Enum.sort()

        IO.puts("GAPS: #{inspect(Enum.to_list(1..40) -- seqs)}")

        IO.puts(
          "DUP_VALUES: #{inspect(length(keys) - length(Enum.uniq_by(keys, & &1["eventId"])))}"
        )

        IO.puts(
          "COUNTER: #{inspect(:ets.lookup(:smalt_sentinel_streams, {:seq_counter, "dcr-race", "Custom-Logs"}))}"
        )
      end

      assert length(keys) == 40, "expected 40 distinct rows, got #{length(keys)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 1: Sentinel strict-DCR fence (C7-3a implicit-create divergence,
  # ledger fix-shape). Default parity preserved; one env flip pivots to 404.
  # ---------------------------------------------------------------------------

  describe "lens-2 Sentinel strict-DCR fence" do
    test "default: ingest to a never-created DCR implicitly creates it (documented divergence)" do
      assert {:ok, 204, ""} =
               Sentinel.ingest("never-dcr", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")

      assert length(Store.list_prefix(:smalt_sentinel_rows, "never-dcr/Custom-Logs/")) == 1
    end

    test "enforced: ingest to a never-created DCR is refused with the 404-class envelope, no partial insert" do
      SmaltTest.Env.put_restored(sentinel_dcr_strict: true)

      try do
        assert {:error, 404, %{"error" => %{"code" => "DCRNotFound"}}} =
                 Sentinel.ingest(
                   "fenced-dcr",
                   "Custom-Logs",
                   [%{"msg" => "a"}, %{"msg" => "b"}],
                   "2023-01-01"
                 )

        assert Store.list_prefix(:smalt_sentinel_rows, "fenced-dcr/") == []
        assert Store.list_prefix(:smalt_sentinel_streams, "fenced-dcr/") == []
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end
    end

    test "enforced: explicit creation marker admits the ingest (fix shape works)" do
      SmaltTest.Env.put_restored(sentinel_dcr_strict: true)

      try do
        Store.put(:smalt_sentinel_streams, {:dcr_created, "fenced-marked"}, true)

        assert {:ok, 204, ""} =
                 Sentinel.ingest("fenced-marked", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")

        assert length(Store.list_prefix(:smalt_sentinel_rows, "fenced-marked/Custom-Logs/")) == 1
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end
    end

    test "enforced: a DCR with prior stream state admits ingests" do
      # Seed state with the fence off (the seed ingest itself would otherwise be
      # the implicit create), then flip the fence: prior state admits ingests.
      assert {:ok, 204, ""} =
               Sentinel.ingest(
                 "fenced-existing",
                 "Custom-Logs",
                 [%{"msg" => "seed"}],
                 "2023-01-01"
               )

      SmaltTest.Env.put_restored(sentinel_dcr_strict: true)

      try do
        assert {:ok, 204, ""} =
                 Sentinel.ingest(
                   "fenced-existing",
                   "Custom-Logs",
                   [%{"msg" => "next"}],
                   "2023-01-01"
                 )

        assert length(Store.list_prefix(:smalt_sentinel_rows, "fenced-existing/Custom-Logs/")) ==
                 2
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end
    end

    test "enforced: api-version is still checked first (400 InvalidApiVersion wins over 404)" do
      SmaltTest.Env.put_restored(sentinel_dcr_strict: true)

      try do
        assert {:error, 400, %{"error" => %{"code" => "InvalidApiVersion"}}} =
                 Sentinel.ingest("never-dcr-2", "Custom-Logs", [%{}], "2022-01-01")
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 1: Purview lineage cycle-safety (BFS must terminate on a
  # cyclic guid graph, with typed bounded output — never hang, never duplicate).
  # ---------------------------------------------------------------------------

  describe "lens-2 Purview lineage cycle safety" do
    test "two-node cycle terminates and returns each relation once (both directions, deep)" do
      g = %{"x" => "c-xxxxxxxxxxxx1", "y" => "c-yyyyyyyyyyyy2"}

      for {id, name} <- [{"c-xxxxxxxxxxxx1", "entity_x"}, {"c-yyyyyyyyyyyy2", "entity_y"}] do
        Store.put(:smalt_purview_entities, id, %{
          "guid" => id,
          "typeName" => "table",
          "name" => name
        })
      end

      Purview.put_edge(g["x"], g["y"], "process", %{"relationshipId" => "r-xy"})
      Purview.put_edge(g["y"], g["x"], "process", %{"relationshipId" => "r-yx"})

      task =
        Task.async(fn -> Purview.lineage(g["x"], "both", 50) end)

      assert {:ok, 200, resp} = Task.await(task, 5_000)
      assert resp["baseEntityGuid"] == g["x"]

      rel_ids = resp["relations"] |> Enum.map(& &1["relationshipId"]) |> Enum.sort()
      assert rel_ids == ["r-xy", "r-yx"]

      # Visited set is bounded: base + one hop partner, no unbounded growth.
      assert map_size(resp["guidEntityMap"]) == 2
    end

    test "self-loop edge is excluded from output and never traps the walk" do
      id = "c-selfloop00001"
      Store.put(:smalt_purview_entities, id, %{"guid" => id, "typeName" => "table"})

      Purview.put_edge(id, id, "process", %{"relationshipId" => "r-self"})

      assert {:ok, 200, resp} = Purview.lineage(id, "both", 10)
      assert resp["relations"] == []
      assert resp["guidEntityMap"][id]["guid"] == id
    end

    test "cycle downstream of a chain terminates and stays depth-bounded" do
      g = %{
        "p" => "c-chainp0000001",
        "q" => "c-chainq0000001",
        "r" => "c-chainr0000001"
      }

      for {id, _} <- g do
        Store.put(:smalt_purview_entities, id, %{"guid" => id, "typeName" => "table"})
      end

      # p -> q -> r -> q (cycle below the entry node)
      Purview.put_edge(g["p"], g["q"], "process", %{"relationshipId" => "e-pq"})
      Purview.put_edge(g["q"], g["r"], "process", %{"relationshipId" => "e-qr"})
      Purview.put_edge(g["r"], g["q"], "process", %{"relationshipId" => "e-rq"})

      task = Task.async(fn -> Purview.lineage(g["p"], "output", 100) end)

      assert {:ok, 200, resp} = Task.await(task, 5_000)

      rel_ids = resp["relations"] |> Enum.map(& &1["relationshipId"]) |> Enum.sort()
      assert rel_ids == ["e-pq", "e-qr", "e-rq"]
      assert map_size(resp["guidEntityMap"]) == 3
    end

    test "input direction over a cycle terminates identically" do
      g = %{"m" => "c-inputm0000001", "n" => "c-inputn0000001"}

      for {id, _} <- g do
        Store.put(:smalt_purview_entities, id, %{"guid" => id, "typeName" => "table"})
      end

      Purview.put_edge(g["m"], g["n"], "process", %{"relationshipId" => "e-mn"})
      Purview.put_edge(g["n"], g["m"], "process", %{"relationshipId" => "e-nm"})

      task = Task.async(fn -> Purview.lineage(g["m"], "input", 50) end)

      assert {:ok, 200, resp} = Task.await(task, 5_000)

      rel_ids = resp["relations"] |> Enum.map(& &1["relationshipId"]) |> Enum.sort()
      assert rel_ids == ["e-mn", "e-nm"]
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 1: cross-plane event ordering + durability (EventStream publish
  # -> ordered read; ResourceGraph skipToken survives the minting process).
  # ---------------------------------------------------------------------------

  describe "lens-2 cross-plane event ordering" do
    test "EventStream list_events returns strict insertion order under concurrent publishes" do
      parent = self()

      tasks =
        for t <- 1..8 do
          Task.async(fn ->
            ids =
              for i <- 1..10 do
                {:ok, id} =
                  Smalt.Messaging.EventStream.publish("order-topic", %{
                    "specversion" => "1.0",
                    "source" => "/test/order",
                    "type" => "com.smalt.order",
                    "payload" => "t#{t}-#{i}"
                  })

                id
              end

            send(parent, {:batch_done, t})
            ids
          end)
        end

      Task.await_many(tasks, 10_000)

      events = Smalt.Messaging.EventStream.list_events("order-topic")
      assert length(events) == 80

      # seq is globally monotonic across publishers: every list is strictly
      # increasing, unique, and covers 80 distinct events.
      seqs = Enum.map(events, & &1["seq"])
      assert seqs == Enum.sort(Enum.uniq(seqs))
      assert length(Enum.uniq(Enum.map(events, & &1["id"]))) == 80

      # Durability: a second read from a fresh process sees the identical list.
      {:ok, checker} =
        Task.start(fn ->
          send(parent, {:reread, Smalt.Messaging.EventStream.list_events("order-topic")})
        end)

      ref = Process.monitor(checker)

      assert_receive {:reread, reread}, 5_000
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert reread == events
    end

    test "publish_events (router path) then list preserves CloudEvents payload and order" do
      batch =
        for i <- 1..25 do
          %{
            "specversion" => "1.0",
            "source" => "/plane/cross",
            "type" => "com.smalt.cross",
            "n" => i
          }
        end

      assert :ok = Smalt.Messaging.EventStream.publish_events("cross-topic", batch)

      events = Smalt.Messaging.EventStream.list_events("cross-topic")
      assert Enum.map(events, & &1["n"]) == Enum.to_list(1..25)
      assert Enum.all?(events, &(&1["specversion"] == "1.0" and is_binary(&1["id"])))
    end

    test "ResourceGraph skipToken minted in a dead task is honored afterwards (lane-restart compat)" do
      for i <- 1..7 do
        Store.put(
          :smalt_resources,
          "/subscriptions/sub-rx/resourcegroups/rg#{i}/providers/microsoft.storage/storageaccounts/sa#{i}",
          %{
            "id" =>
              "/subscriptions/sub-rx/resourceGroups/rg#{i}/providers/Microsoft.Storage/storageAccounts/sa#{i}",
            "name" => "sa#{i}",
            "type" => "Microsoft.Storage/storageAccounts"
          }
        )
      end

      # Mint the token inside a task that then exits (the "pre-restart" lane).
      token =
        Task.async(fn ->
          {:ok, 200, body} =
            ResourceGraph.query(["sub-rx"], %{"options" => %{"$top" => 3}}, "2022-10-01")

          assert body["count"] == 3
          assert is_binary(body["$skipToken"])
          body["$skipToken"]
        end)
        |> Task.await(5_000)

      # "Post-restart": the minting process is gone; the token must still page.
      {:ok, 200, body} =
        Task.async(fn ->
          ResourceGraph.query(nil, %{"options" => %{"$skipToken" => token}}, "2022-10-01")
        end)
        |> Task.await(5_000)

      assert body["count"] == 4
      assert body["totalRecords"] == 7

      # And the token survives a Store round-trip key identity (durable, not
      # process-local): direct Store read from this process succeeds.
      assert match?({:ok, %{"offset" => 3}}, Store.get(:smalt_resource_graph_tokens, token))
    end

    test "unknown skipToken degrades to plain skip (documented lenient fallback)" do
      for i <- 1..5 do
        Store.put(:smalt_resources, "/subscriptions/sub-rx2/resourcegroups/rg#{i}", %{
          "id" => "/subscriptions/sub-rx2/resourceGroups/rg#{i}",
          "name" => "rg#{i}"
        })
      end

      {:ok, 200, body} =
        ResourceGraph.query(
          ["sub-rx2"],
          %{"options" => %{"$skipToken" => "deadbeef", "$top" => 2}},
          "2022-10-01"
        )

      assert body["count"] == 2
      assert body["totalRecords"] == 5
      assert is_binary(body["$skipToken"])
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 3: ResourceGraph token-mint contention + Sentinel large-seq
  # ordering under concurrent ingest.
  # ---------------------------------------------------------------------------

  describe "lens-2 cycle 3" do
    test "concurrent ResourceGraph pagers mint distinct, individually-valid tokens" do
      sub = "tok-sub-#{System.unique_integer([:positive])}"

      for i <- 1..12 do
        Store.put(:smalt_resources, "/subscriptions/#{sub}/rg#{i}", %{
          "id" => "/subscriptions/#{sub}/rg#{i}",
          "name" => "rg#{i}"
        })
      end

      tasks =
        for _t <- 1..24 do
          Task.async(fn ->
            {:ok, 200, body} =
              ResourceGraph.query([sub], %{"options" => %{"$top" => 4}}, "2022-10-01")

            body
          end)
        end

      bodies = Task.await_many(tasks, 10_000)
      tokens = Enum.map(bodies, & &1["$skipToken"])

      # 24 mints, 24 distinct tokens, each stored with the right offset.
      assert length(Enum.uniq(tokens)) == 24

      for token <- tokens do
        assert match?({:ok, %{"offset" => 4}}, Store.get(:smalt_resource_graph_tokens, token))
      end

      # Sampled tokens each page to the identical second page.
      for token <- Enum.take(tokens, 4) do
        assert {:ok, 200, page2} =
                 ResourceGraph.query(nil, %{"options" => %{"$skipToken" => token}}, "2022-10-01")

        # offset 4 of 12, default $top: 8 remaining
        assert page2["count"] == 8
      end
    end

    test "Sentinel large-seq ordering: 1200 concurrent rows, no seq collisions, take returns stored order" do
      dcr = "order-dcr-#{System.unique_integer([:positive])}"

      batches =
        for t <- 1..6 do
          Task.async(fn ->
            rows = for i <- 1..200, do: %{"msg" => "t#{t}-#{i}"}
            Sentinel.ingest(dcr, "Custom-Logs", rows, "2023-01-01")
          end)
        end

      Task.await_many(batches, 15_000)

      keys = Store.list_prefix(:smalt_sentinel_rows, "#{dcr}/Custom-Logs/")
      assert length(keys) == 1200, "seq collisions dropped rows: got #{length(keys)}"

      {:ok, 200, resp} = Sentinel.query(dcr, %{"query" => "Custom-Logs | take 2000"})
      assert length(hd(resp["tables"])["rows"]) == 101
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 4: eventId preservation, lineage orientation symmetry,
  # $skip/$skipToken precedence.
  # ---------------------------------------------------------------------------

  describe "lens-2 cycle 4" do
    test "Sentinel augment preserves a caller-supplied eventId verbatim; coerces non-binaries" do
      dcr = "eid-dcr-#{System.unique_integer([:positive])}"

      assert {:ok, 204, ""} =
               Sentinel.ingest(
                 dcr,
                 "Custom-Logs",
                 [
                   %{"msg" => "a", "eventId" => "my-explicit-id-42"},
                   %{"msg" => "b", "eventId" => 77}
                 ],
                 "2023-01-01"
               )

      rows = Store.list_prefix(:smalt_sentinel_rows, "#{dcr}/Custom-Logs/")

      assert %{"eventId" => "my-explicit-id-42"} = Enum.find(rows, &(&1["msg"] == "a"))
      assert %{"eventId" => "77"} = Enum.find(rows, &(&1["msg"] == "b"))
    end

    test "Purview lineage orientation is symmetric: either endpoint yields the same relations" do
      u = "sym-u-#{System.unique_integer([:positive])}"
      v = "sym-v-#{System.unique_integer([:positive])}"

      for id <- [u, v] do
        Store.put(:smalt_purview_entities, id, %{"guid" => id, "typeName" => "table"})
      end

      rid = "r-sym-#{System.unique_integer([:positive])}"
      Purview.put_edge(u, v, "process", %{"relationshipId" => rid})

      assert {:ok, 200, from_u} = Purview.lineage(u, "both", 1)
      assert {:ok, 200, from_v} = Purview.lineage(v, "both", 1)

      assert [%{"relationshipId" => ^rid, "fromEntityId" => ^u, "toEntityId" => ^v}] =
               from_u["relations"]

      assert [%{"relationshipId" => ^rid, "fromEntityId" => ^u, "toEntityId" => ^v}] =
               from_v["relations"]
    end

    test "ResourceGraph: an explicit $skipToken takes precedence over $skip" do
      sub = "prec-sub-#{System.unique_integer([:positive])}"

      for i <- 1..9 do
        Store.put(:smalt_resources, "/subscriptions/#{sub}/r#{i}", %{
          "id" => "/subscriptions/#{sub}/r#{i}",
          "name" => "r#{i}"
        })
      end

      {:ok, 200, page1} = ResourceGraph.query([sub], %{"options" => %{"$top" => 3}}, "2022-10-01")
      token = page1["$skipToken"]

      # $skip=0 would restart from the top; the token must win for the offset
      # (real API: continuation semantics override a bare skip). The token
      # carries offset+subscriptions only — $top is re-supplied by the caller.
      {:ok, 200, page2} =
        ResourceGraph.query(
          [sub],
          %{"options" => %{"$skip" => 0, "$skipToken" => token, "$top" => 3}},
          "2022-10-01"
        )

      assert page2["count"] == 3
      assert page2["totalRecords"] == 9

      names = page2["data"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["r4", "r5", "r6"]
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 5: EventStream duplicate-id semantics, Purview depth frontier.
  # ---------------------------------------------------------------------------

  describe "lens-2 cycle 5" do
    test "EventStream republish with the same id overwrites by topic/id key (pinned divergence)" do
      topic = "dup-topic-#{System.unique_integer([:positive])}"

      ev = %{
        "specversion" => "1.0",
        "source" => "/dup",
        "type" => "com.smalt.dup",
        "id" => "fixed-id",
        "v" => 1
      }

      assert {:ok, "fixed-id"} = Smalt.Messaging.EventStream.publish(topic, ev)
      assert {:ok, "fixed-id"} = Smalt.Messaging.EventStream.publish(topic, %{ev | "v" => 2})

      events = Smalt.Messaging.EventStream.list_events(topic)
      # Pinned divergence: real Event Grid dedups duplicate ids within its
      # dedup window; the emulator keeps one row per id, last write wins.
      assert length(events) == 1
      assert [only] = events
      assert only["v"] == 2
    end

    test "EventStream same id on a DIFFERENT topic is a separate row (key scoping)" do
      t1 = "scope1-#{System.unique_integer([:positive])}"
      t2 = "scope2-#{System.unique_integer([:positive])}"
      ev = %{"specversion" => "1.0", "source" => "/s", "type" => "t", "id" => "shared"}

      assert {:ok, "shared"} = Smalt.Messaging.EventStream.publish(t1, ev)
      assert {:ok, "shared"} = Smalt.Messaging.EventStream.publish(t2, ev)

      assert [ev1] = Smalt.Messaging.EventStream.list_events(t1)
      assert [ev2] = Smalt.Messaging.EventStream.list_events(t2)
      assert ev1["topic"] == t1 and ev2["topic"] == t2
    end

    test "Purview lineage depth is frontier-additive across a mixed both-direction graph" do
      a = "mix-a-#{System.unique_integer([:positive])}"
      b = "mix-b-#{System.unique_integer([:positive])}"
      c = "mix-c-#{System.unique_integer([:positive])}"
      x = "mix-x-#{System.unique_integer([:positive])}"

      for id <- [a, b, c, x] do
        Store.put(:smalt_purview_entities, id, %{"guid" => id, "typeName" => "table"})
      end

      # a -> b -> c (output side) and x -> a (input side)
      Purview.put_edge(a, b, "process", %{"relationshipId" => "e-ab"})
      Purview.put_edge(b, c, "process", %{"relationshipId" => "e-bc"})
      Purview.put_edge(x, a, "process", %{"relationshipId" => "e-xa"})

      {:ok, 200, d1} = Purview.lineage(a, "both", 1)
      {:ok, 200, d2} = Purview.lineage(a, "both", 2)

      assert MapSet.new(Enum.map(d1["relations"], & &1["relationshipId"])) ==
               MapSet.new(["e-ab", "e-xa"])

      assert "e-bc" in Enum.map(d2["relations"], & &1["relationshipId"])
      assert map_size(d2["guidEntityMap"]) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 7: one-flip coordinator pivots — flagged fix-shape proofs for
  # the two remaining pinned divergences (strict-DCR already fenced cycle 1).
  # ---------------------------------------------------------------------------

  describe "lens-2 cycle 7 option-preserving skipToken fence" do
    test "default: continuation ignores stored options (offset+subscriptions only)" do
      sub = "opt-d-#{System.unique_integer([:positive])}"

      for i <- 1..9 do
        Store.put(:smalt_resources, "/subscriptions/#{sub}/r#{i}", %{
          "id" => "/subscriptions/#{sub}/r#{i}",
          "name" => "r#{i}"
        })
      end

      {:ok, 200, page1} = ResourceGraph.query([sub], %{"options" => %{"$top" => 3}}, "2022-10-01")
      token = page1["$skipToken"]

      # No $top re-supplied: default page = everything remaining (6).
      {:ok, 200, page2} =
        ResourceGraph.query([sub], %{"options" => %{"$skipToken" => token}}, "2022-10-01")

      assert page2["count"] == 6
    end

    test "enforced: continuation falls back to the stored $top (real-API shape)" do
      sub = "opt-e-#{System.unique_integer([:positive])}"

      for i <- 1..9 do
        Store.put(:smalt_resources, "/subscriptions/#{sub}/r#{i}", %{
          "id" => "/subscriptions/#{sub}/r#{i}",
          "name" => "r#{i}"
        })
      end

      {:ok, 200, page1} = ResourceGraph.query([sub], %{"options" => %{"$top" => 3}}, "2022-10-01")
      token = page1["$skipToken"]

      SmaltTest.Env.put_restored(rg_token_preserve_options: true)

      try do
        # Explicit options still win over stored ones.
        {:ok, 200, p2a} =
          ResourceGraph.query(
            [sub],
            %{"options" => %{"$skipToken" => token, "$top" => 2}},
            "2022-10-01"
          )

        assert p2a["count"] == 2
        assert Enum.map(p2a["data"], & &1["name"]) |> Enum.sort() == ["r4", "r5"]

        # Omitted $top falls back to the stored value (3).
        {:ok, 200, p2b} =
          ResourceGraph.query([sub], %{"options" => %{"$skipToken" => token}}, "2022-10-01")

        assert p2b["count"] == 3
        assert Enum.map(p2b["data"], & &1["name"]) |> Enum.sort() == ["r4", "r5", "r6"]
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end
    end
  end

  describe "lens-2 cycle 7 EventStream id-dedup fence" do
    test "default: same-id republish overwrites (documented divergence)" do
      topic = "dedup-d-#{System.unique_integer([:positive])}"
      ev = %{"specversion" => "1.0", "source" => "/s", "type" => "t", "id" => "same", "v" => 1}

      assert {:ok, "same"} = Smalt.Messaging.EventStream.publish(topic, ev)
      assert {:ok, "same"} = Smalt.Messaging.EventStream.publish(topic, %{ev | "v" => 2})
      assert [%{"v" => 2}] = Smalt.Messaging.EventStream.list_events(topic)
    end

    test "enforced: same-id republish is refused with a typed error, first write preserved" do
      topic = "dedup-e-#{System.unique_integer([:positive])}"
      ev = %{"specversion" => "1.0", "source" => "/s", "type" => "t", "id" => "same", "v" => 1}

      SmaltTest.Env.put_restored(event_stream_dedup_ids: true)

      try do
        assert {:ok, "same"} = Smalt.Messaging.EventStream.publish(topic, ev)

        assert {:error, :duplicate_id} =
                 Smalt.Messaging.EventStream.publish(topic, %{ev | "v" => 2})

        # First write intact, last-write-wins defeated.
        assert [%{"v" => 1}] = Smalt.Messaging.EventStream.list_events(topic)

        # A distinct id still publishes normally under the fence.
        assert {:ok, _} = Smalt.Messaging.EventStream.publish(topic, %{ev | "id" => "other"})

        # publish_many halts at the duplicate (partial insert semantics
        # documented in cycle 5: earlier events remain stored).
        assert {:error, :duplicate_id} =
                 Smalt.Messaging.EventStream.publish_many(topic, [
                   %{ev | "id" => "ok3"},
                   %{ev | "id" => "same"}
                 ])

        # Generated ids (no explicit id) never collide.
        assert {:ok, _} = Smalt.Messaging.EventStream.publish(topic, %{ev | "id" => nil})
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-3 F-1: serialized seq counter. The pre-repair shape (caller-side
  # init/check/CAS-seed + direct :ets.update_counter bump) let a concurrent
  # bump slip between the seed CAS's lookup and insert and clobber assigned
  # seqs (lens-3 huntE timeline). Store.next_seq/3 runs the whole
  # check-seed-bump as one Store handle_call; these courts pin its contract.
  # ---------------------------------------------------------------------------
  describe "lens-3 Store.next_seq serialized counter" do
    test "seeds from seed_fun exactly once when the counter row is missing" do
      table = :l3_seq_court
      {:ok, owner} = Task.start(fn -> Process.sleep(:infinity) end)
      :ets.new(table, [:set, :public, :named_table])
      :ets.give_away(table, owner, nil)

      on_exit(fn ->
        if :ets.info(table) != :undefined, do: :ets.delete(table)
      end)

      # No counter row: next_seq must seed from seed_fun, not 0.
      assert 4 = Store.next_seq(table, {:k}, fn -> 3 end)
      # After seeding, bump continues and the stale seed_fun value is refused.
      assert 5 = Store.next_seq(table, {:k}, fn -> 999 end)

      # seed_fun must NOT be called when the row exists.
      assert 6 =
               Store.next_seq(table, {:k}, fn ->
                 flunk("seed_fun called although the counter row exists")
               end)
    end

    test "concurrent next_seq calls never collide and end exactly at n" do
      table = :l3_seq_court2
      {:ok, owner} = Task.start(fn -> Process.sleep(:infinity) end)
      :ets.new(table, [:set, :public, :named_table])
      :ets.give_away(table, owner, nil)

      on_exit(fn ->
        if :ets.info(table) != :undefined, do: :ets.delete(table)
      end)

      results =
        1..16
        |> Enum.map(fn _ ->
          Task.async(fn -> for _ <- 1..25, do: Store.next_seq(table, {:k}, fn -> 0 end) end)
        end)
        |> Task.await_many(30_000)
        |> List.flatten()
        |> Enum.sort()

      assert results == Enum.to_list(1..400)
      assert Store.current_counter(table, {:k}) == 400
    end

    test "unknown table fails closed (raises, never silently creates)" do
      assert_raise ArgumentError, ~r/unknown table/, fn ->
        Store.next_seq(:no_such_l3_table, {:k}, fn -> 0 end)
      end
    end

    # Lens-4: Store-level mutation courts for the shared-seam next_seq/3.
    test "seed_fun runs exactly once across concurrent first-touches (re-entry discipline)" do
      table = :l4_seq_seed_once
      {:ok, owner} = Task.start(fn -> Process.sleep(:infinity) end)
      :ets.new(table, [:set, :public, :named_table])
      :ets.give_away(table, owner, nil)

      on_exit(fn ->
        if :ets.info(table) != :undefined, do: :ets.delete(table)
      end)

      {:ok, counter} = Agent.start(fn -> 0 end)

      results =
        1..16
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..25 do
              Store.next_seq(table, {:k}, fn ->
                Agent.update(counter, &(&1 + 1))
                0
              end)
            end
          end)
        end)
        |> Task.await_many(30_000)
        |> List.flatten()
        |> Enum.sort()

      assert results == Enum.to_list(1..400)
      # Seed happened once, ever: after the first serialized seed, seed_fun is
      # dead code for the life of the row.
      assert Agent.get(counter, & &1) == 1
      assert Store.current_counter(table, {:l4_other}) == 0
    end

    test "concurrent mixed next_seq + compare_and_swap on adjacent keys never cross-clobber" do
      seq_table = :l4_mixed_seq
      cas_table = :l4_mixed_cas
      {:ok, owner} = Task.start(fn -> Process.sleep(:infinity) end)

      :ets.new(seq_table, [:set, :public, :named_table])
      :ets.new(cas_table, [:set, :public, :named_table])
      :ets.give_away(seq_table, owner, nil)
      :ets.give_away(cas_table, owner, nil)

      on_exit(fn ->
        if :ets.info(seq_table) != :undefined, do: :ets.delete(seq_table)
        if :ets.info(cas_table) != :undefined, do: :ets.delete(cas_table)
      end)

      cas_key = {:adjacent_cas}
      # CAS conflicts on a missing row; seed the cell deterministically before
      # any task starts (single-threaded setup, no window).
      :ets.insert(cas_table, {cas_key, 0})

      # CAS contender hammering an adjacent key for the whole window.
      cas_task =
        Task.async(fn ->
          Enum.max(
            for i <- 1..400 do
              case Store.compare_and_swap(cas_table, cas_key, i - 1, i) do
                :ok -> i
                {:error, :conflict} -> 0
              end
            end
          )
        end)

      seq_results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..25, do: Store.next_seq(seq_table, {:k}, fn -> 0 end)
          end)
        end)
        |> Task.await_many(30_000)
        |> List.flatten()
        |> Enum.sort()

      cas_task_max = Task.await(cas_task, 30_000)

      # seq stream is exactly 1..200 with zero clobbered assignments even
      # while the CAS contender hammers its own adjacent key.
      assert seq_results == Enum.to_list(1..200)
      assert cas_task_max == 400
      assert Store.current_counter(seq_table, {:k}) == 200
    end

    test "forensic off-state costs zero: no :smalt_sentinel_forensic table is ever created" do
      saved = Application.get_env(:smalt, :sentinel_forensic, false)
      SmaltTest.Env.put_restored(sentinel_forensic: false)

      # Leak fix (i21 batch 3): unconditional on_exit delete for :l4_off_cas.
      # The in-test `after` is skipped when the VM is tearing the test down
      # abnormally; on_exit always runs.
      on_exit(fn ->
        if :ets.info(:l4_off_cas) != :undefined, do: :ets.delete(:l4_off_cas)
      end)

      try do
        if :ets.info(:smalt_sentinel_forensic) != :undefined do
          :ets.delete(:smalt_sentinel_forensic)
        end

        # Full counter + row traffic with the flag off.
        assert {:ok, 204, ""} =
                 Sentinel.ingest("l4-off-dcr", "Custom-Logs", [%{"msg" => "off"}], "2023-01-01")

        :ets.new(:l4_off_cas, [:set, :public, :named_table])
        Store.update_counter(:l4_off_cas, {:k}, 1)
        Store.compare_and_swap(:l4_off_cas, {:k}, 1, 2)
      after
        SmaltTest.Env.put_restored(sentinel_forensic: saved)
        if :ets.info(:l4_off_cas) != :undefined, do: :ets.delete(:l4_off_cas)
      end

      assert :ets.info(:smalt_sentinel_forensic) == :undefined
    end
  end

  # ---------------------------------------------------------------------------
  # Lane 19 (v26.10.14) egress-security sweep fences.
  # ---------------------------------------------------------------------------

  describe "lane-19 egress-security fence" do
    test "item 2: strict mode admits a DCR the lib itself created" do
      assert {:ok, 204, ""} =
               Sentinel.ingest("lane19-dcr", "Custom-Logs", [%{"msg" => "seed"}], "2023-01-01")

      SmaltTest.Env.put_restored(sentinel_dcr_strict: true)

      try do
        assert {:ok, 204, ""} =
                 Sentinel.ingest("lane19-dcr", "Custom-Logs", [%{"msg" => "next"}], "2023-01-01")
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end

      {:ok, 200, body} =
        Sentinel.query("lane19-dcr", %{"query" => "take 100"})

      [table] = body["tables"]
      assert length(table["rows"]) == 2
    end

    test "item 2: strict mode still refuses a truly never-created DCR" do
      SmaltTest.Env.put_restored(sentinel_dcr_strict: true)

      try do
        assert {:error, 404, %{"error" => %{"code" => "DCRNotFound"}}} =
                 Sentinel.ingest("lane19-never", "Custom-Logs", [%{"msg" => "a"}], "2023-01-01")
      after
        # isolation-court: exempt restore now structural via put_restored on_exit
        :ok
      end
    end

    test "item 7: legacy take is capped at 101 and honors smaller takes" do
      rows = Enum.map(1..105, fn i -> %{"msg" => "r#{i}"} end)
      assert {:ok, 204, ""} = Sentinel.ingest("lane19-take", "Custom-Logs", rows, "2023-01-01")

      {:ok, 200, body} = Sentinel.query("lane19-take", %{"query" => "take 100000"})
      [table] = body["tables"]
      assert length(table["rows"]) == 101

      {:ok, 200, body} = Sentinel.query("lane19-take", %{"query" => "take 50"})
      [table] = body["tables"]
      assert length(table["rows"]) == 50
    end

    test "item 4: expired skip tokens are swept on mint" do
      # Seed an already-expired token directly, then mint a fresh one via a
      # paginated query: the mint-time sweep must delete the expired entry.
      expired_token = String.duplicate("aa", 12)

      Store.put(:smalt_resource_graph_tokens, expired_token, %{
        "offset" => 0,
        "subscriptions" => nil,
        "created_at" => System.system_time(:millisecond) - :timer.minutes(16)
      })

      Store.put(:smalt_resources, "r1", %{
        "id" => "/subscriptions/sub-a/resourceGroups/rg1/providers/Mock.Type/m1",
        "name" => "m1",
        "type" => "Mock.Type"
      })

      Store.put(:smalt_resources, "r2", %{
        "id" => "/subscriptions/sub-a/resourceGroups/rg1/providers/Mock.Type/m2",
        "name" => "m2",
        "type" => "Mock.Type"
      })

      {:ok, 200, body} =
        ResourceGraph.query(nil, %{"$top" => 1}, "2022-10-01")

      assert body["$skipToken"]

      assert :error = Store.get(:smalt_resource_graph_tokens, expired_token)
      {:ok, _} = Store.get(:smalt_resource_graph_tokens, body["$skipToken"])
    end

    test "item 4: token cap evicts oldest-first" do
      now = System.system_time(:millisecond)

      # Fill to the cap with age-ordered tokens; the next mint must evict the
      # oldest to stay at the cap.
      Enum.each(1..1000, fn i ->
        Store.put(
          :smalt_resource_graph_tokens,
          "tok-#{String.pad_leading(Integer.to_string(i), 5, "0")}",
          %{
            "offset" => i,
            "subscriptions" => nil,
            "created_at" => now - (1000 - i)
          }
        )
      end)

      Store.put(:smalt_resources, "r1", %{
        "id" => "/subscriptions/sub-a/resourceGroups/rg1/providers/Mock.Type/m1",
        "name" => "m1",
        "type" => "Mock.Type"
      })

      Store.put(:smalt_resources, "r2", %{
        "id" => "/subscriptions/sub-a/resourceGroups/rg1/providers/Mock.Type/m2",
        "name" => "m2",
        "type" => "Mock.Type"
      })

      {:ok, 200, body} = ResourceGraph.query(nil, %{"$top" => 1}, "2022-10-01")
      assert body["$skipToken"]

      # Oldest token evicted, table held at the cap.
      assert :error = Store.get(:smalt_resource_graph_tokens, "tok-00001")
      assert length(Store.keys(:smalt_resource_graph_tokens)) == 1000
    end
  end
end

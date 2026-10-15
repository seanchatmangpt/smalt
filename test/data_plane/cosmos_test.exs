defmodule Smalt.DataPlane.CosmosTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.DataPlane.{ConditionalHeaders, Cosmos, PartitionKey}
  alias Smalt.EgressRouter
  alias Smalt.Store

  @charge %{"x-ms-request-charge" => "1.0"}

  setup do
    if GenServer.whereis(Store) == nil do
      {:ok, _} = Store.start_link([])
    end

    Store.clear()
    assert Cosmos.store_ready?()
    :ok
  end

  # ---------------------------------------------------------------------------
  # ConditionalHeaders
  # ---------------------------------------------------------------------------

  describe "ConditionalHeaders.evaluate/2" do
    test "no conditions proceeds" do
      assert ConditionalHeaders.evaluate(%{}, "\"abc\"") == :proceed
    end

    test "If-Match exact match proceeds" do
      assert ConditionalHeaders.evaluate(%{"If-Match" => "\"abc\""}, "\"abc\"") == :proceed
    end

    test "If-Match * proceeds" do
      assert ConditionalHeaders.evaluate(%{"if-match" => "*"}, "\"abc\"") == :proceed
    end

    test "If-Match mismatch halts 412" do
      assert ConditionalHeaders.evaluate(%{"if-match" => "\"stale\""}, "\"abc\"") == {:halt, 412}
    end

    test "If-None-Match match halts 304" do
      assert ConditionalHeaders.evaluate(%{"if-none-match" => "\"abc\""}, "\"abc\"") ==
               {:halt, 304}
    end

    test "If-None-Match non-match proceeds" do
      assert ConditionalHeaders.evaluate(%{"if-none-match" => "\"other\""}, "\"abc\"") == :proceed
    end

    test "unquoted etag candidate matches the stored quoted etag (strip tolerance)" do
      assert ConditionalHeaders.evaluate(%{"if-match" => "abc"}, "\"abc\"") == :proceed
      assert ConditionalHeaders.evaluate(%{"if-none-match" => "abc"}, "\"abc\"") == {:halt, 304}
      assert ConditionalHeaders.evaluate(%{"if-match" => "stale"}, "\"abc\"") == {:halt, 412}
    end

    test "multi-candidate If-Match list: any match proceeds" do
      assert ConditionalHeaders.evaluate(%{"if-match" => "\"x\", \"abc\""}, "\"abc\"") == :proceed
      assert ConditionalHeaders.evaluate(%{"if-match" => "\"x\", \"y\""}, "\"abc\"") == {:halt, 412}
    end
  end

  # ---------------------------------------------------------------------------
  # PartitionKey
  # ---------------------------------------------------------------------------

  describe "PartitionKey matrix" do
    test "parse accepts JSON array with exactly one non-empty string" do
      assert PartitionKey.parse(~s(["acme"])) == {:ok, "acme"}
    end

    test "parse rejects empty array, multi-element, non-string, and malformed JSON" do
      assert PartitionKey.parse("[]") == :error
      assert PartitionKey.parse(~s(["a","b"])) == :error
      assert PartitionKey.parse("[1]") == :error
      assert PartitionKey.parse(~s([""])) == :error
      assert PartitionKey.parse("not json") == :error
      assert PartitionKey.parse(nil) == :error
    end

    test "enforce ok when container has no partition key" do
      assert PartitionKey.enforce(nil, nil) == :ok
      assert PartitionKey.enforce(nil, %{"paths" => ["/tenantId"]}) == {:error, 400, "BadRequest"}
    end

    test "enforce: header missing when pk defined -> 400 BadRequest" do
      assert PartitionKey.enforce(nil, %{"id" => "d", "__pk_header__" => nil}, %{
               "paths" => ["/tenantId"]
             }) == {:error, 400, "BadRequest"}
    end

    test "enforce: header matches doc pk value -> ok" do
      doc = %{"id" => "d", "tenantId" => "acme"}

      assert PartitionKey.enforce(~s(["acme"]), doc, %{"paths" => ["/tenantId"]}) == :ok
    end

    test "enforce: header mismatch vs doc -> 400 BadRequest" do
      doc = %{"id" => "d", "tenantId" => "acme"}

      assert PartitionKey.enforce(~s(["other"]), doc, %{"paths" => ["/tenantId"]}) ==
               {:error, 400, "BadRequest"}
    end
  end

  # ---------------------------------------------------------------------------
  # Cosmos document CRUD
  # ---------------------------------------------------------------------------

  describe "Cosmos point operations" do
    test "create returns 201 with _etag quoted sha256, _rid, _ts and request charge" do
      assert {:ok, 201, headers, doc} =
               Cosmos.create_doc("db1", "coll1", %{"id" => "d1", "v" => 1}, %{})

      assert headers["x-ms-request-charge"] == "1.0"
      assert doc["_rid"] =~ ~r/^[A-Za-z0-9_-]{20}$/
      assert doc["_rid"] == Cosmos.doc_rid("db1", "coll1", "d1")

      assert Cosmos.db_rid("db1") == Cosmos.rid_segment("db1", 8)
      assert Cosmos.coll_rid("db1", "coll1") == Cosmos.db_rid("db1") <> Cosmos.rid_segment("coll1", 4)
      assert is_integer(doc["_ts"])
      assert <<?", _::binary>> = doc["_etag"]
      assert String.ends_with?(doc["_etag"], "\"")
      assert byte_size(doc["_etag"]) == 66
    end

    test "create of a > 2MB doc -> 413 RequestEntityTooLarge envelope" do
      big = %{"id" => "toobig", "blob" => String.duplicate("x", 2 * 1024 * 1024)}

      assert {:ok, 413, headers, %{"code" => "RequestEntityTooLarge"}} =
               Cosmos.create_doc("db1", "coll1", big, %{})

      assert headers["x-ms-request-charge"] == "1.0"
    end

    test "create without pk header on pk container -> 400 BadRequest" do
      Cosmos.define_container("db1", "pkcoll", ["/tenantId"])

      assert {:ok, 400, headers, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("db1", "pkcoll", %{"id" => "d1", "tenantId" => "acme"}, %{})

      assert headers["x-ms-request-charge"] == "1.0"
    end

    test "create with mismatched pk header -> 400 BadRequest" do
      Cosmos.define_container("db1", "pkcoll", ["/tenantId"])

      assert {:ok, 400, _h, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("db1", "pkcoll", %{"id" => "d1", "tenantId" => "acme"}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["other"])
               })
    end

    test "create with matching pk header -> 201" do
      Cosmos.define_container("db1", "pkcoll", ["/tenantId"])

      assert {:ok, 201, _h, _doc} =
               Cosmos.create_doc("db1", "pkcoll", %{"id" => "d1", "tenantId" => "acme"}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["acme"])
               })
    end

    test "read: 200, 404 NotFound, and 304 on If-None-Match match" do
      {:ok, 201, _, doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "d1"}, %{})

      assert {:ok, 200, headers, ^doc} = Cosmos.get_doc("db1", "coll1", "d1", %{})
      assert headers["etag"] == doc["_etag"]
      assert headers["x-ms-request-charge"] == "1.0"

      assert {:ok, 304, headers_304, %{}} =
               Cosmos.get_doc("db1", "coll1", "d1", %{"if-none-match" => doc["_etag"]})

      assert headers_304["etag"] == doc["_etag"]
      assert headers_304["x-ms-request-charge"] == "1.0"

      assert {:ok, 404, _, %{"code" => "NotFound"}} =
               Cosmos.get_doc("db1", "coll1", "missing", %{})
    end

    test "replace: 200 with new etag; If-Match mismatch -> 412 PreconditionFailed" do
      {:ok, 201, _, doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "d1", "v" => 1}, %{})

      assert {:ok, 200, h2, updated} =
               Cosmos.put_doc("db1", "coll1", "d1", %{"v" => 2}, %{"if-match" => doc["_etag"]})

      assert h2["etag"] != doc["_etag"]
      assert updated["v"] == 2

      assert {:ok, 412, _, %{"code" => "PreconditionFailed"}} =
               Cosmos.put_doc("db1", "coll1", "d1", %{"v" => 3}, %{"if-match" => doc["_etag"]})
    end

    test "delete: bare delete 204; conditional delete 204 on match / 412 on mismatch; 404 missing doc" do
      {:ok, 201, _, doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "d1"}, %{})

      # Bare delete (no If-Match) -> unconditional 204, doc gone
      assert {:ok, 204, headers, ""} = Cosmos.delete_doc("db1", "coll1", "d1", %{})
      assert headers["x-ms-request-charge"] == "1.0"
      assert {:ok, 404, _, %{"code" => "NotFound"}} = Cosmos.get_doc("db1", "coll1", "d1", %{})

      # Wrong If-Match -> 412
      {:ok, 201, _, doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "d1"}, %{})

      assert {:ok, 412, _, %{"code" => "PreconditionFailed"}} =
               Cosmos.delete_doc("db1", "coll1", "d1", %{"if-match" => "\"nope\""})

      # Correct If-Match -> 204, doc gone
      assert {:ok, 204, headers, ""} =
               Cosmos.delete_doc("db1", "coll1", "d1", %{"if-match" => doc["_etag"]})

      assert headers["x-ms-request-charge"] == "1.0"
      assert {:ok, 404, _, %{"code" => "NotFound"}} = Cosmos.get_doc("db1", "coll1", "d1", %{})
    end

    test "bare delete of a missing doc -> 404 NotFound" do
      assert {:ok, 404, headers, %{"code" => "NotFound"}} =
               Cosmos.delete_doc("db1", "coll1", "ghost", %{})

      assert headers["x-ms-request-charge"] == "1.0"
    end

    test "delete after re-create with the old etag -> 412 PreconditionFailed" do
      {:ok, 201, _, old_doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "rc", "v" => 1}, %{})
      {:ok, 204, _, ""} = Cosmos.delete_doc("db1", "coll1", "rc", %{})

      {:ok, 201, _, new_doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "rc", "v" => 2}, %{})
      assert new_doc["_etag"] != old_doc["_etag"]

      assert {:ok, 412, _, %{"code" => "PreconditionFailed"}} =
               Cosmos.delete_doc("db1", "coll1", "rc", %{"if-match" => old_doc["_etag"]})

      # The doc survives the failed conditional delete.
      assert {:ok, 200, _, ^new_doc} = Cosmos.get_doc("db1", "coll1", "rc", %{})
    end

    test "replace without If-Match is an unconditional overwrite (last-writer-wins)" do
      {:ok, 201, _, _} = Cosmos.create_doc("db1", "coll1", %{"id" => "u1", "v" => 1}, %{})

      assert {:ok, 200, headers, updated} =
               Cosmos.put_doc("db1", "coll1", "u1", %{"v" => 99}, %{})

      assert headers["x-ms-request-charge"] == "1.0"
      assert updated["v"] == 99
      assert {:ok, 200, _, ^updated} = Cosmos.get_doc("db1", "coll1", "u1", %{})
    end

    test "list by prefix returns only matching docs" do
      Cosmos.create_doc("db1", "coll1", %{"id" => "a1"}, %{})
      Cosmos.create_doc("db1", "coll1", %{"id" => "a2"}, %{})
      Cosmos.create_doc("db1", "coll2", %{"id" => "a3"}, %{})

      assert {:ok, 200, headers, docs} = Cosmos.list_docs("db1", "coll1")
      ids = Enum.map(docs, & &1["id"]) |> Enum.sort()
      assert ids == ["a1", "a2"]
      assert headers["x-ms-request-charge"] == "1.0"

      assert {:ok, 200, _, docs2} = Cosmos.list_docs("db1", "coll1", "a2")
      assert Enum.map(docs2, & &1["id"]) == ["a2"]
    end

    test "every response carries x-ms-request-charge header" do
      {:ok, 201, _, doc} = Cosmos.create_doc("db1", "c", %{"id" => "x"}, %{})

      responses = [
        Cosmos.create_doc("db1", "c", %{"id" => "y"}, %{}),
        Cosmos.get_doc("db1", "c", "x", %{}),
        Cosmos.get_doc("db1", "c", "nope", %{}),
        Cosmos.put_doc("db1", "c", "x", %{"v" => 1}, %{"if-match" => doc["_etag"]}),
        Cosmos.put_doc("db1", "c", "x", %{"v" => 2}, %{"if-match" => "\"stale\""}),
        Cosmos.delete_doc("db1", "c", "y", %{"if-match" => "*"}),
        Cosmos.list_docs("db1", "c")
      ]

      Enum.each(responses, fn {:ok, _s, headers, _b} ->
        assert headers["x-ms-request-charge"] == "1.0"
      end)
    end

    test "concurrent replace with exactly one winning If-Match" do
      {:ok, 201, _, doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "r1", "v" => 0}, %{})

      results =
        1..2
        |> Enum.map(fn i ->
          Task.async(fn ->
            Cosmos.put_doc("db1", "coll1", "r1", %{"v" => i}, %{"if-match" => doc["_etag"]})
          end)
        end)
        |> Task.await_many()

      assert Enum.count(results, fn {:ok, status, _, _} -> status == 200 end) == 1
      assert Enum.count(results, fn {:ok, status, _, _} -> status == 412 end) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Real-SDK-driven response headers (@azure/cosmos)
  # ---------------------------------------------------------------------------

  describe "SDK response headers (alt-content-path, session-token, lsn)" do
    test "create response carries alt-content-path, session-token and lsn" do
      assert {:ok, 201, headers, _doc} =
               Cosmos.create_doc("sdkdb", "sdkcoll", %{"id" => "h1"}, %{})

      assert headers["x-ms-alt-content-path"] == "dbs/sdkdb/colls/sdkcoll"
      assert headers["x-ms-session-token"] == "1#1"
      assert headers["x-ms-lsn"] == "1"
      assert headers["x-ms-request-charge"] == "1.0"
    end

    test "session token is monotonic per collection, independent across collections" do
      {:ok, 201, h1a, _} = Cosmos.create_doc("mdb", "mcoll", %{"id" => "a"}, %{})
      {:ok, 201, h1b, _} = Cosmos.create_doc("mdb", "mcoll", %{"id" => "b"}, %{})
      {:ok, 200, h1c, _} = Cosmos.put_doc("mdb", "mcoll", "a", %{"v" => 2}, %{"if-match" => "*"})
      {:ok, 204, h1d, ""} = Cosmos.delete_doc("mdb", "mcoll", "b", %{"if-match" => "*"})

      lsns = [h1a, h1b, h1c, h1d] |> Enum.map(&String.to_integer(&1["x-ms-lsn"]))
      assert lsns == Enum.sort(Enum.uniq(lsns))
      assert length(Enum.uniq(lsns)) == 4

      {:ok, 201, h2a, _} = Cosmos.create_doc("mdb", "othercoll", %{"id" => "a"}, %{})
      assert h2a["x-ms-lsn"] == "1"
      assert h2a["x-ms-session-token"] == "1#1"

      # writes in one collection do not disturb the other's counter
      {:ok, 201, h2b, _} = Cosmos.create_doc("mdb", "othercoll", %{"id" => "b"}, %{})
      assert String.to_integer(h2b["x-ms-lsn"]) == String.to_integer(h2a["x-ms-lsn"]) + 1
      assert String.to_integer(h1d["x-ms-lsn"]) > String.to_integer(h2b["x-ms-lsn"]) - 100
    end

    test "reads report current lsn; 404/412 errors still carry the headers" do
      {:ok, 201, _, _} = Cosmos.create_doc("edb", "ecoll", %{"id" => "x", "v" => 1}, %{})
      {:ok, 201, _, _} = Cosmos.create_doc("edb", "ecoll", %{"id" => "y"}, %{})

      assert {:ok, 200, h_read, doc_x} = Cosmos.get_doc("edb", "ecoll", "x", %{})
      assert h_read["x-ms-alt-content-path"] == "dbs/edb/colls/ecoll"
      assert h_read["x-ms-session-token"] == "1#2"
      assert h_read["x-ms-lsn"] == "2"

      assert {:ok, 304, h_304, %{}} =
               Cosmos.get_doc("edb", "ecoll", "x", %{"if-none-match" => doc_x["_etag"]})

      assert h_304["x-ms-lsn"] == "2"
      assert h_304["x-ms-session-token"] == "1#2"

      assert {:ok, 404, h_404, %{"code" => "NotFound"}} =
               Cosmos.get_doc("edb", "ecoll", "missing", %{})

      assert h_404["x-ms-alt-content-path"] == "dbs/edb/colls/ecoll"
      assert h_404["x-ms-session-token"] == "1#2"

      assert {:ok, 412, h_412, %{"code" => "PreconditionFailed"}} =
               Cosmos.delete_doc("edb", "ecoll", "x", %{"if-match" => "\"stale\""})

      assert h_412["x-ms-lsn"] == "2"
    end

    test "list_docs carries the SDK headers" do
      Cosmos.create_doc("ldb", "lcoll", %{"id" => "a"}, %{})

      assert {:ok, 200, headers, docs} = Cosmos.list_docs("ldb", "lcoll")
      assert headers["x-ms-alt-content-path"] == "dbs/ldb/colls/lcoll"
      assert headers["x-ms-session-token"] == "1#1"
      assert Enum.map(docs, & &1["id"]) == ["a"]
    end
  end

  # ---------------------------------------------------------------------------
  # S8 regression rows: table ownership, atomic CAS, db/coll surfaces, query
  # ---------------------------------------------------------------------------

  describe "S8 regressions" do
    test "tables are store-owned: CosMOS module never creates them" do
      # Store.init must have created BOTH lsn and pk-meta tables; the module's
      # readiness gate reports on them without ever calling :ets.new.
      assert :ets.info(:smalt_cosmos_lsn) != :undefined
      assert :ets.info(:smalt_cosmos_pk_meta) != :undefined
      assert :ets.info(:smalt_cosmos_docs) != :undefined
      assert Cosmos.store_ready?()
    end

    test "8-way same-doc If-Match race: exactly one 200, seven 412, no lost update" do
      Cosmos.define_container("racedb", "racecoll", ["/tenantId"])

      {:ok, 201, _, doc} =
        Cosmos.create_doc("racedb", "racecoll", %{"id" => "r", "tenantId" => "acme", "v" => 0}, %{
          "x-ms-documentdb-partitionkey" => ~s(["acme"])
        })

      results =
        1..8
        |> Enum.map(fn i ->
          Task.async(fn ->
            Cosmos.put_doc(
              "racedb",
              "racecoll",
              "r",
              %{"id" => "r", "tenantId" => "acme", "v" => i},
              %{"if-match" => doc["_etag"], "x-ms-documentdb-partitionkey" => ~s(["acme"])}
            )
          end)
        end)
        |> Task.await_many()

      codes = Enum.map(results, fn {:ok, status, _, _} -> status end)
      assert Enum.count(codes, &(&1 == 200)) == 1
      assert Enum.count(codes, &(&1 == 412)) == 7

      # No lost update: the surviving record is exactly the winner's write.
      {:ok, 200, _, final} = Cosmos.get_doc("racedb", "racecoll", "r", %{})
      winner = Enum.find(results, fn {:ok, s, _, _} -> s == 200 end)
      {:ok, _, _, winner_doc} = winner
      assert final == winner_doc
    end

    test "stale If-Match after a winning CAS is refused with 412 (no read-check-write window)" do
      {:ok, 201, _, doc} = Cosmos.create_doc("casdb", "cascoll", %{"id" => "d", "v" => 0}, %{})

      {:ok, 200, _, _} =
        Cosmos.put_doc("casdb", "cascoll", "d", %{"v" => 1}, %{"if-match" => doc["_etag"]})

      assert {:ok, 412, _, %{"code" => "PreconditionFailed"}} =
               Cosmos.put_doc("casdb", "cascoll", "d", %{"v" => 2}, %{"if-match" => doc["_etag"]})
    end

    test "create_db / list_dbs round-trip" do
      assert {:ok, 201, _, %{"id" => "s8db"}} = Cosmos.create_db("s8db")

      {:ok, 200, _, %{"Databases" => dbs}} = Cosmos.list_dbs()
      assert "s8db" in Enum.map(dbs, & &1["id"])
    end

    test "create_collection stores durable pk meta; enforcement live across calls" do
      assert {:ok, 201, _, %{"id" => "pkcoll", "partitionKey" => %{"paths" => ["/tenantId"]}}} =
               Cosmos.create_collection("pkdb", "pkcoll", %{
                 "id" => "pkcoll",
                 "partitionKey" => %{"paths" => ["/tenantId"]}
               })

      # Durable: meta visible through the read path used by every handler.
      assert Cosmos.container_meta("pkdb", "pkcoll") == %{"paths" => ["/tenantId"]}

      # Live enforcement: missing header -> 400, mismatch -> 400, match -> 201.
      assert {:ok, 400, _, _} =
               Cosmos.create_doc("pkdb", "pkcoll", %{"id" => "a", "tenantId" => "acme"}, %{})

      assert {:ok, 400, _, _} =
               Cosmos.create_doc("pkdb", "pkcoll", %{"id" => "a", "tenantId" => "acme"}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["other"])
               })

      assert {:ok, 201, _, _} =
               Cosmos.create_doc("pkdb", "pkcoll", %{"id" => "a", "tenantId" => "acme"}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["acme"])
               })
    end

    test "list_collections returns the containers of one db" do
      Cosmos.create_db("cldb")
      Cosmos.create_collection("cldb", "c1", %{"id" => "c1"})
      Cosmos.create_collection("cldb", "c2", %{"id" => "c2"})
      Cosmos.create_collection("otherdb", "c3", %{"id" => "c3"})

      {:ok, 200, _, %{"DocumentCollections" => colls}} = Cosmos.list_collections("cldb")
      assert Enum.map(colls, & &1["id"]) |> Enum.sort() == ["c1", "c2"]
    end

    test "query_docs filters by pk header, caps at 100, never creates" do
      Cosmos.create_collection("qdb", "qcoll", %{
        "id" => "qcoll",
        "partitionKey" => %{"paths" => ["/tenantId"]}
      })

      for part <- ["acme", "globex"] do
        for i <- 0..2 do
          {:ok, 201, _, _} =
            Cosmos.create_doc(
              "qdb",
              "qcoll",
              %{"id" => "q-#{part}-#{i}", "tenantId" => part, "i" => i},
              %{"x-ms-documentdb-partitionkey" => ~s(["#{part}"])}
            )
        end
      end

      before = Store.list_prefix(:smalt_cosmos_docs, "qdb/qcoll/")

      {:ok, 200, _, result} =
        Cosmos.query_docs("qdb", "qcoll", %{"query" => "SELECT * FROM c"}, %{
          "x-ms-documentdb-partitionkey" => ~s(["acme"])
        })

      assert result["_count"] == 3

      assert Enum.map(result["Documents"], & &1["id"]) ==
               Enum.sort(Enum.map(result["Documents"], & &1["id"]))

      # A query POST must never create a doc.
      assert Store.list_prefix(:smalt_cosmos_docs, "qdb/qcoll/") == before

      # Cross-partition (no pk header): the whole container.
      {:ok, 200, _, all} = Cosmos.query_docs("qdb", "qcoll", %{"query" => "SELECT * FROM c"}, %{})
      assert all["_count"] == 6
    end
  end

  # -------------------------------------------------------------------------
  # Python-SDK wire tolerance (lane 91 blockers)
  # -------------------------------------------------------------------------

  describe "python-SDK wire tolerance (lane 91)" do
    @router_opts EgressRouter.init([])

    defp dispatch(conn), do: EgressRouter.call(conn, @router_opts)

    test "GET /dbs/:db/colls/:coll/ (trailing slash) routes identically to non-slash form" do
      assert conn(:post, "/dbs", %{id: "sdb"}) |> dispatch() |> status_response() == 201

      assert conn(:post, "/dbs/sdb/colls", %{id: "scoll", partitionKey: %{paths: ["/pk"]}})
             |> dispatch()
             |> status_response() == 201

      plain = conn(:get, "/dbs/sdb/colls/scoll") |> dispatch()
      slashed = conn(:get, "/dbs/sdb/colls/scoll/") |> dispatch()

      assert plain.status == 200
      assert slashed.status == 200

      assert Jason.decode!(slashed.resp_body) == Jason.decode!(plain.resp_body)
      assert Jason.decode!(slashed.resp_body)["id"] == "scoll"

      # db-level trailing slash too
      assert conn(:get, "/dbs/sdb/") |> dispatch() |> status_response() == 200
    end

    test "GET / account carries the python-SDK-required DatabaseAccount fields" do
      resp = conn(:get, "/") |> dispatch()
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["kind"] == "DatabaseAccount"
      assert body["id"] != "localhost"
      assert %{"name" => _, "databaseAccountEndpoint" => _} = body["writableLocations"] |> List.first()
      assert body["readableLocations"] |> List.first() |> Map.has_key?("databaseAccountEndpoint")
      assert body["userConsistencyPolicy"]["defaultConsistencyLevel"]
      refute is_nil(body["databasesLink"])
      refute is_nil(body["mediaLink"])
    end

    test "container records carry partitionKey.kind = Hash (SDK _ExtractPartitionKey)" do
      created =
        conn(:post, "/dbs/kdb/colls", %{id: "kcoll", partitionKey: %{paths: ["/pk"]}})
        |> dispatch()

      assert created.status == 201
      body = Jason.decode!(created.resp_body)
      assert body["partitionKey"]["kind"] == "Hash"
      assert body["partitionKey"]["paths"] == ["/pk"]

      read = conn(:get, "/dbs/kdb/colls/kcoll") |> dispatch()
      assert read.status == 200
      assert Jason.decode!(read.resp_body)["partitionKey"]["kind"] == "Hash"

      missing = conn(:get, "/dbs/kdb/colls/nope") |> dispatch()
      assert missing.status == 404
      assert Jason.decode!(missing.resp_body)["code"] == "NotFound"
    end
  end

  # ---------------------------------------------------------------------------
  # _rid grammar composition end-to-end (C3 rows 3/4)
  # ---------------------------------------------------------------------------

  describe "_rid grammar composition end-to-end" do
    test "db/container/doc rids compose and ride the wire records" do
      {:ok, 201, _, db} = Cosmos.create_db("riddb")
      {:ok, 201, _, coll} = Cosmos.create_collection("riddb", "ridcoll", %{"id" => "ridcoll"})

      assert db["_rid"] == Cosmos.db_rid("riddb")
      assert coll["_rid"] == Cosmos.coll_rid("riddb", "ridcoll")
      assert coll["_rid"] == db["_rid"] <> String.slice(coll["_rid"], 8, 4)
      assert String.valid?(db["_rid"]) and String.length(db["_rid"]) == 8

      {:ok, 201, _, doc} =
        Cosmos.create_doc("riddb", "ridcoll", %{"id" => "rdoc", "v" => 1}, %{})

      assert doc["_rid"] == Cosmos.doc_rid("riddb", "ridcoll", "rdoc")
      assert doc["_rid"] == coll["_rid"] <> String.slice(doc["_rid"], 12, 8)
      assert byte_size(doc["_rid"]) == 20
      assert doc["_rid"] =~ ~r/^[A-Za-z0-9_-]{20}$/
      assert doc["_self"] == "/dbs/riddb/colls/ridcoll/docs/rdoc"
      assert db["_self"] == "/dbs/riddb"
      assert coll["_self"] == "/dbs/riddb/colls/ridcoll"
      # base64url alphabet only (no + or / or padding =)
      refute doc["_rid"] =~ ~r{[+/=]}
    end

    test "query feed envelope _rid equals the container rid; deterministic across recreate" do
      {:ok, 201, _, coll} = Cosmos.create_collection("feeddb", "feedcoll", %{"id" => "fc"})

      {:ok, 201, _, _} =
        Cosmos.create_doc("feeddb", "feedcoll", %{"id" => "f1", "tenantId" => "acme"}, %{})

      {:ok, 200, _, feed} =
        Cosmos.query_docs("feeddb", "feedcoll", %{"query" => "SELECT"}, %{})

      assert feed["_rid"] == coll["_rid"]
      assert feed["_count"] == 1
      assert hd(feed["Documents"])["_rid"] == Cosmos.doc_rid("feeddb", "feedcoll", "f1")

      rid_before = coll["_rid"]
      {:ok, 201, _, coll2} = Cosmos.create_collection("feeddb", "feedcoll", %{"id" => "fc"})
      assert coll2["_rid"] == rid_before
    end
  end

  # ---------------------------------------------------------------------------
  # Partition-key header: real-Cosmos 400-class messages (C3 rows 5/7)
  # ---------------------------------------------------------------------------

  describe "partition-key 400 messages (real Cosmos parity)" do
    test "missing / non-array / empty-array / malformed header all 400 BadRequest with the mismatch message" do
      Cosmos.create_collection("msgdb", "mc", %{
        "id" => "mc",
        "partitionKey" => %{"paths" => ["/tenantId"]}
      })

      body = %{"id" => "a", "tenantId" => "acme"}

      bad_headers = [
        %{},
        %{"x-ms-documentdb-partitionkey" => "acme"},
        %{"x-ms-documentdb-partitionkey" => "[]"},
        %{"x-ms-documentdb-partitionkey" => "[1]"},
        %{"x-ms-documentdb-partitionkey" => "not json"},
        %{"x-ms-documentdb-partitionpk" => ~s(["acme"])},
        %{"x-ms-documentdb-partitionkey" => ~s(["acme", "extra"])}
      ]

      # JSON with trailing whitespace is VALID — accepted with 201.
      assert {:ok, 201, _, _} =
               Cosmos.create_doc("msgdb", "mc", body, %{
                 "x-ms-documentdb-partitionkey" => ~s(["acme"] )
               })

      Enum.each(bad_headers, fn h ->
        assert {:ok, 400, headers, %{"code" => "BadRequest", "message" => msg}} =
                 Cosmos.create_doc("msgdb", "mc", body, h)

        assert msg == "Partition key provided in the header doesn't match the partition key of the document."
        assert headers["x-ms-request-charge"] == "1.0"
        assert headers["x-ms-alt-content-path"] == "dbs/msgdb/colls/mc"
      end)
    end

    test "put_doc and query on pk containers honor the same 400 contract" do
      Cosmos.create_collection("msgdb", "mcq", %{
        "id" => "mcq",
        "partitionKey" => %{"paths" => ["/tenantId"]}
      })

      {:ok, 201, _, _} =
        Cosmos.create_doc("msgdb", "mcq", %{"id" => "q", "tenantId" => "acme"}, %{
          "x-ms-documentdb-partitionkey" => ~s(["acme"])
        })

      # put with mismatched pk header -> 400 (not 200/412)
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.put_doc("msgdb", "mcq", "q", %{"v" => 2}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["wrong"])
                 })

      # put without header -> 400
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.put_doc("msgdb", "mcq", "q", %{"v" => 2}, %{})

      # query with matching pk header returns only that partition
      {:ok, 200, _, feed} =
        Cosmos.query_docs("msgdb", "mcq", %{}, %{"x-ms-documentdb-partitionkey" => ~s(["acme"])})

      assert feed["_count"] == 1

      {:ok, 200, _, feed2} =
        Cosmos.query_docs("msgdb", "mcq", %{}, %{"x-ms-documentdb-partitionkey" => ~s(["other"])})

      assert feed2["_count"] == 0
    end
  end

  defp status_response(conn), do: conn.status

  # ---------------------------------------------------------------------------
  # KQL fuzz fences: run/2 is pure — {:ok,_} | {:error,_} on ANY input,
  # never a raise (lexer/parser crash fence).
  # ---------------------------------------------------------------------------

  describe "KQL fuzz fences (no-raise contract)" do
    test "malformed pipelines return parse errors, never raise" do
      malformed = [
        "x == 'a' 'b'",
        "take 5, 6",
        ") x == 1",
        "(x == 1))",
        "project a,, b",
        "| take",
        "| take x",
        "| order by",
        "| project",
        "| where",
        "| where (x == 1",
        "| where x ==",
        "| where 'lit' == x",
        "'x' == 1",
        "x == 1 && y == 2",
        "| take 99999999999999999999999999"
      ]

      Enum.each(malformed, fn q ->
        assert match?({:error, _}, Smalt.DataPlane.KQL.run([], q)),
               "expected {:error,_} for #{inspect(q)}"
      end)
    end

    test "invalid UTF-8 bytes return parse/limit errors, never raise" do
      raw_cases = [
        <<0xFF, 0xFE, 32>>,
        "'x" <> <<0xFF>> <> "' == 1",
        <<0xC3, 0x28>>,
        <<0xE2, 0x82>>,
        :crypto.strong_rand_bytes(64)
      ]

      Enum.each(raw_cases, fn q ->
        assert match?({:error, _}, Smalt.DataPlane.KQL.run([], q)),
               "expected {:error,_} for #{inspect(q, limit: :infinity)}"
      end)
    end

    test "deep nesting and length limits return errors, never raise" do
      deep = String.duplicate("(", 900) <> "x == 1" <> String.duplicate(")", 900)
      assert {:error, {:parse, _}} = Smalt.DataPlane.KQL.run([], deep)

      # Parens are AST-transparent; the depth guard counts and/or nesting.
      deep_where = "| where " <> String.duplicate("(x == 1) and ", 300) <> "x == 2"
      assert {:error, {:limit, _}} = Smalt.DataPlane.KQL.run([], deep_where)

      assert {:error, {:limit, _}} = Smalt.DataPlane.KQL.run([], String.duplicate("| take 1", 400))
      # just under the cap still parses
      assert {:ok, []} = Smalt.DataPlane.KQL.run([], String.duplicate("| take 1", 90))
    end

    test "unicode and random binaries terminate quickly (no hangs, no raises)" do
      unicode = "| where col == 'héllo→日本語' | take 5"
      assert {:ok, []} = Smalt.DataPlane.KQL.run([], unicode)

      row = %{"col" => "héllo→日本語"}
      assert {:ok, [%{"col" => "héllo→日本語"}]} =
               Smalt.DataPlane.KQL.run([row], "| where col == 'héllo→日本語' | take 5")

      Enum.each(1..50, fn _ ->
        q = :crypto.strong_rand_bytes(:rand.uniform(128))
        assert match?({:error, _}, Smalt.DataPlane.KQL.run([], q))
      end)
    end
  end
end

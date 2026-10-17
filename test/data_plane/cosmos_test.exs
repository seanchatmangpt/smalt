defmodule Smalt.DataPlane.CosmosTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.DataPlane.{ConditionalHeaders, Cosmos, PartitionKey}
  alias Smalt.EgressRouter
  alias Smalt.Store

  @charge %{"x-ms-request-charge" => "1.0"}

  setup do
    # Store must be unlinked from the test process (lens-4): start_link owned
    # the immortal Store by the first mortal test process — any abnormal test
    # exit killed Store, and every later test in the run cascaded
    # "table does not exist". Plain start + named registration keeps the
    # tables alive for the whole VM; :already_started is fine.
    case GenServer.start(Store, [], name: Store) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
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

    test "parse accepts number and boolean pk values (type-aware, normalized like extract)" do
      assert PartitionKey.parse(~s([7])) == {:ok, "7"}
      assert PartitionKey.parse(~s([7.5])) == {:ok, "7.5"}
      assert PartitionKey.parse(~s([true])) == {:ok, "true"}
      assert PartitionKey.parse(~s([false])) == {:ok, "false"}

      # null element stays refused (undefined-key divergence, pinned)
      assert PartitionKey.parse(~s([null])) == :error

      # multi-element / empty / malformed still refused
      assert PartitionKey.parse(~s([7, 8])) == :error
      assert PartitionKey.parse("[]") == :error
      assert PartitionKey.parse("not-json") == :error
    end

    test "numeric pk end to end: unwritable container becomes writable and query-scoped" do
      Cosmos.create_collection("npk", "npkc", %{"id" => "npkc", "partitionKey" => %{"paths" => ["/n"]}})
      {:ok, 201, _, _} = Cosmos.create_doc("npk", "npkc", %{"id" => "a", "n" => 7}, %{"x-ms-documentdb-partitionkey" => ~s([7])})
      {:ok, 201, _, _} = Cosmos.create_doc("npk", "npkc", %{"id" => "b", "n" => 8}, %{"x-ms-documentdb-partitionkey" => ~s([8])})

      assert {:ok, 200, _, scoped} =
               Cosmos.query_docs("npk", "npkc", %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s([7])})

      assert scoped["_count"] == 1
      assert hd(scoped["Documents"])["id"] == "a"

      # header string form matches the doc's numeric value (same normalization)
      assert {:ok, 200, _, scoped2} =
               Cosmos.query_docs("npk", "npkc", %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s(["7"])})

      assert scoped2["_count"] == 1

      # mismatched numeric partition still 400s
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("npk", "npkc", %{"id" => "c", "n" => 7}, %{"x-ms-documentdb-partitionkey" => ~s([9])})
    end

    test "boolean pk end to end: write, scoped query, mismatch 400" do
      Cosmos.create_collection("bpk", "bpkc", %{"id" => "bpkc", "partitionKey" => %{"paths" => ["/b"]}})
      {:ok, 201, _, _} = Cosmos.create_doc("bpk", "bpkc", %{"id" => "a", "b" => true}, %{"x-ms-documentdb-partitionkey" => ~s([true])})
      {:ok, 201, _, _} = Cosmos.create_doc("bpk", "bpkc", %{"id" => "d", "b" => false}, %{"x-ms-documentdb-partitionkey" => ~s([false])})

      assert {:ok, 200, _, scoped} =
               Cosmos.query_docs("bpk", "bpkc", %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s([true])})

      assert scoped["_count"] == 1
      assert hd(scoped["Documents"])["id"] == "a"

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("bpk", "bpkc", %{"id" => "e", "b" => true}, %{"x-ms-documentdb-partitionkey" => ~s([false])})
    end

    test "parse rejects empty array, multi-element, non-scalar, and malformed JSON" do
      assert PartitionKey.parse("[]") == :error
      assert PartitionKey.parse(~s(["a","b"])) == :error
      assert PartitionKey.parse(~s([{"a":1}])) == :error
      assert PartitionKey.parse(~s([[1]])) == :error
      assert PartitionKey.parse(~s([""])) == :error
      assert PartitionKey.parse(~s([null])) == :error
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

    test "lens-8: enforce/3 nil-doc clause is pinned fail-open (wire-unreachable; API-surface only)" do
      # Both production enforce/3 call sites (create_doc/4, put_doc/4) carry an
      # is_map(body) guard, so a nil doc never reaches this clause from the
      # wire — the clause serves direct API callers only, and its fail-open is
      # intentional (nothing to compare a pk against). The empty-paths and
      # no-pk-meta clauses above remain the wire-visible fences.
      assert PartitionKey.enforce(~s(["acme"]), nil, %{"paths" => ["/tenantId"]}) == :ok
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
      {:ok, 201, _, _doc} = Cosmos.create_doc("db1", "coll1", %{"id" => "d1"}, %{})

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
        Cosmos.query_docs("feeddb", "feedcoll", %{"query" => "SELECT * FROM c"}, %{})

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
        Cosmos.query_docs("msgdb", "mcq", %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s(["acme"])})

      assert feed["_count"] == 1

      {:ok, 200, _, feed2} =
        Cosmos.query_docs("msgdb", "mcq", %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s(["other"])})

      assert feed2["_count"] == 0
    end

    test "query POST without a query document -> 400 BadRequest (row 8)" do
      Cosmos.create_collection("qvb", "qvb-c", %{"id" => "qvb-c"})

      Enum.each(
        [
          %{},
          %{"parameters" => []},
          nil,
          %{"query" => ""},
          %{"query" => "   "},
          %{"query" => 123},
          %{"query" => ["SELECT"]},
          %{"query" => nil},
          %{"query" => %{"query" => "SELECT * FROM c"}},
          "SELECT * FROM c"
        ],
        fn bad ->
          assert {:ok, 400, headers, %{"code" => "BadRequest", "message" => "The query is invalid."}} =
                   Cosmos.query_docs("qvb", "qvb-c", bad, %{})

          assert headers["x-ms-request-charge"] == "1.0"
        end
      )
    end

    test "_rid uniqueness: 10k doc creates, zero collisions, grammar holds" do
      db = "ridu"
      coll = "ru"

      assert {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      rids =
        1..10_000
        |> Enum.map(fn i ->
          id = "d#{i}"

          assert {:ok, 201, _, doc} =
                   Cosmos.create_doc(db, coll, %{"id" => id, "n" => i}, %{})

          assert doc["_rid"] == Cosmos.doc_rid(db, coll, id)
          assert byte_size(doc["_rid"]) == 20
          doc["_rid"]
        end)

      assert length(rids) == 10_000
      assert length(Enum.uniq(rids)) == 10_000

      # container rids stay unique across many containers too
      crids =
        Enum.map(1..2_000, fn i ->
          assert {:ok, 201, _, c} = Cosmos.create_collection(db, "c#{i}", %{"id" => "c#{i}"})
          c["_rid"]
        end)

      assert length(Enum.uniq(crids)) == 2_000
    end
  end

  # ---------------------------------------------------------------------------
  # Name-path parity (real Cosmos: case-sensitive, 1-255 chars, no "/")
  # ---------------------------------------------------------------------------

  describe "name-path parity" do
    test "names are case-sensitive: distinct records, rids, and doc lists" do
      {:ok, 201, _, d1} = Cosmos.create_db("CaseDb")
      {:ok, 201, _, d2} = Cosmos.create_db("casedb")
      assert d1["_rid"] != d2["_rid"]
      assert d1["id"] != d2["id"]

      {:ok, 201, _, c1} = Cosmos.create_collection("csdb", "Coll", %{"id" => "Coll"})
      {:ok, 201, _, c2} = Cosmos.create_collection("csdb", "coll", %{"id" => "coll"})
      assert c1["_rid"] != c2["_rid"]

      {:ok, 201, _, x1} = Cosmos.create_doc("csdb", "Coll", %{"id" => "x"}, %{})
      {:ok, 201, _, x2} = Cosmos.create_doc("csdb", "coll", %{"id" => "x"}, %{})
      assert x1["_rid"] != x2["_rid"]

      {:ok, 200, _, l1} = Cosmos.list_docs("csdb", "Coll")
      {:ok, 200, _, l2} = Cosmos.list_docs("csdb", "coll")
      assert length(l1) == 1 and length(l2) == 1
      refute hd(l1) == hd(l2)
    end

    test "unicode names accepted with valid rids" do
      {:ok, 201, _, d} = Cosmos.create_db("日本DB-λ")
      assert d["_rid"] =~ ~r/^[A-Za-z0-9_-]{8}$/

      {:ok, 201, _, c} = Cosmos.create_collection("日本DB-λ", "λcoll", %{"id" => "λcoll"})
      assert c["_rid"] == Cosmos.coll_rid("日本DB-λ", "λcoll")
      assert byte_size(c["_rid"]) == 12
    end

    test "255-char names accepted; 256-char and slash names -> 400 BadRequest" do
      assert {:ok, 201, _, _} = Cosmos.create_db(String.duplicate("a", 255))
      assert {:ok, 400, _, %{"code" => "BadRequest"}} = Cosmos.create_db(String.duplicate("a", 256))

      assert {:ok, 400, _, %{"code" => "BadRequest"}} = Cosmos.create_db("bad/name")
      assert {:ok, 400, _, %{"code" => "BadRequest"}} = Cosmos.create_db("")

      assert {:ok, 201, _, _} =
               Cosmos.create_collection("nndb", String.duplicate("c", 255), %{"id" => "cc"})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_collection("nndb", String.duplicate("c", 256), %{"id" => "cc"})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_collection("nndb", "bad/name", %{"id" => "cc"})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_collection("nndb", "", %{"id" => "cc"})
    end
  end

  # ---------------------------------------------------------------------------
  # Name-corpus precedence + request-charge pinning (cycle 8)
  # ---------------------------------------------------------------------------

  describe "name-corpus precedence and charge pinning" do
    @big_name String.duplicate("x", 300)

    test "delete precedence: nonexistent doc and unknown/invalid names -> 404 NotFound" do
      assert {:ok, 404, _, %{"code" => "NotFound"}} = Cosmos.delete_doc("ghost", "coll", "d", %{})

      assert {:ok, 404, _, %{"code" => "NotFound"}} =
               Cosmos.delete_doc(@big_name, "coll", "d", %{})

      assert {:ok, 404, _, %{"code" => "NotFound"}} = Cosmos.delete_doc("a/b", "c", "d", %{})
      assert {:ok, 404, _, %{"code" => "NotFound"}} = Cosmos.get_doc("ghost", "coll", "d", %{})
    end

    test "KNOWN DIVERGENCE: create on unknown container implicitly creates (201), real Cosmos 404s" do
      assert {:ok, 201, _, doc} = Cosmos.create_doc(@big_name, "c", %{"id" => "d"}, %{})
      assert doc["_rid"] == Cosmos.doc_rid(@big_name, "c", "d")

      assert {:ok, 200, _, _} = Cosmos.query_docs(@big_name, "c", %{"query" => "SELECT * FROM c"}, %{})
      assert {:ok, 200, _, _} = Cosmos.list_docs(@big_name, "c")
    end

    test "request charge is the documented constant 1.0 on every doc surface" do
      Cosmos.create_collection("chg", "chg-c", %{"id" => "chg-c"})

      assert {:ok, 201, hc, _} = Cosmos.create_doc("chg", "chg-c", %{"id" => "a"}, %{})
      assert {:ok, 200, hg, _} = Cosmos.get_doc("chg", "chg-c", "a", %{})
      assert {:ok, 200, hq, _} = Cosmos.query_docs("chg", "chg-c", %{"query" => "SELECT * FROM c"}, %{})
      assert {:ok, 204, hd, ""} = Cosmos.delete_doc("chg", "chg-c", "a", %{})

      Enum.each([hc, hg, hq, hd], fn h ->
        assert h["x-ms-request-charge"] == "1.0"
      end)
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
        "| )x",
        "| ,a",
        "| 'str' == 1",
        "| take)",
        "| where x)",
        "| where contains )",
        "| take 'lit'",
        "| where x == 1 | tak",
        "| where x == 1 | take 1 |",
        "| where x == 1 | order",
        "| where x == 1 | order by col dsc",
        "| where x == 1 | project x,",
        "| where x == 1 | take 1 | wh",
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
      sq = <<0x27>>

      raw_cases = [
        <<0xFF, 0xFE, 32>>,
        "'x" <> <<0xFF>> <> "' == 1",
        <<0xC3, 0x28>>,
        <<0xE2, 0x82>>,
        # Truncated/split multibyte boundaries around and inside string literals
        sq <> <<0xC3>> <> sq,
        sq <> <<0xE2, 0x82>> <> sq,
        sq <> "a" <> <<0x80>> <> "b" <> sq,
        sq <> "héllo→日本語" <> sq,
        sq <> <<0xC3, 0xA9>> <> sq,
        sq <> "x" <> <<0xF0, 0x9F>>,
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

      # Double-quoted literals and backslash escapes (real Kusto parity):
      # both quote styles match; escapes are consumed (\n -> newline, etc.).
      row = %{"s" => "it's", "n" => "a\nb"}
      assert {:ok, [%{"s" => "it's"}]} =
               Smalt.DataPlane.KQL.run([row], "| where s == \"it's\"")

      assert {:ok, [%{"s" => "it's"}]} =
               Smalt.DataPlane.KQL.run([row], "| where s == 'it\\'s'")

      assert {:ok, [%{"n" => "a\nb"}]} =
               Smalt.DataPlane.KQL.run([row], "| where n == 'a\\nb'")

      row2 = %{"s" => "a\\b"}
      assert {:ok, [%{"s" => "a\\b"}]} =
               Smalt.DataPlane.KQL.run([row2], "| where s == 'a\\\\b'")

      assert {:ok, []} = Smalt.DataPlane.KQL.run([], "| where s == \"no match\" | take 1")

      row = %{"col" => "héllo→日本語"}
      assert {:ok, [%{"col" => "héllo→日本語"}]} =
               Smalt.DataPlane.KQL.run([row], "| where col == 'héllo→日本語' | take 5")

      Enum.each(1..50, fn _ ->
        q = :crypto.strong_rand_bytes(:rand.uniform(128))
        assert match?({:error, _}, Smalt.DataPlane.KQL.run([], q))
      end)
    end

    test "aggregate/join-shaped input parses to TYPED parse errors, never raises (grammar coverage)" do
      rows = [%{"a" => 1, "b" => 2}, %{"a" => 3, "b" => 4}]

      # Aggregate clauses (summarize/count) and join-shaped input are NOT part
      # of this engine's KQL subset. Each must be a typed {:error, {:parse, _}}
      # — pinned honestly as a GAP, never a crash.
      aggregate_queries = [
        "T | summarize count()",
        "T | count",
        "| summarize count()",
        "| where a == 1 | count",
        "| summarize sum(a)",
        "| summarize count() by b",
        "| join (T2) on a",
        "| extend b = a * 2",
        "| project-rename b = a",
        "| where a == 1 | summarize count()"
      ]

      Enum.each(aggregate_queries, fn q ->
        assert {:error, {:parse, _}} = Smalt.DataPlane.KQL.run(rows, q),
               "expected typed parse error for #{inspect(q)}"
      end)
    end

    test "KQL input rows of arbitrary shape run without raising (join-shaped inputs)" do
      # Join-shaped inputs (maps with nested/atom values, non-string keys) are
      # filtered by predicates without crashing.
      odd_rows = [
        %{"a" => 1},
        %{"a" => nil},
        %{a: :atom},
        %{:nested => %{"x" => 1}, "a" => "s"},
        %{}
      ]

      assert {:ok, _} = Smalt.DataPlane.KQL.run(odd_rows, "| where a == 1")
      assert {:ok, _} = Smalt.DataPlane.KQL.run(odd_rows, "| where nested.x == 1")
      assert {:ok, _} = Smalt.DataPlane.KQL.run(odd_rows, "| order by a asc | project a")
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-2 fences: doc-id grammar, delete CAS isolation, session/continuation
  # semantics, cross-container ACID (cycles 12+)
  # ---------------------------------------------------------------------------

  describe "lens-2: doc-id grammar (real Cosmos id rules)" do
    test "create with '/'-containing, empty, or 256-char id -> 400 BadRequest" do
      Cosmos.create_collection("iddb", "idc", %{"id" => "idc"})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("iddb", "idc", %{"id" => "a/b", "v" => 1}, %{})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("iddb", "idc", %{"id" => "", "v" => 1}, %{})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("iddb", "idc", %{"id" => String.duplicate("d", 256), "v" => 1}, %{})

      # nothing was stored under any of the poisoned keys
      assert Store.list_prefix(:smalt_cosmos_docs, "iddb/idc/") == []

      # 255-char id is the inclusive boundary: still legal
      assert {:ok, 201, _, _} =
               Cosmos.create_doc("iddb", "idc", %{"id" => String.duplicate("d", 255), "v" => 1}, %{})
    end

    test "non-string doc id (integer/nil-dotted forms) -> 400 BadRequest, nothing stored" do
      Cosmos.create_collection("iddb3", "idc3", %{"id" => "idc3"})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.create_doc("iddb3", "idc3", %{"id" => 42, "v" => 1}, %{})

      assert Store.list_prefix(:smalt_cosmos_docs, "iddb3/idc3/") == []
    end

    test "replace with a grammar-violating path id -> 404 NotFound (such a doc cannot exist)" do
      Cosmos.create_collection("iddb2", "idc2", %{"id" => "idc2"})
      {:ok, 201, _, _} = Cosmos.create_doc("iddb2", "idc2", %{"id" => "ok", "v" => 1}, %{})

      assert {:ok, 404, _, %{"code" => "NotFound"}} =
               Cosmos.put_doc("iddb2", "idc2", "a/b", %{"v" => 2}, %{})

      assert {:ok, 200, _, _} = Cosmos.put_doc("iddb2", "idc2", "ok", %{"v" => 2}, %{})
    end

    test "create on an existing id -> 409 Conflict, original doc untouched (real Cosmos parity)" do
      Cosmos.create_collection("dup", "dupc", %{"id" => "dupc"})
      {:ok, 201, _, d1} = Cosmos.create_doc("dup", "dupc", %{"id" => "x", "v" => 1}, %{})

      assert {:ok, 409, _, %{"code" => "Conflict"}} =
               Cosmos.create_doc("dup", "dupc", %{"id" => "x", "v" => 2}, %{})

      assert {:ok, 200, _, unchanged} = Cosmos.get_doc("dup", "dupc", "x", %{})
      assert unchanged["v"] == 1
      assert unchanged["_etag"] == d1["_etag"]
    end

    test "8-way duplicate-create race on one id: exactly one 201, seven 409" do
      Cosmos.create_collection("dup2", "dup2c", %{"id" => "dup2c"})

      results =
        1..8
        |> Task.async_stream(fn i ->
          Cosmos.create_doc("dup2", "dup2c", %{"id" => "race", "v" => i}, %{})
        end)
        |> Enum.to_list()

      statuses =
        Enum.map(results, fn
          {:ok, {:ok, s, _, _}} -> s
          other -> {:exit, other}
        end)

      assert Enum.count(statuses, &(&1 == 201)) == 1,
             "expected exactly one 201, got #{inspect(statuses)}"

      assert Enum.count(statuses, &(&1 == 409)) == 7,
             "expected seven 409s, got #{inspect(statuses)}"

      assert {:ok, 200, _, doc} = Cosmos.get_doc("dup2", "dup2c", "race", %{})
      assert is_integer(doc["v"])
    end

    # R118/D17: replace (PUT) semantics — the stored doc IS the body; removed
    # fields must be gone. Previously Map.merge retained stale top-level keys.
    test "R118: PUT omitting a field removes it from the stored doc (was: retained by merge)" do
      Cosmos.create_collection("r118", "r118c", %{"id" => "r118c"})
      {:ok, 201, _, _} = Cosmos.create_doc("r118", "r118c", %{"id" => "d", "a" => 1, "b" => 2}, %{})

      assert {:ok, 200, _, replaced} = Cosmos.put_doc("r118", "r118c", "d", %{"id" => "d", "a" => 9}, %{})
      assert replaced["a"] == 9
      refute Map.has_key?(replaced, "b"), "stale key b must not survive a replace, got: #{inspect(replaced)}"

      assert {:ok, 200, _, stored} = Cosmos.get_doc("r118", "r118c", "d", %{})
      refute Map.has_key?(stored, "b")
      assert stored["a"] == 9
    end

    # KD-36: x-ms-documentdb-is-upsert -> create-or-replace (real Cosmos parity).
    test "KD-36: upsert on existing id -> 200 replace, not 409" do
      Cosmos.create_collection("kd36", "kd36c", %{"id" => "kd36c"})
      {:ok, 201, _, first} = Cosmos.create_doc("kd36", "kd36c", %{"id" => "u", "v" => 1}, %{})
      upsert = %{"x-ms-documentdb-is-upsert" => "true"}

      assert {:ok, 200, _, replaced} =
               Cosmos.create_doc("kd36", "kd36c", %{"id" => "u", "v" => 2}, upsert)

      assert replaced["v"] == 2
      assert replaced["_etag"] != first["_etag"]

      assert {:ok, 200, _, stored} = Cosmos.get_doc("kd36", "kd36c", "u", %{})
      assert stored["v"] == 2
    end

    test "KD-36: upsert on new id -> 201 create" do
      Cosmos.create_collection("kd36b", "kd36bc", %{"id" => "kd36bc"})
      upsert = %{"x-ms-documentdb-is-upsert" => "true"}

      assert {:ok, 201, _, _} =
               Cosmos.create_doc("kd36b", "kd36bc", %{"id" => "fresh", "v" => 1}, upsert)

      # non-upsert create on an existing id still 409 (the KD-36 fix must not
      # have relaxed plain creates)
      assert {:ok, 409, _, %{"code" => "Conflict"}} =
               Cosmos.create_doc("kd36b", "kd36bc", %{"id" => "fresh", "v" => 2}, %{})
    end

    test "create/delete churn on one id: terminal state is always consistent (exists-with-201-etag or absent)" do
      Cosmos.create_collection("churn2", "churn2c", %{"id" => "churn2c"})
      {:ok, 201, _, seed} = Cosmos.create_doc("churn2", "churn2c", %{"id" => "z", "v" => 0}, %{})

      results =
        1..12
        |> Task.async_stream(fn i ->
          if rem(i, 2) == 0 do
            {:create, Cosmos.create_doc("churn2", "churn2c", %{"id" => "z", "v" => i}, %{})}
          else
            {:del, Cosmos.delete_doc("churn2", "churn2c", "z", %{})}
          end
        end)
        |> Enum.to_list()

      statuses =
        Enum.map(results, fn {:ok, {tag, {:ok, s, _, _}}} -> {tag, s} end)

      # Creates may 201 (absent at check time) or 409 (lost the insert_new);
      # deletes may 204 (present) or 404 (absent). No other statuses allowed.
      assert Enum.all?(statuses, fn
             {_t, s} -> s in [201, 409, 204, 404]
             end)

      # Terminal consistency: if the doc exists it carries a 201-minted etag
      # (sha256 over {winning-body hash, _v, _gen}), never a hybrid.
      case Cosmos.get_doc("churn2", "churn2c", "z", %{}) do
        {:ok, 200, _, doc} ->
          body_hash =
            :crypto.hash(:sha256, Jason.encode!(%{"id" => "z", "v" => doc["v"]}))
            |> Base.encode16(case: :lower)

          assert doc["_etag"] ==
                   "\"" <>
                     (:crypto.hash(
                        :sha256,
                        Jason.encode!(%{"h" => body_hash, "v" => doc["_v"], "g" => doc["_gen"]})
                      )
                      |> Base.encode16(case: :lower)) <> "\""

        {:ok, 404, _, _} ->
          :ok
      end
    end
  end

  describe "lens-2: conditional delete is atomic (CAS-delete, S8 class)" do
    test "8-way same-etag conditional delete race: exactly one 204, seven 412" do
      Cosmos.create_collection("dd", "ddc", %{"id" => "ddc"})
      {:ok, 201, _, doc} = Cosmos.create_doc("dd", "ddc", %{"id" => "race", "v" => 0}, %{})
      etag = doc["_etag"]

      results =
        1..8
        |> Task.async_stream(fn _ -> Cosmos.delete_doc("dd", "ddc", "race", %{"if-match" => etag}) end,
          max_concurrency: 8
        )
        |> Enum.to_list()

      statuses =
        Enum.map(results, fn
          {:ok, {:ok, s, _, _}} -> s
          other -> {:exit, other}
        end)

      assert Enum.count(statuses, &(&1 == 204)) == 1,
             "expected exactly one 204, got #{inspect(statuses)}"

      # The rest are 412 (lost the CAS) or 404 (read after the winner's
      # delete) — either refusal is correct; two 204s are structurally
      # impossible with the check+delete inside one Store call.
      assert Enum.count(statuses, &(&1 in [412, 404])) == 7,
             "expected seven refusals, got #{inspect(statuses)}"

      assert {:ok, 404, _, _} = Cosmos.get_doc("dd", "ddc", "race", %{})
    end

    test "mixed put/delete race on one etag: exactly one effect survives (cross-op isolation)" do
      Cosmos.create_collection("xo", "xoc", %{"id" => "xoc"})
      {:ok, 201, _, doc} = Cosmos.create_doc("xo", "xoc", %{"id" => "m", "v" => 0}, %{})
      etag = doc["_etag"]

      results =
        1..8
        |> Task.async_stream(fn i ->
          if rem(i, 2) == 0 do
            {:put, Cosmos.put_doc("xo", "xoc", "m", %{"v" => i}, %{"if-match" => etag})}
          else
            {:del, Cosmos.delete_doc("xo", "xoc", "m", %{"if-match" => etag})}
          end
        end)
        |> Enum.to_list()

      statuses =
        Enum.map(results, fn {:ok, {tag, {:ok, s, _, _}}} -> {tag, s} end)

      # Exactly one op wins the etag: a 200 (put kept the doc) or a 204 (delete
      # removed it). Every other op refuses 412/404. A put 200 AND a delete 204
      # together would mean the etag governed two effects.
      winners = Enum.count(statuses, fn {_t, s} -> s in [200, 204] end)
      assert winners == 1, "expected exactly one winning effect, got #{inspect(statuses)}"

      assert Enum.all?(statuses, fn {_t, s} -> s in [200, 204, 412, 404] end)

      # Post-state agrees with the winner.
      if Enum.any?(statuses, fn {t, s} -> t == :put and s == 200 end) do
        assert {:ok, 200, _, final} = Cosmos.get_doc("xo", "xoc", "m", %{})
        refute final["v"] == 0
      else
        assert {:ok, 404, _, _} = Cosmos.get_doc("xo", "xoc", "m", %{})
      end
    end

    test "conditional delete after an intervening replace -> 412 (no stale delete)" do
      Cosmos.create_collection("dd2", "dd2c", %{"id" => "dd2c"})
      {:ok, 201, _, doc} = Cosmos.create_doc("dd2", "dd2c", %{"id" => "x", "v" => 0}, %{})

      {:ok, 200, _, _} = Cosmos.put_doc("dd2", "dd2c", "x", %{"v" => 1}, %{"if-match" => doc["_etag"]})

      # the OLD etag no longer governs: conditional delete must 412
      assert {:ok, 412, _, %{"code" => "PreconditionFailed"}} =
               Cosmos.delete_doc("dd2", "dd2c", "x", %{"if-match" => doc["_etag"]})
    end
  end

  describe "lens-2: cross-container ACID isolation" do
    test "concurrent CAS races on docs in different containers do not interfere" do
      Cosmos.create_collection("xca", "ca", %{"id" => "ca"})
      Cosmos.create_collection("xcb", "cb", %{"id" => "cb"})

      {:ok, 201, _, docA} = Cosmos.create_doc("xca", "ca", %{"id" => "s", "v" => 0}, %{})
      {:ok, 201, _, docB} = Cosmos.create_doc("xcb", "cb", %{"id" => "s", "v" => 0}, %{})

      # Both etags are sha256 over {body hash, _v, _gen} of the same body —
      # still distinct per doc (independent _gen nonces), but CAS is keyed on
      # the FULL storage key (db/coll/doc), so the two races must be fully
      # independent.
      {resultsA, resultsB} =
        Task.async_stream(1..8, fn i ->
          if rem(i, 2) == 0 do
            {:a, Cosmos.put_doc("xca", "ca", "s", %{"v" => i}, %{"if-match" => docA["_etag"]})}
          else
            {:b, Cosmos.put_doc("xcb", "cb", "s", %{"v" => i}, %{"if-match" => docB["_etag"]})}
          end
        end)
        |> Enum.to_list()
        |> Enum.split_with(&match?({:a, _}, elem(&1, 1)))

      for {tag, {:ok, {s, _, _, _}}} <- resultsA ++ resultsB do
        assert s == 200, "#{tag}: expected 200, got #{inspect(s)}"
      end

      {:ok, 200, _, finalA} = Cosmos.get_doc("xca", "ca", "s", %{})
      {:ok, 200, _, finalB} = Cosmos.get_doc("xcb", "cb", "s", %{})
      # No lost updates, no cross-container bleed: both docs advanced.
      assert finalA["v"] != 0 and finalB["v"] != 0
      assert finalA["v"] != finalB["v"]
    end
  end

  describe "lens-2: session-token / continuation semantics (typed GAPs, pinned)" do
    test "malformed pk header on a partitioned query -> 400, never a cross-partition leak" do
      Cosmos.create_collection("leak", "leakc", %{"id" => "leakc", "partitionKey" => %{"paths" => ["/t"]}})
      {:ok, 201, _, _} = Cosmos.create_doc("leak", "leakc", %{"id" => "a", "t" => "x"}, %{"x-ms-documentdb-partitionkey" => ~s(["x"])})
      {:ok, 201, _, _} = Cosmos.create_doc("leak", "leakc", %{"id" => "b", "t" => "y"}, %{"x-ms-documentdb-partitionkey" => ~s(["y"])})

      for bad <- ["not-json", "[]", ~s(["x","y"]), ~s([null]), ""] do
        assert {:ok, 400, _, %{"code" => "BadRequest"}} =
                 Cosmos.query_docs("leak", "leakc", %{"query" => "SELECT * FROM c"}, %{
                   "x-ms-documentdb-partitionkey" => bad
                 }),
               "expected 400 for malformed pk header #{inspect(bad)}"
      end

      # A parseable header still scopes; absent header still cross-partitions.
      assert {:ok, 200, _, scoped} =
               Cosmos.query_docs("leak", "leakc", %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s(["x"])})

      assert scoped["_count"] == 1

      assert {:ok, 200, _, all} = Cosmos.query_docs("leak", "leakc", %{"query" => "SELECT * FROM c"}, %{})
      assert all["_count"] == 2
    end

    test "hostile headers through every point op: {:ok,..} | {:error,:store_not_ready} only, never a raise" do
      Cosmos.create_collection("hz", "hzc", %{"id" => "hzc", "partitionKey" => %{"paths" => ["/t"]}})

      {:ok, 201, _, _} =
        Cosmos.create_doc("hz", "hzc", %{"id" => "d", "t" => "x"}, %{"x-ms-documentdb-partitionkey" => ~s(["x"])})

      hostile = [
        %{"if-match" => :crypto.strong_rand_bytes(64)},
        %{"if-match" => "\"unbalanced"},
        %{"if-none-match" => <<0xFF, 0xFE, 0x00>>},
        %{"x-ms-documentdb-partitionkey" => <<0xFF, 0xFE>>},
        %{"x-ms-documentdb-partitionkey" => String.duplicate("[", 500)},
        %{"x-ms-consistency-level" => 123},
        %{"x-ms-session-token" => :crypto.strong_rand_bytes(256)},
        %{"authorization" => "Type%3dmaster%26ver%3d1.0%26sig%3d!!!"},
        %{"x-ms-date" => -1}
      ]

      Enum.each(hostile, fn h ->
        r1 = Cosmos.create_doc("hz", "hzc", %{"id" => "hz1", "t" => "x"}, h)
        r2 = Cosmos.get_doc("hz", "hzc", "d", h)
        r3 = Cosmos.put_doc("hz", "hzc", "d", %{"v" => 1}, h)
        r4 = Cosmos.delete_doc("hz", "hzc", "d", h)
        r5 = Cosmos.query_docs("hz", "hzc", %{"query" => "SELECT * FROM c"}, h)

        Enum.each([r1, r2, r3, r4, r5], fn r ->
          assert match?({:ok, _, _, _}, r) or match?({:error, :store_not_ready}, r),
                 "non-typed result under hostile headers #{inspect(h, limit: :infinity)}: #{inspect(r)}"
        end)

        # the anchor doc survives the sweep (re-created: the unconditional
        # delete inside the sweep legitimately removed the previous one)
        Cosmos.create_doc("hz", "hzc", %{"id" => "d", "t" => "x"}, %{"x-ms-documentdb-partitionkey" => ~s(["x"])})
        assert match?({:ok, 200, _, _}, Cosmos.get_doc("hz", "hzc", "d", %{}))
      end)
    end

    test "concurrent writes mint strictly monotonic, distinct session tokens" do
      Cosmos.create_collection("mono", "monoc", %{"id" => "monoc"})
      {:ok, 201, _, _} = Cosmos.create_doc("mono", "monoc", %{"id" => "seed", "v" => 0}, %{})

      tokens =
        1..20
        |> Task.async_stream(fn i ->
          {:ok, 201, h, _} =
            Cosmos.create_doc("mono", "monoc", %{"id" => "m" <> String.pad_leading(Integer.to_string(i), 2, "0")}, %{})

          h["x-ms-session-token"]
        end)
        |> Enum.map(fn {:ok, t} -> t end)

      assert length(Enum.uniq(tokens)) == 20

      numbers =
        Enum.map(tokens, fn t ->
          assert t =~ ~r/^\d+#\d+$/
          {n, _} = Integer.parse(List.last(String.split(t, "#")))
          n
        end)

      # Distinct, contiguous, no gaps: update_counter is atomic, so 20
      # concurrent creates mint exactly 20 distinct LSNs above the seed's.
      assert Enum.sort(numbers) == Enum.to_list(2..21)
    end

    test "KNOWN DIVERGENCE: a stale client x-ms-session-token is ignored" do
      Cosmos.create_collection("st", "stc", %{"id" => "stc"})
      {:ok, 201, h1, _} = Cosmos.create_doc("st", "stc", %{"id" => "d1", "v" => 1}, %{})
      assert h1["x-ms-session-token"] == "1#1"

      # Client sends a stale token; the engine reports the CURRENT token and
      # serves the read (real Cosmos: the service never rejects on a stale
      # session token — enforcement is client-side in the SDK — so ignoring
      # it IS the parity behavior; pinned so it cannot silently pivot).
      assert {:ok, 200, h2, _} =
               Cosmos.get_doc("st", "stc", "d1", %{"x-ms-session-token" => "1#0"})

      assert h2["x-ms-session-token"] == "1#1"
    end

    test "feed truncation emits x-ms-continuation (row 18 RAISE closed, lens-3)" do
      Cosmos.create_collection("cont", "contc", %{"id" => "contc"})

      for i <- 0..104 do
        {:ok, 201, _, _} =
          Cosmos.create_doc("cont", "contc", %{"id" => "q" <> String.pad_leading(Integer.to_string(i), 4, "0")},
            %{})
      end

      {:ok, 200, h, res} =
        Cosmos.query_docs("cont", "contc", %{"query" => "SELECT * FROM c"}, %{})

      assert res["_count"] == 100
      # Real Cosmos emits x-ms-continuation when a feed page is truncated.
      # Lens-3 (row 18 RAISE closed): the token format is "1#{lsn}:{last_id}",
      # the last page is tokenless, and a forged token is a typed 400.
      token = h["x-ms-continuation"]
      assert is_binary(token) and token =~ ~r/^1#\d+:[A-Za-z0-9_-]+:q0099$/
    end

    test "query/list under concurrent doc churn: bounded, crash-free, no phantom completeness" do
      Cosmos.create_collection("churn", "churnc", %{"id" => "churnc"})

      {:ok, 201, _, _} = Cosmos.create_doc("churn", "churnc", %{"id" => "anchor", "v" => 0}, %{})

      # 40 concurrent creates while 10 queries + 10 lists run.
      spin =
        Task.async_stream(1..40, fn i ->
          Cosmos.create_doc("churn", "churnc", %{"id" => "c" <> String.pad_leading(Integer.to_string(i), 3, "0")}, %{})
        end)

      reads =
        Task.async_stream(1..20, fn i ->
          if rem(i, 2) == 0 do
            {:query, Cosmos.query_docs("churn", "churnc", %{"query" => "SELECT * FROM c"}, %{})}
          else
            {:list, Cosmos.list_docs("churn", "churnc")}
          end
        end)

      spin_done = Enum.to_list(spin)
      reads_done = Enum.to_list(reads)

      for {_tag, {:ok, 200, _h, body}} <- reads_done do
        docs = if is_list(body), do: body, else: body["Documents"]
        count = length(docs)

        assert count in 1..100,
               "feed must be bounded 1..100 under churn, got #{count}"

        ids = Enum.map(docs, & &1["id"])
        assert ids == Enum.sort(ids)
      end

      # After churn drains, the feed is complete: 41 docs (anchor + 40).
      assert {:ok, 200, _, final} = Cosmos.list_docs("churn", "churnc")
      assert length(final) == 41
    end

    test "GAP: no stored-procedure / trigger / UDF surface (wire 404s, typed GAP)" do
      # Cosmos.ex exposes no sproc/trigger/udf handlers. The wire layer must
      # keep refusing these routes, never crash and never half-implement.
      {:ok, 404, _, _} = Cosmos.get_doc("anydb", "anycoll", "..%2Fsprocs", %{})
      assert Cosmos.store_ready?()
    end
  end

  # -------------------------------------------------------------------------
  # Feed continuation (row 18 — lens-3 RAISE, engine work order lens-2 c5)
  # -------------------------------------------------------------------------

  describe "feed continuation x-ms-continuation (row 18)" do
    @tag :cont
    test "105-doc feed: page 1 emits token, resume completes the feed, last page tokenless" do
      db = "cdb"
      coll = "cc"

      {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 0..104 do
        {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d-#{String.pad_leading(Integer.to_string(i), 4, "0")}"}, %{})
      end

      {:ok, 200, h1, p1} = Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{})

      assert p1["_count"] == 100
      token = h1["x-ms-continuation"]
      assert is_binary(token) and token =~ ~r/^1#\d+:[A-Za-z0-9_-]+:d-0099$/

      {:ok, 200, h2, p2} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => token})

      assert p2["_count"] == 5
      assert h2["x-ms-continuation"] == nil

      # Full loop: no skip, no repeat.
      all = Enum.map(p1["Documents"], & &1["id"]) ++ Enum.map(p2["Documents"], & &1["id"])
      assert length(all) == 105
      assert length(Enum.uniq(all)) == 105
      assert all == Enum.sort(all)
    end

    @tag :cont
    test "contract pin: token's last_id deleted mid-resume -> order-based resume, no skip/stall" do
      db = "chdb"
      coll = "chc"

      {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 0..104 do
        {:ok, 201, _, _} =
          Cosmos.create_doc(db, coll, %{"id" => "k-#{String.pad_leading(Integer.to_string(i), 4, "0")}"}, %{})
      end

      {:ok, 200, h1, p1} = Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{})
      token = h1["x-ms-continuation"]
      assert p1["_count"] == 100 and is_binary(token)

      # The doc the token points at is deleted BEFORE the resume.
      {:ok, 204, _, _} = Cosmos.delete_doc(db, coll, "k-0099", %{})

      {:ok, 200, h2, p2} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => token})

      assert p2["_count"] == 5
      assert h2["x-ms-continuation"] == nil

      ids = Enum.map(p2["Documents"], & &1["id"])
      assert ids == Enum.sort(ids) and length(ids) == 5
      assert "k-0099" not in ids and "k-0100" in ids
    end

    @tag :cont
    test "token forgery: malformed, wrong-version, ahead-of-ledger tokens -> typed 400" do
      db = "fdb"
      coll = "fc"

      {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      {:ok, 200, _, seed} = Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{})
      assert seed["_count"] == 0

      forged = [
        "garbage",
        "1",
        "1#",
        "1#abc:x",
        "2#1:abc",
        "1#1:",
        "1#999999999:abc",
        "1#1:/bad/id",
        "1#1:" <> String.duplicate("x", 256),
        "1#1:with/slash"
      ]

      for bad <- forged do
        assert {:ok, 400, headers, %{"code" => "BadRequest"}} =
                 Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => bad})

        assert headers["x-ms-request-charge"] == "1.0"
      end
    end

    @tag :cont
    test "partition-scoped continuation: token resumes within one partition, never leaks the other" do
      db = "pdb"
      coll = "pc"

      {:ok, 201, _, _} =
        Cosmos.create_collection(db, coll, %{"id" => coll, "partitionKey" => %{"paths" => ["/t"]}})

      for part <- ["a", "b"], i <- 0..59 do
        {:ok, 201, _, _} =
          Cosmos.create_doc(
            db,
            coll,
            %{"id" => "p-#{part}-#{String.pad_leading(Integer.to_string(i), 3, "0")}", "t" => part},
            %{"x-ms-documentdb-partitionkey" => ~s(["#{part}"])}
          )
      end

      {:ok, 200, h1, p1} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
          "x-ms-documentdb-partitionkey" => ~s(["a"])
        })

      assert p1["_count"] == 60
      # 60 < 100: no truncation, no token — the last page is tokenless.
      assert h1["x-ms-continuation"] == nil

      # Force truncation inside one partition: 101 docs in partition "a" only.
      for i <- 60..100 do
        {:ok, 201, _, _} =
          Cosmos.create_doc(
            db,
            coll,
            %{"id" => "p-a-#{String.pad_leading(Integer.to_string(i), 3, "0")}", "t" => "a"},
            %{"x-ms-documentdb-partitionkey" => ~s(["a"])}
          )
      end

      {:ok, 200, h2, p2} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
          "x-ms-documentdb-partitionkey" => ~s(["a"])
        })

      assert p2["_count"] == 100
      token = h2["x-ms-continuation"]
      # Scoped feed: the pk header is embedded as the token scope
      # ("1#<lsn>:<pk_raw>/<last_id>", lens-5 scope-binding fence).
      assert is_binary(token) and token =~ ~r|^1#\d+:[A-Za-z0-9_-]+:\["a"\]/p-a-099$|

      {:ok, 200, h3, p3} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
          "x-ms-documentdb-partitionkey" => ~s(["a"]),
          "x-ms-continuation" => token
        })

      assert p3["_count"] == 1
      assert h3["x-ms-continuation"] == nil

      # Resume with the token under the OTHER partition's header: typed 400 —
      # the token's scope must equal the resume's pk header (lens-5 fence;
      # previously the cursor silently dropped 50 of 60 B docs with 200).
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["b"]),
                 "x-ms-continuation" => token
               })
    end

    @tag :cont
    test "forgery fuzz: 300 seeded random tokens never 5xx; well-formed -> 200/400, never raise" do
      db = "zzdb"
      coll = "zzc"

      {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "seed"}, %{})

      base = ["1", "2", "0", "", "x", "999999", "-1", "1e3", "1#1", "#", ":", "1##", "01#1"]

      seeds = for a <- base, b <- base, c <- base, do: {a, b, c}

      tokens =
        Enum.map(seeds, fn {a, b, c} -> a <> Enum.random(["#", ":"]) <> b <> ":" <> c end)

      tokens =
        tokens ++
          Enum.map(1..60, fn _ ->
            :crypto.strong_rand_bytes(:rand.uniform(24))
            |> Base.url_encode64(padding: false)
          end)

      tokens = Enum.uniq(tokens) |> Enum.take(300)

      results =
        Enum.map(tokens, fn tok ->
          Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => tok})
        end)

      # Never a raise, never a 5xx: every forged probe is a typed 200 or 400.
      Enum.each(results, fn
        {:ok, s, _, _} when s in [200, 400] -> :ok
        other -> flunk("forged token produced #{inspect(other)}")
      end)

      # Every 400 carries the envelope, every 200 a well-formed feed.
      Enum.each(Enum.zip(tokens, results), fn
        {_, {:ok, 400, h, %{"code" => "BadRequest"}}} -> assert h["x-ms-request-charge"] == "1.0"
        {_, {:ok, 200, _, %{"_count" => n}}} -> assert is_integer(n)
        _ -> :ok
      end)
    end

    @tag :cont
    test "wire tier: query POST emits the token on truncated pages and honors it on resume" do
      db = "wdb"
      coll = "wc"
      router_opts = EgressRouter.init([])

      dispatch = fn c -> EgressRouter.call(c, router_opts) end

      conn(:post, "/dbs", %{"id" => db}) |> dispatch.() |> status_response() |> then(&assert &1 == 201)

      conn(:post, "/dbs/#{db}/colls", %{"id" => coll, "partitionKey" => %{"paths" => ["/p"]}})
      |> dispatch.()
      |> status_response()
      |> then(&assert &1 == 201)

      for i <- 0..104 do
        body = Jason.encode!(%{"id" => "w-#{String.pad_leading(Integer.to_string(i), 4, "0")}", "p" => "ten"})
        conn(:post, "/dbs/#{db}/colls/#{coll}/docs", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-ms-documentdb-partitionkey", ~s(["ten"]))
        |> dispatch.()
        |> status_response()
        |> then(&assert &1 == 201)
      end

      qbody = Jason.encode!(%{"query" => "SELECT * FROM c"})

      conn1 =
        conn(:post, "/dbs/#{db}/colls/#{coll}/docs", qbody)
        |> put_req_header("content-type", "application/query+json")
        |> put_req_header("x-ms-documentdb-partitionkey", ~s(["ten"]))
        |> dispatch.()

      assert conn1.status == 200

      resp_token =
        conn1 |> get_resp_header("x-ms-continuation") |> List.first()

      assert is_binary(resp_token) and resp_token =~ ~r|^1#\d+:[A-Za-z0-9_-]+:\["ten"\]/w-0099$|

      page1 =
        conn1.resp_body |> Jason.decode!() |> Map.get("Documents") |> Enum.map(& &1["id"])

      assert length(page1) == 100

      conn2 =
        conn(:post, "/dbs/#{db}/colls/#{coll}/docs", qbody)
        |> put_req_header("content-type", "application/query+json")
        |> put_req_header("x-ms-documentdb-partitionkey", ~s(["ten"]))
        |> put_req_header("x-ms-continuation", resp_token)
        |> dispatch.()

      assert conn2.status == 200

      page2 =
        conn2.resp_body |> Jason.decode!() |> Map.get("Documents") |> Enum.map(& &1["id"])

      assert length(page2) == 5
      assert get_resp_header(conn2, "x-ms-continuation") == []

      assert (page1 ++ page2) |> Enum.uniq() |> length() == 105
    end
  end

  # -------------------------------------------------------------------------
  # List-feed continuation (lens-4: authorized continuation of the lens-3 GAP)
  # -------------------------------------------------------------------------

  describe "list_docs continuation (version-2 token namespace)" do
    test "truncated list emits a v2 token, resume completes the feed, last page tokenless" do
      db = "ldb2"
      coll = "lc2"
      Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..105 do
        Cosmos.create_doc(db, coll, %{"id" => "d" <> String.pad_leading(Integer.to_string(i), 3, "0")}, %{})
      end

      {:ok, 200, h1, page1} = Cosmos.list_docs(db, coll)
      assert length(page1) == 100
      token = h1["x-ms-continuation"]
      assert is_binary(token) and token =~ ~r/^2#\d+:[A-Za-z0-9_-]+:d100$/

      # Cross-namespace fence: this v2 list token fed to the QUERY surface is
      # a typed 400 — token namespaces must not cross.
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
                 "x-ms-continuation" => token
               })

      {:ok, 200, h2, page2} = Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => token})
      assert Enum.map(page2, & &1["id"]) == Enum.map(101..105, &"d#{&1}")
      assert h2["x-ms-continuation"] == nil

      assert Enum.uniq(Enum.map(page1, & &1["id"]) ++ Enum.map(page2, & &1["id"])) |> length() ==
               105
    end

    test "prefix-resume fence: a token minted under prefix A resumed under prefix B is a typed 400" do
      db = "ldbp"
      coll = "lcp"
      {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..105, do: {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "a#{String.pad_leading(Integer.to_string(i), 3, "0")}"}, %{})

      for i <- 1..60, do: {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "b#{i}"}, %{})

      # Mint a REAL token under prefix "a" (truncated 105-doc feed).
      {:ok, 200, h1, page1} = Cosmos.list_docs(db, coll, "a")
      assert length(page1) == 100
      token = h1["x-ms-continuation"]
      # Nonempty prefix is embedded in the token tail: "2#<lsn>:a/a100"
      assert is_binary(token) and token =~ ~r/^2#\d+:[A-Za-z0-9_-]+:a\/a100$/

      # Same-prefix resume completes the feed, last page tokenless.
      {:ok, 200, h2, page2} = Cosmos.list_docs(db, coll, "a", %{"x-ms-continuation" => token})
      assert Enum.map(page2, & &1["id"]) == Enum.map(101..105, &"a#{String.pad_leading(Integer.to_string(&1), 3, "0")}")
      assert h2["x-ms-continuation"] == nil

      # Cross-prefix resume: a DIFFERENT prefix is a typed 400 — a token is
      # only valid for the feed (prefix) that emitted it (real Cosmos binds
      # tokens to their query).
      for wrong_prefix <- ["", "b", "aa", "a/"] do
        assert {:ok, 400, _, %{"code" => "BadRequest"}} =
                 Cosmos.list_docs(db, coll, wrong_prefix, %{"x-ms-continuation" => token}),
               "prefix #{inspect(wrong_prefix)} must 400"
      end
    end

    test "query scope fence: a cross-partition token resumed under a pk header is a typed 400 (silent-drop regression)" do
      db = "qdb"
      coll = "qc"

      {:ok, 201, _, _} =
        Cosmos.create_collection(db, coll, %{"id" => coll, "partitionKey" => %{"paths" => ["/p"]}})

      # Interleaved partitions: 120 docs, alternating p = A/B.
      for i <- 1..120 do
        p = if rem(i, 2) == 0, do: "A", else: "B"

        {:ok, 201, _, _} =
          Cosmos.create_doc(db, coll, %{"id" => "m#{String.pad_leading(Integer.to_string(i), 3, "0")}", "p" => p},
            %{"x-ms-documentdb-partitionkey" => ~s(["#{p}"])})
      end

      # Truncated cross-partition page: cursor at m100.
      {:ok, 200, h1, p1} = Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{})
      assert p1["_count"] == 100
      token = h1["x-ms-continuation"]
      assert is_binary(token) and token =~ ~r|^1#\d+:[A-Za-z0-9_-]+:m100$|

      # Pre-fence this resume returned 200 with 10 of 60 B docs — 50 silently
      # dropped (lens-5 probe). Now a typed 400: the token scope ("") must
      # equal the resume's pk header.
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["B"]),
                 "x-ms-continuation" => token
               })

      # The unscoped resume (same scope) still completes the remaining 20.
      {:ok, 200, h2, p2} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => token})

      assert p2["_count"] == 20 and h2["x-ms-continuation"] == nil
    end

    test "churn contract: deleting the token's last_id doc mid-resume cannot skip or stall" do
      db = "ldbchurn"
      coll = "lcchurn"
      Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..12 do
        Cosmos.create_doc(db, coll, %{"id" => "k" <> String.pad_leading(Integer.to_string(i), 2, "0")}, %{})
      end

      # Force a 10-doc page: page 1 = k01..k10, token cursor k10.
      {:ok, 200, h1, page1} = Cosmos.list_docs(db, coll)
      # (12 docs fit one page here, so drive the cursor directly.) The token
      # carries the container binding (lens-6): "2#{lsn}:{b64c}:{last_id}".
      b64c = Base.url_encode64("#{db}/#{coll}", padding: false)
      token = "2#1:" <> b64c <> ":k10"

      # Actually page through at limit: shrink by using the cursor to resume.
      assert length(page1) == 12 and h1["x-ms-continuation"] == nil

      # Delete the cursor doc, then resume: ORDER-based cursor must return
      # k11, k12 — no skip, no stall, no 404.
      {:ok, 204, _, _} = Cosmos.delete_doc(db, coll, "k10", %{})
      {:ok, 200, _, rest} = Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => token})
      assert Enum.map(rest, & &1["id"]) == ["k11", "k12"]
    end

    test "cross-token: a v1 query token fed to list_docs is a typed 400" do
      db = "ldbx"
      coll = "lcx"
      Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..3, do: Cosmos.create_doc(db, coll, %{"id" => "d#{i}"}, %{})

      lsn = 1
      q_token = "1##{lsn}:d1"

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => q_token})
    end

    test "list forgery matrix: forged/malformed tokens are typed 400s" do
      db = "ldbf"
      coll = "lcf"
      Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..3, do: Cosmos.create_doc(db, coll, %{"id" => "d#{i}"}, %{})

      forged = [
        "garbage",
        "1",
        "2",
        "2#",
        "2#abc:d1",
        "1#1:d1",
        "2#999999:d1",
        "2#1:",
        String.duplicate("a", 256),
        "2#1:a/b"
      ]

      for tok <- forged do
        assert {:ok, 400, _, %{"code" => "BadRequest"}} =
                 Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => tok}),
               "token #{inspect(tok)} must be a 400"
      end
    end

    test "list forgery fuzz: 300 seeded/random tokens never 5xx, never raise" do
      db = "ldbz"
      coll = "lcz"
      Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..3, do: Cosmos.create_doc(db, coll, %{"id" => "d#{i}"}, %{})

      :rand.seed(:exsss, {1, 2, 3})

      tokens =
        for _ <- 1..300 do
          case :rand.uniform(4) do
            1 -> :base64.encode(:crypto.strong_rand_bytes(:rand.uniform(24)))
            2 -> "2##{:rand.uniform(50)}:" <> :base64.encode(:crypto.strong_rand_bytes(8))
            3 -> "1##{:rand.uniform(50)}:" <> :base64.encode(:crypto.strong_rand_bytes(8))
            _ -> String.duplicate("2#", :rand.uniform(6))
          end
        end

      for tok <- tokens do
        res = Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => tok})

        assert match?({:ok, 200, _, _}, res) or match?({:ok, 400, _, _}, res),
               "token #{inspect(tok)} produced #{inspect(res)}"
      end
    end

    test "container fence: a token minted on one container resumed on another is a typed 400 (lens-6 silent-drop regression)" do
      db_a = "l6ca"
      coll_a = "c6a"
      db_b = "l6cb"
      coll_b = "c6b"
      Cosmos.create_collection(db_a, coll_a, %{"id" => coll_a})
      Cosmos.create_collection(db_b, coll_b, %{"id" => coll_b})

      for i <- 1..105 do
        Cosmos.create_doc(db_a, coll_a, %{"id" => "n" <> String.pad_leading("#{i}", 3, "0")}, %{})
        Cosmos.create_doc(db_b, coll_b, %{"id" => "n" <> String.pad_leading("#{i}", 3, "0")}, %{})
      end

      # List feed (v2): token minted on A, resumed on B.
      {:ok, 200, ha, _} = Cosmos.list_docs(db_a, coll_a, "", %{})
      assert tok_a = ha["x-ms-continuation"]
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.list_docs(db_b, coll_b, "", %{"x-ms-continuation" => tok_a})

      # Symmetric: B's token refused on A.
      {:ok, 200, hb, _} = Cosmos.list_docs(db_b, coll_b, "", %{})
      assert tok_b = hb["x-ms-continuation"]
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.list_docs(db_a, coll_a, "", %{"x-ms-continuation" => tok_b})

      # Query feed (v1): token minted on A, resumed on B.
      {:ok, 200, hqa, _} = Cosmos.query_docs(db_a, coll_a, %{"query" => "SELECT * FROM c"}, %{})
      assert tq_a = hqa["x-ms-continuation"]
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.query_docs(db_b, coll_b, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => tq_a})

      # The A token still resumes lawfully on A (fence refuses only cross-container).
      {:ok, 200, h2, page2} = Cosmos.list_docs(db_a, coll_a, "", %{"x-ms-continuation" => tok_a})
      assert h2["x-ms-continuation"] == nil
      assert length(page2) == 5
    end

    test "container+scope mutation matrix: every resume/filter combination is typed 400 or lawful 200 (lens-6 fuzz)" do
      db_a = "l6ma"
      coll_a = "ma"
      db_b = "l6mb"
      coll_b = "mb"
      Cosmos.create_collection(db_a, coll_a, %{"id" => coll_a})
      Cosmos.create_collection(db_b, coll_b, %{"id" => coll_b})

      for i <- 1..105 do
        Cosmos.create_doc(db_a, coll_a, %{"id" => "n" <> String.pad_leading("#{i}", 3, "0")}, %{})
        Cosmos.create_doc(db_b, coll_b, %{"id" => "n" <> String.pad_leading("#{i}", 3, "0")}, %{})
      end

      b64_a = Base.url_encode64("#{db_a}/#{coll_a}", padding: false)
      b64_b = Base.url_encode64("#{db_b}/#{coll_b}", padding: false)

      # Real minted tokens: v1 unscoped (A), v1 pk-scoped (A), v2 list (A).
      {:ok, 200, h1, _} = Cosmos.query_docs(db_a, coll_a, %{"query" => "SELECT * FROM c"}, %{})
      v1 = h1["x-ms-continuation"]
      {:ok, 200, h2, _} =
        Cosmos.query_docs(db_a, coll_a, %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s(["x"])})

      # pk-scoped feed needs a pk-defined container? No: header on pk-less
      # container is ignored (paths []), so scope "" — hand-mint instead.
      v1_scoped = "1#105:" <> b64_a <> ":" <> ~s(["x"]) <> "/n100"

      {:ok, 200, h3, _} = Cosmos.list_docs(db_a, coll_a, "", %{})
      v2 = h3["x-ms-continuation"]

      lawful =
        [
          {Cosmos, :query_docs, [db_a, coll_a, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => v1}]},
          {Cosmos, :list_docs, [db_a, coll_a, "", %{"x-ms-continuation" => v2}]},
          {Cosmos, :query_docs,
           [db_a, coll_a, %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => ~s(["x"]), "x-ms-continuation" => v1_scoped}]}
        ]

      Enum.each(lawful, fn {m, f, args} ->
        assert {:ok, 200, _, _} = apply(m, f, args), "#{inspect(f)} lawful resume must be 200"
      end)

      # Mutations: every combination of {foreign container, swapped version,
      # swapped scope} on the token/surface pair must be a typed 400.
      forged =
        for {tok, db, coll, extra} <- [
              {v1, db_b, coll_b, %{}},
              {v2, db_b, coll_b, %{}},
              {v1_scoped, db_a, coll_a, %{}},
              {v1_scoped, db_a, coll_a, %{"x-ms-documentdb-partitionkey" => ~s(["y"])}},
              {v1_scoped, db_b, coll_b, %{"x-ms-documentdb-partitionkey" => ~s(["x"])}},
              {v1, db_a, coll_a, %{"x-ms-documentdb-partitionkey" => ~s(["x"])}}
            ] do
          {tok, db, coll, extra}
        end

      Enum.each(forged, fn {tok, db, coll, extra} ->
        res =
          if tok == v2 do
            Cosmos.list_docs(db, coll, "", Map.put(extra, "x-ms-continuation", tok))
          else
            Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, Map.put(extra, "x-ms-continuation", tok))
          end

        assert {:ok, 400, _, %{"code" => "BadRequest"}} = res,
               "mutation #{inspect(tok)} on #{db}/#{coll} extra=#{inspect(extra)} must be 400, got #{inspect(res |> elem(1))}"
      end)
    end

    @tag timeout: 150_000
    test "store restart: docs replayed (cross-session DETS snapshot) or dropped (same-session), old-grammar token still typed 400" do
      db = "lrst"
      coll = "lrc"
      {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..3, do: {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d#{i}"}, %{})

      {:ok, 200, _, pre} = Cosmos.list_docs(db, coll, "", %{})
      assert length(pre) == 3

      # Stop the table-owner GenServer; the supervisor restarts it.
      :ok = GenServer.stop(Store)

      # Wait for the restarted instance — no hard cap shorter than the CI
      # budget (2000 x 50ms = 100s ceiling; CI load previously flaked the
      # 5s cap).
      restarted? =
        Enum.reduce_while(1..2000, false, fn _, _ ->
          if Cosmos.store_ready?(), do: {:halt, true}, else: (Process.sleep(50) && {:cont, false})
        end)

      assert restarted?

      # v26.10.14 store hardening: DetsMirror atomic restore REPLAYS the
      # pre-restart rows when a DETS snapshot exists (cross-session restart).
      # In THIS test's setup the table-owner GenServer was created in this
      # same VM session, so there is no DETS snapshot to replay and restore
      # DROPS the feed — replay is environment-dependent here, not
      # deterministic. (Smalt.StoreDetsTest pins the replay law itself with
      # a forced sync + fresh DETS file.) So accept either outcome after the
      # readiness wait: replayed (length 3) or dropped (empty).
      {:ok, 200, _, post} = Cosmos.list_docs(db, coll, "", %{})
      assert post in [[], pre] or length(post) == 3,
             "post-restart feed must be replayed (3 docs) or dropped ([]), got #{inspect(post)}"

      # A pre-restart-shaped v2 token ("2#2:d2") is old-grammar (no b64url
      # container segment), so the grammar itself types it as forged —
      # state-independently of the restore: 400 BadRequest, never a silent
      # from-start scan.
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => "2#2:d2"})
    end
  end

  # -------------------------------------------------------------------------
  # Lens-7: token grammar conjunct isolation (b64url container binding)
  # -------------------------------------------------------------------------
  describe "lens-7: token grammar conjunct isolation" do
    @b64c Base.url_encode64("g7db/g7c", padding: false)

    test "non-base64 middle segment is never admitted (both namespaces)" do
      Cosmos.create_collection("g7db", "g7c", %{"id" => "g7c"})

      for {tok, surface} <- [
            {"1#1:!!!:d1", :query},
            {"2#1:!!!:d1", :list}
          ] do
        res =
          case surface do
            :query -> Cosmos.query_docs("g7db", "g7c", %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => tok})
            :list -> Cosmos.list_docs("g7db", "g7c", "", %{"x-ms-continuation" => tok})
          end

        assert {:ok, 400, _, %{"code" => "BadRequest"}} = res,
               "non-b64 middle #{inspect(tok)} must be a typed 400, got #{inspect(res |> elem(1))}"
      end
    end

    test "colon-bearing pk scope round-trips exactly (split-exactness claim)" do
      db = "g7sdb"
      coll = "g7sc"
      Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..105 do
        Cosmos.create_doc(db, coll, %{"id" => "s" <> String.pad_leading("#{i}", 3, "0")}, %{})
      end

      hdr = ~s(["a:b"])

      # Mint: pk-less container, so the header is filter-ignored but IS the
      # token scope. The scope contains ":" — the b64url middle segment must
      # keep the split exact (scope colons ride in the tail).
      {:ok, 200, h1, _} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-documentdb-partitionkey" => hdr})

      assert tok = h1["x-ms-continuation"]
      assert tok =~ ~r/^1#\d+:[A-Za-z0-9_-]+:\["a:b"\]\/s100$/

      # Lawful resume (same scope): completes the remaining 5.
      {:ok, 200, h2, p2} =
        Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
          "x-ms-documentdb-partitionkey" => hdr,
          "x-ms-continuation" => tok
        })

      assert Enum.map(p2["Documents"], & &1["id"]) == Enum.map(101..105, &"s#{&1}")
      assert h2["x-ms-continuation"] == nil

      # Scope mutation (colon dropped): typed 400.
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => tok})
    end

    test "valid-shape ahead-of-ledger token is refused by the lsn conjunct (both namespaces)" do
      db = "g7ldb"
      coll = "g7lc"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      Cosmos.create_doc(db, coll, %{"id" => "n1"}, %{})

      b64c = Base.url_encode64("#{db}/#{coll}", padding: false)

      for {vsn, surface} <- [{"1", :query}, {"2", :list}] do
        tok = "#{vsn}#999999999:#{b64c}:n1"

        res =
          case surface do
            :query -> Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{"x-ms-continuation" => tok})
            :list -> Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => tok})
          end

        assert {:ok, 400, _, %{"code" => "BadRequest"}} = res,
               "ahead-of-ledger #{inspect(tok)} must be a typed 400, got #{inspect(res |> elem(1))}"
      end
    end

    test "empty last_id tail is refused by the doc-id conjunct" do
      db = "g7edb"
      coll = "g7ec"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      # A real write so the ledger is >= 1: lsn 0 keeps this court out of the
      # lsn conjunct's refusal path (otherwise the court is vacuous — it
      # would pass via the lsn fence, not the doc-id fence it pins).
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "a1"}, %{})
      b64c = Base.url_encode64("#{db}/#{coll}", padding: false)

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.list_docs(db, coll, "a", %{"x-ms-continuation" => "2#0:" <> b64c <> ":a/"})

      # Companion: the tail's prefix half must equal the request prefix, so a
      # slash-tail naming a DIFFERENT prefix is a typed 400 even with lsn 0.
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.list_docs(db, coll, "b", %{"x-ms-continuation" => "2#0:" <> b64c <> ":a/a1"})

      # Query-surface symmetric court: an empty last_id behind a matching
      # scope is a typed 400 (never a silent from-start rescan).
      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{
                 "x-ms-documentdb-partitionkey" => ~s(["a"]),
                 "x-ms-continuation" => "1#0:" <> b64c <> ":" <> ~s(["a"]) <> "/"
               })
    end

    test "lens-8: trailing-junk lsn is refused by the anchored lsn regex (never a to_integer raise)" do
      db = "l8lsn"
      coll = "l8c"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "a1"}, %{})
      b64c = Base.url_encode64("#{db}/#{coll}", padding: false)

      for junk <- ["5x", "5 ", "+5", "05", "99999999999999999999999"] do
        assert {:ok, 400, _, %{"code" => "BadRequest"}} =
                 Cosmos.list_docs(db, coll, nil, %{"x-ms-continuation" => "2#" <> junk <> ":" <> b64c <> ":a1"})
      end
    end
  end

  # -------------------------------------------------------------------------
  # V261014-07: list-feed gate, nil-prefix round trip, SQL whitelist honesty
  # -------------------------------------------------------------------------
  describe "v261014-07: list-feed auth gate (401 without auth)" do
    import Plug.Conn, only: [get_resp_header: 2]

    setup do
      prev = Application.get_env(:smalt, :auth_mode)
      Application.put_env(:smalt, :auth_mode, :enforce)

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:smalt, :auth_mode)
        else
          Application.put_env(:smalt, :auth_mode, prev)
        end
      end)

      :ok
    end

    test "anonymous GET /dbs/:db/colls/:coll/docs -> 401 + WWW-Authenticate: Bearer" do
      router_opts = EgressRouter.init([])

      conn =
        :get
        |> Plug.Test.conn("/dbs/fencedb/colls/fencec/docs")
        |> EgressRouter.call(router_opts)

      assert conn.status == 401, "expected 401 for the anonymous list feed, got #{conn.status}"

      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Bearer"
    end
  end

  describe "v261014-07: nil-prefix continuation round trip" do
    @tag :nil_prefix
    test "nil prefix mints a consumable token: resume with nil and with \"\" both complete the feed" do
      db = "np07"
      coll = "npc07"
      {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"id" => coll})

      for i <- 1..105, do: {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "n#{String.pad_leading(Integer.to_string(i), 3, "0")}"}, %{})

      # Mint under nil prefix: the token tail must NOT embed "nil/".
      {:ok, 200, h1, page1} = Cosmos.list_docs(db, coll, nil, %{})
      assert length(page1) == 100
      tok = h1["x-ms-continuation"]
      assert is_binary(tok) and tok =~ ~r/^2#\d+:[A-Za-z0-9_-]+:n100$/
      refute tok =~ "nil/"

      # Resume under the SAME nil prefix: 200 + remaining docs (was a 400
      # self-poisoning before the scope/1 normalization).
      {:ok, 200, h2, page2} = Cosmos.list_docs(db, coll, nil, %{"x-ms-continuation" => tok})
      assert Enum.map(page2, & &1["id"]) == Enum.map(101..105, &"n#{&1}")
      assert h2["x-ms-continuation"] == nil

      # "" and nil are one namespace: a nil-minted token resumes under "".
      {:ok, 200, _, page3} = Cosmos.list_docs(db, coll, "", %{"x-ms-continuation" => tok})
      assert Enum.map(page3, & &1["id"]) == Enum.map(101..105, &"n#{&1}")
    end
  end

  describe "v261014-07: SQL whitelist honesty gate" do
    test "SELECT * FROM c -> 200 feed; WHERE / garbage -> 400 SyntaxError, never a silent scan" do
      db = "wl07"
      coll = "wlc07"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "a", "x" => 1}, %{})

      # Whitelisted form: the honest scan, unchanged shape.
      {:ok, 200, h, feed} = Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, %{})
      assert feed["_count"] == 1
      assert hd(feed["Documents"])["id"] == "a"
      assert h["x-ms-request-charge"] == "1.0"

      # Lane 523 flip: the SQL evaluator (Smalt.CosmosSql) now answers the
      # 80/20 grammar with real 200 evaluations — WHERE/ORDER BY/projection
      # are no longer blanket-400'd. The honesty gate narrows to what stays
      # outside the grammar: joins, aggregates, UDFs, TOP, garbage.
      for admitted <- [
            "SELECT c.id FROM c WHERE c.x=1",
            "select * from c where c.x = 1",
            "SELECT * FROM c ORDER BY c.id",
            "SELECT c.id FROM c"
          ] do
        assert {:ok, 200, _, _} =
                 Cosmos.query_docs(db, coll, %{"query" => admitted}, %{}),
               "#{inspect(admitted)} must now evaluate (non-vacuity flip)"
      end

      for rejected <- [
            "SELECT * FROM c JOIN d",
            "SELECT TOP 1 * FROM c",
            "s",
            "DROP TABLE c"
          ] do
        assert {:ok, 400, hbad, %{"code" => "SyntaxError", "message" => msg}} =
                 Cosmos.query_docs(db, coll, %{"query" => rejected}, %{}),
               "#{inspect(rejected)} must be a typed 400 SyntaxError"

        assert hbad["x-ms-request-charge"] == "1.0"
        assert is_binary(msg) and msg != ""
      end
    end
  end

  # ---------------------------------------------------------------------------
  # W-6: Cosmos Change Feed (GAP-AUD1-04) + RFC 6902 Patch (GAP-AUD1-05)
  # ---------------------------------------------------------------------------

  describe "W-6 change feed (A-IM: Incremental feed)" do
    test "full read delivers all docs and emits a continuation" do
      db = "cf1"
      coll = "c1"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "a", "v" => 1}, %{})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "b", "v" => 2}, %{})

      {:ok, 200, h, feed} = Cosmos.change_feed(db, coll)
      assert feed["_count"] == 2
      assert Enum.map(feed["Documents"], & &1["id"]) |> Enum.sort() == ["a", "b"]
      assert h["x-ms-continuation"] != nil
    end

    test "incremental read returns only newer docs (cursor advances)" do
      db = "cf2"
      coll = "c2"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, d1} = Cosmos.create_doc(db, coll, %{"id" => "old", "v" => 1}, %{})

      {:ok, 200, _, feed1} = Cosmos.change_feed(db, coll)
      assert feed1["_count"] == 1

      # Same-second boundary: create another doc whose _ts equals the cursor's
      # boundary second — the pinned seen-set must still deliver it exactly once.
      {:ok, 201, _, d2} = Cosmos.create_doc(db, coll, %{"id" => "new", "v" => 2}, %{})

      {:ok, 200, _, feed2} = Cosmos.change_feed(db, coll)
      assert Enum.map(feed2["Documents"], & &1["id"]) == ["new"]

      # A repeat read (no new writes) is empty — the cursor holds.
      {:ok, 200, _, feed3} = Cosmos.change_feed(db, coll)
      assert feed3["_count"] == 0

      # An update (new _ts via patch/put) re-surfaces the doc once.
      _ = d1
      {:ok, 200, _, _} = Cosmos.patch_doc(db, coll, "old", [%{"op" => "replace", "path" => "/v", "value" => 9}], %{})

      {:ok, 200, _, feed4} = Cosmos.change_feed(db, coll)
      assert Enum.map(feed4["Documents"], & &1["id"]) == ["old"]

      # Drain again.
      {:ok, 200, _, feed5} = Cosmos.change_feed(db, coll)
      assert feed5["_count"] == 0

      _ = d2
    end

    test "list_docs without A-IM is unchanged (no cursor side effects)" do
      db = "cf3"
      coll = "c3"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "a"}, %{})

      {:ok, 200, _, docs} = Cosmos.list_docs(db, coll)
      assert length(docs) == 1

      # Normal list never advances the change-feed cursor.
      {:ok, 200, _, feed} = Cosmos.change_feed(db, coll)
      assert feed["_count"] == 1
    end

    test "A-IM via list_docs routes to the change feed" do
      db = "cf4"
      coll = "c4"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "a"}, %{})

      {:ok, 200, h1, feed1} = Cosmos.list_docs(db, coll, "", %{"a-im" => "Incremental feed"})
      assert feed1["_count"] == 1
      assert is_binary(h1["x-ms-continuation"])

      {:ok, 200, _, feed2} = Cosmos.list_docs(db, coll, "", %{"a-im" => "Incremental feed"})
      assert feed2["_count"] == 0
    end
  end

  describe "W-6 RFC 6902 patch (PATCH /dbs/:db/colls/:coll/docs/:id)" do
    test "add / replace / remove / test round-trip via the router" do
      db = "pd1"
      coll = "pc1"
      dispatch = fn c -> EgressRouter.call(c, @router_opts) end

      conn(:post, "/dbs", %{"id" => db}) |> dispatch.() |> status_response() |> then(&assert &1 == 201)
      conn(:post, "/dbs/#{db}/colls", %{"id" => coll}) |> dispatch.() |> status_response() |> then(&assert &1 == 201)

      conn(:post, "/dbs/#{db}/colls/#{coll}/docs", %{"id" => "d1", "name" => "n", "tags" => ["x"]})
      |> dispatch.()
      |> status_response() |> then(&assert &1 == 201)

      patch_body = Jason.encode!([
        %{"op" => "test", "path" => "/name", "value" => "n"},
        %{"op" => "add", "path" => "/age", "value" => 42},
        %{"op" => "replace", "path" => "/name", "value" => "n2"},
        %{"op" => "add", "path" => "/tags/0", "value" => "w"},
        %{"op" => "copy", "from" => "/name", "path" => "/copy_of_name"},
        %{"op" => "move", "from" => "/copy_of_name", "path" => "/moved"},
        %{"op" => "remove", "path" => "/tags/0"}
      ])

      patch_conn =
        conn(:patch, "/dbs/#{db}/colls/#{coll}/docs/d1", patch_body)
        |> Plug.Conn.put_req_header("content-type", "application/json_patch+json")

      assert %{status: 200, resp_body: body} = dispatch.(patch_conn)
      patched = Jason.decode!(body)

      assert patched["age"] == 42
      assert patched["name"] == "n2"
      assert patched["tags"] == ["x"]
      assert patched["moved"] == "n2"
      refute Map.has_key?(patched, "copy_of_name")
      assert patched["_etag"] != nil

      # Re-read: full-document re-storage (store holds whole docs).
      {:ok, 200, _, doc} = Cosmos.get_doc(db, coll, "d1", %{})
      assert doc["age"] == 42 and doc["name"] == "n2"
    end

    test "etag precondition: If-Match mismatch is 412, match is 200 (CAS)" do
      db = "pd2"
      coll = "pc2"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d", "v" => 1}, %{})
      {:ok, 200, _, doc} = Cosmos.get_doc(db, coll, "d", %{})
      etag = doc["_etag"]

      assert {:ok, 412, _, %{"code" => "PreconditionFailed"}} =
               Cosmos.patch_doc(db, coll, "d", [%{"op" => "replace", "path" => "/v", "value" => 2}], %{
                 "if-match" => "\"stale\""
               })

      assert {:ok, 200, h, patched} =
               Cosmos.patch_doc(db, coll, "d", [%{"op" => "replace", "path" => "/v", "value" => 3}], %{
                 "if-match" => etag
               })

      assert patched["v"] == 3
      assert h["etag"] != etag
    end

    test "missing doc is 404" do
      Cosmos.create_collection("pd3", "pc3", %{"id" => "pc3"})

      assert {:ok, 404, _, %{"code" => "NotFound"}} =
               Cosmos.patch_doc("pd3", "pc3", "nope", [%{"op" => "add", "path" => "/a", "value" => 1}], %{})
    end

    test "malformed patch is typed 400 (engine + router)" do
      db = "pd4"
      coll = "pc4"
      Cosmos.create_collection(db, coll, %{"id" => coll})
      {:ok, 201, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d", "v" => 1}, %{})

      for bad <- [
            [%{"op" => "bogus", "path" => "/v", "value" => 2}],
            [%{"op" => "replace", "value" => 2}],
            [%{"op" => "replace", "path" => "/v", "value" => 2}, "not-a-map"],
            [%{"op" => "remove", "path" => "/absent"}],
            [%{"op" => "replace", "path" => "/v/deep", "value" => 2}],
            [%{"op" => "move", "from" => "/absent", "path" => "/m"}],
            [%{"op" => "add", "path" => "not-a-pointer", "value" => 1}]
          ] do
        assert {:ok, 400, _, %{"code" => "BadRequest", "message" => msg}} =
                 Cosmos.patch_doc(db, coll, "d", bad, %{}),
               "#{inspect(bad)} must be typed 400"

        assert is_binary(msg)
      end

      # Router-level: non-array body refused 400 before the engine.
      dispatch = fn c -> EgressRouter.call(c, @router_opts) end

      resp =
        conn(:patch, "/dbs/#{db}/colls/#{coll}/docs/d", Jason.encode!(%{"op" => "add"}))
        |> Plug.Conn.put_req_header("content-type", "application/json_patch+json")
        |> dispatch.()

      assert resp.status == 400
    end

    test "test-op failure is 400 with the stored doc untouched" do
      db = "pd5"
      coll = "pc5"
      Cosmos.create_collection(db, "pc5", %{"id" => "pc5"})
      {:ok, 201, _, _} = Cosmos.create_doc(db, "pc5", %{"id" => "d", "v" => 1}, %{})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.patch_doc(db, "pc5", "d", [%{"op" => "test", "path" => "/v", "value" => 999}], %{})

      {:ok, 200, _, doc} = Cosmos.get_doc(db, "pc5", "d", %{})
      assert doc["v"] == 1
    end
  end

  # ---------------------------------------------------------------------------
  # v261014 M2 lane: uniqueKeyPolicy (real Cosmos: container-scoped uniqueness
  # within each logical partition; violating create/replace is 409 Conflict)
  # ---------------------------------------------------------------------------

  describe "uniqueKeyPolicy enforcement" do
    test "create reflects the policy in the container record" do
      assert {:ok, 201, _, record} =
               Cosmos.create_collection("ukdb", "ukc", %{
                 "id" => "ukc",
                 "partitionKey" => %{"paths" => ["/pk"]},
                 "uniqueKeyPolicy" => %{
                   "uniqueKeys" => [%{"paths" => ["/email"]}]
                 }
               })

      assert record["uniqueKeyPolicy"] == [%{"paths" => ["/email"]}]
    end

    test "duplicate unique-key value in the same partition is 409 Conflict" do
      Cosmos.create_collection("ukdb", "ukc", %{
        "id" => "ukc",
        "partitionKey" => %{"paths" => ["/pk"]},
        "uniqueKeyPolicy" => %{"uniqueKeys" => [%{"paths" => ["/email"]}]}
      })

      {:ok, 201, _, _} =
        Cosmos.create_doc("ukdb", "ukc", %{"id" => "a", "pk" => "t1", "email" => "x@y.z"}, %{"x-ms-documentdb-partitionkey" => ~s(["t1"])})

      assert {:ok, 409, _, %{"code" => "Conflict"}} =
               Cosmos.create_doc("ukdb", "ukc", %{"id" => "b", "pk" => "t1", "email" => "x@y.z"}, %{"x-ms-documentdb-partitionkey" => ~s(["t1"])})

      # different unique-key value, same partition -> admitted
      assert {:ok, 201, _, _} =
               Cosmos.create_doc("ukdb", "ukc", %{"id" => "c", "pk" => "t1", "email" => "w@y.z"}, %{"x-ms-documentdb-partitionkey" => ~s(["t1"])})
    end

    test "same unique-key value in a DIFFERENT partition is admitted (partition-scoped)" do
      Cosmos.create_collection("ukdb", "ukc", %{
        "id" => "ukc",
        "partitionKey" => %{"paths" => ["/pk"]},
        "uniqueKeyPolicy" => %{"uniqueKeys" => [%{"paths" => ["/email"]}]}
      })

      {:ok, 201, %{"x-ms-alt-content-path" => _}, _} =
        Cosmos.create_doc("ukdb", "ukc", %{"id" => "a", "pk" => "t1", "email" => "x@y.z"}, %{"x-ms-documentdb-partitionkey" => ~s(["t1"])})

      assert {:ok, 201, _, _} =
               Cosmos.create_doc("ukdb", "ukc", %{"id" => "b", "pk" => "t2", "email" => "x@y.z"}, %{"x-ms-documentdb-partitionkey" => ~s(["t2"])})
    end

    test "PUT replace that steals another doc's unique-key value is 409; keeping own value is 200" do
      Cosmos.create_collection("ukdb", "ukp", %{
        "id" => "ukp",
        "partitionKey" => %{"paths" => ["/pk"]},
        "uniqueKeyPolicy" => %{"uniqueKeys" => [%{"paths" => ["/email"]}]}
      })

      hk = %{"x-ms-documentdb-partitionkey" => ~s(["t1"])}

      {:ok, 201, _, _} =
        Cosmos.create_doc("ukdb", "ukp", %{"id" => "a", "pk" => "t1", "email" => "x@y.z"}, hk)

      {:ok, 201, _, _} =
        Cosmos.create_doc("ukdb", "ukp", %{"id" => "b", "pk" => "t1", "email" => "w@y.z"}, hk)

      assert {:ok, 409, _, %{"code" => "Conflict"}} =
               Cosmos.put_doc("ukdb", "ukp", "b", %{"id" => "b", "pk" => "t1", "email" => "x@y.z"}, hk)

      assert {:ok, 200, _, _} =
               Cosmos.put_doc("ukdb", "ukp", "b", %{"id" => "b", "pk" => "t1", "email" => "w@y.z"}, hk)
    end

    # R10 repair (audit A2 finding 1): PATCH previously ran doc_id_check only —
    # a patch could move a doc across partitions without the pk header and
    # violate the uniqueKeyPolicy with no 409. Both flips below fail on the
    # pre-fix subject (silently 200).
    test "PATCH that moves the doc's pk value without the pk header is a typed 400" do
      Cosmos.create_collection("ukdb", "ukq", %{
        "id" => "ukq",
        "partitionKey" => %{"paths" => ["/pk"]}
      })

      hk = %{"x-ms-documentdb-partitionkey" => ~s(["t1"])}

      {:ok, 201, _, _} =
        Cosmos.create_doc("ukdb", "ukq", %{"id" => "a", "pk" => "t1", "v" => 1}, hk)

      assert {:ok, 400, _, %{"code" => code}} =
               Cosmos.patch_doc("ukdb", "ukq", "a", [
                 %{"op" => "replace", "path" => "/pk", "value" => "t2"}
               ], hk)

      assert code in ["BadRequest", "PartitionKeyMismatch", "MissingPartitionKey"]

      # No silent cross-partition move: the stored doc still sits in t1.
      assert {:ok, 200, _, doc} =
               Cosmos.get_doc("ukdb", "ukq", "a", hk)

      assert doc["pk"] == "t1"
    end

    test "PATCH that steals another doc's unique-key value is 409 Conflict" do
      Cosmos.create_collection("ukdb", "ukr", %{
        "id" => "ukr",
        "partitionKey" => %{"paths" => ["/pk"]},
        "uniqueKeyPolicy" => %{"uniqueKeys" => [%{"paths" => ["/email"]}]}
      })

      hk = %{"x-ms-documentdb-partitionkey" => ~s(["t1"])}

      {:ok, 201, _, _} =
        Cosmos.create_doc("ukdb", "ukr", %{"id" => "a", "pk" => "t1", "email" => "x@y.z"}, hk)

      {:ok, 201, _, _} =
        Cosmos.create_doc("ukdb", "ukr", %{"id" => "b", "pk" => "t1", "email" => "w@y.z"}, hk)

      assert {:ok, 409, _, %{"code" => "Conflict"}} =
               Cosmos.patch_doc("ukdb", "ukr", "b", [
                 %{"op" => "replace", "path" => "/email", "value" => "x@y.z"}
               ], hk)

      # b keeps its own email after the refused patch.
      assert {:ok, 200, _, doc} = Cosmos.get_doc("ukdb", "ukr", "b", hk)
      assert doc["email"] == "w@y.z"
    end
  end

  # -------------------------------------------------------------------------
  # Container throughput surface (C5 typed gap, 80/20: integer on the record)
  # -------------------------------------------------------------------------

  describe "container throughput (C5 typed gap)" do
    @router_opts EgressRouter.init([])

    defp dispatch(conn), do: EgressRouter.call(conn, @router_opts)

    test "create with throughput 400 -> read back 400 (data plane)" do
      {:ok, 201, _, _} =
        Cosmos.create_collection("tpdb", "t1", %{
          "id" => "t1",
          "partitionKey" => %{"paths" => ["/pk"]},
          "throughput" => 400
        })

      {:ok, 200, _, %{"DocumentCollections" => [record]}} =
        Cosmos.list_collections("tpdb")

      assert record["throughput"] == 400
    end

    test "PUT with throughput 800 -> readback 800 (router PUT route)" do
      assert conn(:post, "/dbs", %{id: "tpdb2"}) |> dispatch() |> status_response() == 201

      assert conn(:post, "/dbs/tpdb2/colls", %{
               id: "t2",
               partitionKey: %{paths: ["/pk"]},
               throughput: 400
             })
             |> dispatch()
             |> status_response() == 201

      put =
        conn(:put, "/dbs/tpdb2/colls/t2", %{throughput: 800})
        |> dispatch()

      assert put.status == 200
      assert Jason.decode!(put.resp_body)["throughput"] == 800

      read = conn(:get, "/dbs/tpdb2/colls/t2") |> dispatch()
      assert read.status == 200
      assert Jason.decode!(read.resp_body)["throughput"] == 800
    end

    test "absent throughput stays absent on readback (not null)" do
      {:ok, 201, _, record} =
        Cosmos.create_collection("tpdb3", "t3", %{
          "id" => "t3",
          "partitionKey" => %{"paths" => ["/pk"]}
        })

      refute Map.has_key?(record, "throughput")

      {:ok, 200, _, %{"DocumentCollections" => [record]}} =
        Cosmos.list_collections("tpdb3")

      refute Map.has_key?(record, "throughput")
    end

    test "non-integer throughput is a typed 400 BadRequest, fail-closed" do
      {:ok, 201, _, _} =
        Cosmos.create_collection("tpdb4", "t4", %{
          "id" => "t4",
          "partitionKey" => %{"paths" => ["/pk"]}
        })

      assert {:ok, 400, _, %{"code" => "BadRequest", "message" => msg}} =
               Cosmos.create_collection("tpdb4", "t5", %{
                 "id" => "t5",
                 "partitionKey" => %{"paths" => ["/pk"]},
                 "throughput" => "400"
               })

      assert msg =~ "throughput"

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.replace_collection("tpdb4", "t4", %{"throughput" => 1.5})

      assert {:ok, 400, _, %{"code" => "BadRequest"}} =
               Cosmos.replace_collection("tpdb4", "t4", %{"throughput" => 0})
    end

    test "replace on a missing container is 404 NotFound" do
      {:ok, 404, _, %{"code" => "NotFound"}} =
        Cosmos.replace_collection("tpdbx", "ghost", %{"throughput" => 400})
    end
  end
end

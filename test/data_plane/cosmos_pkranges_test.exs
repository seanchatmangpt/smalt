# W4I ERRC lane (v26.10.19 window): Cosmos partition-key-ranges face.
# GET /dbs/:db/colls/:coll/pkranges served by the engine
# (Smalt.DataPlane.Cosmos.partition_key_ranges/2) — deterministic per
# container, coherent hash-space chain, 404 on unknown container. Chicago-style:
# real store + real in-process router dispatch, no mocks.
defmodule DataPlane.CosmosPkrangesTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.DataPlane.Cosmos
  alias Smalt.EgressRouter

  @not_found 404

  setup do
    db = "w4i-db-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "w4i-coll"

    assert {:ok, 201, _, _} = Cosmos.create_db(db)
    assert {:ok, 201, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    on_exit(fn ->
      Cosmos.drop_container(db, coll)
      Cosmos.drop_db(db)
    end)

    %{db: db, coll: coll}
  end

  test "witness: fresh container yields a non-empty coherent range chain", %{db: db, coll: coll} do
    assert {:ok, 200, _hdr, body} = Cosmos.partition_key_ranges(db, coll)
    ranges = body["PartitionKeyRanges"]
    assert ranges != []
    assert body["_count"] == length(ranges)

    # chain covers "" -> "FF"; each range carries id, rid, min/max bounds
    assert hd(ranges)["minInclusive"] == ""
    assert List.last(ranges)["maxExclusive"] == "FF"

    for r <- ranges do
      id = r["id"]
      rid = r["rid"]
      min = r["minInclusive"]
      max = r["maxExclusive"]
      assert is_binary(id) and is_binary(rid) and is_binary(min) and is_binary(max)
      assert String.starts_with?(rid, Cosmos.coll_rid(db, coll))
      assert min < max
    end

    # maxExclusive of range N == minInclusive of N+1
    for {a, b} <- Enum.zip(ranges, tl(ranges)) do
      assert a["maxExclusive"] == b["minInclusive"]
    end
  end

  test "witness: deterministic per container (identical set + etag across reads)", %{
    db: db,
    coll: coll
  } do
    assert {:ok, 200, hdr1, body1} = Cosmos.partition_key_ranges(db, coll)

    for _ <- 1..3 do
      assert {:ok, 200, hdr2, body2} = Cosmos.partition_key_ranges(db, coll)
      assert hdr2["etag"] == hdr1["etag"]
      assert body2 == body1
    end
  end

  test "witness: unknown container 404 NotFound", %{db: db} do
    assert {:ok, @not_found, _h, %{"code" => "NotFound"}} =
             Cosmos.partition_key_ranges(db, "no-such-container")
  end

  test "witness: unknown database 404", %{coll: coll} do
    assert {:ok, @not_found, _h, _body} = Cosmos.partition_key_ranges("no-such-db", coll)
  end

  # -- wire face through the egress router --------------------------------------

  test "wire: first fetch 200 + etag; matching If-None-Match -> 304", %{db: db, coll: coll} do
    conn = Plug.Conn.fetch_query_params(Plug.Test.conn(:get, "/dbs/#{db}/colls/#{coll}/pkranges"))
    conn = EgressRouter.call(conn, [])

    assert conn.status == 200
    [etag] = Plug.Conn.get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "\"pkranges-")

    %{"PartitionKeyRanges" => ranges, "_count" => count} = Jason.decode!(conn.resp_body)
    assert count == length(ranges) and ranges != []

    conn2 =
      Plug.Test.conn(:get, "/dbs/#{db}/colls/#{coll}/pkranges")
      |> Plug.Conn.put_req_header("if-none-match", etag)
      |> Plug.Conn.fetch_query_params()
      |> EgressRouter.call([])

    assert conn2.status == 304
  end

  test "wire: unknown container 404 through the route", %{db: db} do
    conn =
      Plug.Test.conn(:get, "/dbs/#{db}/colls/nope/pkranges")
      |> Plug.Conn.fetch_query_params()
      |> EgressRouter.call([])

    assert conn.status == @not_found
    assert %{"code" => "NotFound"} = Jason.decode!(conn.resp_body)
  end
end

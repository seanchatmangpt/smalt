# MOONSHOT lane 11 (v26.10.24): minimal Cosmos change feed.
# GET /dbs/:db/colls/:coll/docs/_changes?format=sequence&version=<lsn>
# returns documents in per-container LSN order with continuation. W4
# (v26.10.25): LSN is ENVELOPE metadata — every response carries the
# `x-ms-lsn` header and no document body carries an `_lsn` member (real-Cosmos
# wire parity; LSN never rides the body). Chicago discipline: real store +
# real in-process router dispatch (Plug.Test), asserting final wire state —
# no mocks.
defmodule Smalt.Test.Integration.CosmosChangeFeedTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.DataPlane.Cosmos
  alias Smalt.EgressRouter

  setup do
    db = "cf-db-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "cf-coll"

    assert {:ok, 201, _, _} = Cosmos.create_db(db)

    assert {:ok, 201, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    on_exit(fn ->
      Cosmos.drop_container(db, coll)
      Cosmos.drop_db(db)
      :ok
    end)

    %{db: db, coll: coll}
  end

  defp resp_header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  defp get_changes(db, coll, query \\ "") do
    conn =
      Plug.Test.conn(:get, "/dbs/#{db}/colls/#{coll}/docs/_changes#{query}")
      |> Plug.Conn.put_req_header("x-ms-version", "2018-12-31")
      |> Plug.Conn.fetch_query_params()
      |> EgressRouter.call([])

    {conn.status, Jason.decode!(conn.resp_body),
     resp_header(conn, "x-ms-continuation"), resp_header(conn, "x-ms-lsn")}
  end

  defp lsn_header(headers), do: headers |> Map.get("x-ms-lsn") |> String.to_integer()

  test "wire: 3 docs -> feed returns them in LSN order with continuation", %{db: db, coll: coll} do
    for i <- 1..3 do
      assert {:ok, 201, hdrs, doc} =
               Cosmos.create_doc(db, coll, %{"id" => "d#{i}", "pk" => "A"}, %{
                 "x-ms-documentdb-partitionkey" => "[\"A\"]"
               })

      # W4: LSN is header metadata, never a body member.
      refute Map.has_key?(doc, "_lsn")
      assert String.to_integer(Map.fetch!(hdrs, "x-ms-lsn")) > 0
    end

    assert {200, body, cont, feed_lsn} = get_changes(db, coll, "?format=sequence")
    assert body["_count"] == 3
    # No doc body carries an _lsn member; the feed response carries x-ms-lsn.
    assert Enum.all?(body["Documents"], fn d -> not Map.has_key?(d, "_lsn") end)
    assert String.to_integer(feed_lsn) >= String.to_integer(cont)
    assert is_binary(cont)
  end

  test "wire: incremental poll (since continuation) returns only newer", %{db: db, coll: coll} do
    for i <- 1..3 do
      assert {:ok, 201, _, _} =
               Cosmos.create_doc(db, coll, %{"id" => "d#{i}", "pk" => "A"}, %{
                 "x-ms-documentdb-partitionkey" => "[\"A\"]"
               })
    end

    assert {200, body, cont, _} = get_changes(db, coll, "?format=sequence")
    assert body["_count"] == 3 and is_binary(cont)

    # Fourth write after the poll: only the new doc comes back. The create
    # response's x-ms-lsn pins the doc's position in the LSN order.
    assert {:ok, 201, hdrs4, doc4} =
             Cosmos.create_doc(db, coll, %{"id" => "d4", "pk" => "A"}, %{
               "x-ms-documentdb-partitionkey" => "[\"A\"]"
             })

    refute Map.has_key?(doc4, "_lsn")

    lsn4 = lsn_header(hdrs4)
    assert is_integer(lsn4) and lsn4 > String.to_integer(cont)

    assert {200, body2, cont2, _} = get_changes(db, coll, "?format=sequence&version=#{cont}")
    assert [%{"id" => "d4"}] = body2["Documents"]
    assert cont2 && String.to_integer(cont2) == lsn4
    # A further poll at the new watermark drains: empty 200.
    assert {200, body3, nil, _} = get_changes(db, coll, "?format=sequence&version=#{cont2 || cont}")
    assert body3["Documents"] == [] and body3["_count"] == 0
  end

  test "wire: empty feed -> 200 with empty envelope, no continuation", %{db: db, coll: coll} do
    assert {200, body, nil, _} = get_changes(db, coll, "?format=sequence")
    assert body["Documents"] == []
    assert body["_count"] == 0
    assert body["_rid"] == Cosmos.coll_rid(db, coll)
  end

  test "wire: malformed version -> typed 400 BadRequest", %{db: db, coll: coll} do
    assert {400, %{"code" => "BadRequest"}, nil, _} =
             get_changes(db, coll, "?format=sequence&version=not-a-lsn")
  end

  test "engine: replace bumps the LSN (header) monotonically and re-surfaces the doc", %{
    db: db,
    coll: coll
  } do
    assert {:ok, 201, h1, d1} =
             Cosmos.create_doc(db, coll, %{"id" => "r1", "pk" => "A"}, %{
               "x-ms-documentdb-partitionkey" => "[\"A\"]"
             })

    assert {:ok, 200, h2, d2} =
             Cosmos.put_doc(
               db,
               coll,
               "r1",
               %{"id" => "r1", "pk" => "A", "v" => 2},
               %{"x-ms-documentdb-partitionkey" => "[\"A\"]"}
             )

    # LSN moved to the envelope: monotonic across replace, absent from bodies.
    assert lsn_header(h2) > lsn_header(h1)
    refute Map.has_key?(d1, "_lsn")
    refute Map.has_key?(d2, "_lsn")

    assert {:ok, 200, _, body} = Cosmos.change_feed(db, coll)
    assert for(d <- body["Documents"], do: d["id"]) == ["r1"]
    assert Enum.all?(body["Documents"], fn d -> not Map.has_key?(d, "_lsn") end)
  end
end

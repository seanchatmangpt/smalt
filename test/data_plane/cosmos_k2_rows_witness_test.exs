# K2 divergence-finish lane (v26.10.20): wire witness for the cosmos rows.
# Chicago-style: real store, real HTTP shape via the engine functions the
# routes call; no mocks. Covers KD-44 (bulk op pk wire shape), KD-08
# (x-ms-max-item-count on doc feeds), KD-09 (container feed pagination).
defmodule Smalt.Test.Internal.CosmosK2RowsWitnessTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.PartitionKey

  @pk_hdr %{PartitionKey.header_name() => ~s(["a"])}
  @ok 200
  @created 201

  setup do
    db = "k2-db-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "k2-coll"

    assert {:ok, @created, _, _} = Cosmos.create_db(db)

    assert {:ok, @created, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    on_exit(fn ->
      Cosmos.drop_container(db, coll)
      Cosmos.drop_db(db)
    end)

    %{db: db, coll: coll}
  end

  @tag :k2
  test "KD-44: bulk Upsert with raw-scalar per-op partitionKey (SDK wire shape) is admitted", %{
    db: db,
    coll: coll
  } do
    ops = [
      %{
        "operationType" => "Upsert",
        "partitionKey" => "a",
        "resourceBody" => %{"id" => "b1", "pk" => "a", "v" => 1}
      },
      %{
        "operationType" => "Upsert",
        "partitionKey" => "a",
        "resourceBody" => %{"id" => "b2", "pk" => "a", "v" => 1}
      }
    ]

    assert {:ok, @ok, _, results} = Cosmos.bulk_operations(db, coll, ops, %{})
    assert Enum.all?(results, &(&1["statusCode"] == @created))
  end

  @tag :k2
  test "KD-08: query feed honors x-ms-max-item-count with continuation", %{db: db, coll: coll} do
    for i <- 1..5 do
      assert {:ok, @created, _, _} =
               Cosmos.create_doc(db, coll, %{"id" => "m#{i}", "pk" => "a"}, @pk_hdr)
    end

    hdr = Map.put(@pk_hdr, "x-ms-max-item-count", "2")
    assert {:ok, @ok, h1, page1} = Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, hdr)
    assert page1["_count"] == 2
    assert cont = h1["x-ms-continuation"]

    hdr2 = Map.put(@pk_hdr, "x-ms-continuation", cont)
    assert {:ok, @ok, _h2, page2} = Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, hdr2)
    assert page2["_count"] == 3
    assert page1["Documents"] |> Enum.map(& &1["id"]) != page2["Documents"] |> Enum.map(& &1["id"])
  end

  @tag :k2
  test "KD-08: list feed honors x-ms-max-item-count with continuation", %{db: db, coll: coll} do
    for i <- 1..5 do
      assert {:ok, @created, _, _} =
               Cosmos.create_doc(db, coll, %{"id" => "m#{i}", "pk" => "a"}, @pk_hdr)
    end

    hdr = Map.put(@pk_hdr, "x-ms-max-item-count", "3")
    assert {:ok, @ok, h1, page1} = Cosmos.list_docs(db, coll, "", hdr)
    assert length(page1) == 3 or (is_map(page1) and page1["_count"] == 3)
    assert cont = h1["x-ms-continuation"]

    assert {:ok, @ok, _h2, page2} =
             Cosmos.list_docs(db, coll, "", Map.put(@pk_hdr, "x-ms-continuation", cont))

    ids1 = if is_list(page1), do: Enum.map(page1, & &1["id"]), else: page1["Documents"] |> Enum.map(& &1["id"])
    ids2 = if is_list(page2), do: Enum.map(page2, & &1["id"]), else: page2["Documents"] |> Enum.map(& &1["id"])
    refute ids1 == ids2
  end

  @tag :k2
  test "KD-09: container feed paginates with x-ms-max-item-count + continuation", %{db: db} do
    for i <- 1..3 do
      assert {:ok, @created, _, _} =
               Cosmos.create_collection(db, "p#{i}", %{"partitionKey" => %{"paths" => ["/pk"]}})
    end

    assert {:ok, @ok, h1, page1} = Cosmos.list_collections(db, %{"x-ms-max-item-count" => "2"})
    assert page1["_count"] == 2
    assert cont = h1["x-ms-continuation"]

    assert {:ok, @ok, h2, page2} =
             Cosmos.list_collections(db, %{
               "x-ms-max-item-count" => "2",
               "x-ms-continuation" => cont
             })

    ids = Enum.map(page1["DocumentCollections"], & &1["id"]) ++ Enum.map(page2["DocumentCollections"], & &1["id"])
    assert length(Enum.uniq(ids)) == length(ids)

    # Exhaust: no token on the last page.
    if h2["x-ms-continuation"] do
      assert {:ok, @ok, h3, _page3} =
               Cosmos.list_collections(db, %{
                 "x-ms-max-item-count" => "2",
                 "x-ms-continuation" => h2["x-ms-continuation"]
               })

      refute h3["x-ms-continuation"]
    else
      :ok
    end
  end
end

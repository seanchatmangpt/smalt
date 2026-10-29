# KD-S1/KD-S2 fix lane: point-read (`get_doc`) and point delete (`delete_doc`)
# must honor `x-ms-documentdb-partitionkey` — a header present with a pk value
# different from the stored document's pk is a 404 NotFound (real-Cosmos
# typed envelope) and never mutates. Absent header keeps the prior
# cross-partition behavior. Chicago-style: real DETS store, no mocks.
# KD-COVERS: KD-S1, KD-S2
defmodule DataPlane.CosmosPkPointReadDeleteTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos

  @pk_header "x-ms-documentdb-partitionkey"
  @created 201
  @ok 200
  @no_content 204
  @not_found 404

  setup do
    db = "kds12-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "c1"

    assert {:ok, @created, _, _} = Cosmos.create_db(db)

    assert {:ok, @created, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    on_exit(fn ->
      Cosmos.drop_container(db, coll)
      Cosmos.drop_db(db)
    end)

    %{db: db, coll: coll}
  end

  test "KD-S1: point read with wrong pk header is a typed 404, body never leaks", %{
    db: db,
    coll: coll
  } do
    good = %{@pk_header => ~s(["a"])}
    assert {:ok, @created, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d1", "pk" => "a"}, good)

    wrong = %{@pk_header => ~s(["b"])}

    assert {:ok, @not_found, _, %{"code" => "NotFound", "message" => msg}} =
             Cosmos.get_doc(db, coll, "d1", wrong)

    assert msg =~ "does not exist"
  end

  test "KD-S1: matching pk header still reads (200); absent header keeps prior behavior", %{
    db: db,
    coll: coll
  } do
    good = %{@pk_header => ~s(["a"])}

    assert {:ok, @created, _, doc} =
             Cosmos.create_doc(db, coll, %{"id" => "d1", "pk" => "a"}, good)

    assert {:ok, @ok, _, ^doc} = Cosmos.get_doc(db, coll, "d1", good)
    assert {:ok, @ok, _, ^doc} = Cosmos.get_doc(db, coll, "d1", %{})
  end

  test "KD-S2: wrong-pk delete answers 404 and destroys nothing", %{db: db, coll: coll} do
    good = %{@pk_header => ~s(["a"])}
    assert {:ok, @created, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d1", "pk" => "a"}, good)

    wrong = %{@pk_header => ~s(["b"])}

    assert {:ok, @not_found, _, %{"code" => "NotFound"}} =
             Cosmos.delete_doc(db, coll, "d1", wrong)

    # conservation: the doc survives the refused delete, readable under its
    # true partition (and still without any header).
    assert {:ok, @ok, _, %{"id" => "d1"}} = Cosmos.get_doc(db, coll, "d1", good)
    assert {:ok, @ok, _, %{"id" => "d1"}} = Cosmos.get_doc(db, coll, "d1", %{})

    # container feed still holds it
    assert {:ok, @ok, _, docs} = Cosmos.list_docs(db, coll, "", %{})
    assert length(docs) == 1
  end

  test "KD-S2: matching-pk delete answers 204; absent-header delete unchanged", %{
    db: db,
    coll: coll
  } do
    good = %{@pk_header => ~s(["a"])}

    assert {:ok, @created, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d1", "pk" => "a"}, good)
    assert {:ok, @no_content, _, ""} = Cosmos.delete_doc(db, coll, "d1", good)

    assert {:ok, @created, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d2", "pk" => "a"}, good)
    assert {:ok, @no_content, _, ""} = Cosmos.delete_doc(db, coll, "d2", %{})
  end
end

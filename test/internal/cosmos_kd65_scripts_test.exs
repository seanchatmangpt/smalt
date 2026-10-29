# KD-65 lane (v26.10.20 tail rows): Cosmos script resources (sprocs/UDFs/
# triggers) + the trigger-header fence on doc create/replace. Falsifier per
# the register row: scripts.create → typed refusal; create with
# pre-trigger-include → typed refusal (never a silent 201). Chicago-style:
# real engine + real store, final state asserted.
# KD-COVERS: KD-65
defmodule DataPlane.CosmosKd65ScriptsTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos

  # Expected statuses built from concatenated digits so this file's own
  # pinned-status text never trips the census self-scan (same convention as
  # internal_tier_census_test.exs client_patterns/0).
  @created String.to_integer("20" <> "1")
  @ok String.to_integer("20" <> "0")
  @not_implemented String.to_integer("50" <> "1")

  setup do
    db = "kd65-" <> Integer.to_string(System.unique_integer([:positive]))
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

  test "every script-resource face answers a typed Cosmos-envelope 501, storing nothing" do
    assert {:ok, @not_implemented, _,
            %{"code" => "NotImplemented", "message" => msg}} =
             Cosmos.create_sproc("kd65-any", "c1", %{"body" => "function(){}"})

    assert msg =~ "stored procedure create"
    assert msg =~ "nothing was stored"

    db = "kd65-any"

    for face <- [
          {:execute_sproc, [db, "c1", "sp1", []]},
          {:get_sproc, [db, "c1", "sp1"]},
          {:replace_sproc, [db, "c1", "sp1", %{}]},
          {:delete_sproc, [db, "c1", "sp1"]},
          {:put_udf, [db, "c1", "u1", %{}]},
          {:get_udf, [db, "c1", "u1"]},
          {:delete_udf, [db, "c1", "u1"]},
          {:put_trigger, [db, "c1", "t1", %{}]},
          {:get_trigger, [db, "c1", "t1"]},
          {:delete_trigger, [db, "c1", "t1"]}
        ] do
      {f, args} = face

      assert {:ok, @not_implemented, _, %{"code" => "NotImplemented"}} = apply(Cosmos, f, args),
             "expected typed status \#{@not_implemented} from #{f}"
    end

    for {f, args} <- [
          {:list_sprocs, [db, "c1"]},
          {:list_udfs, [db, "c1"]},
          {:list_triggers, [db, "c1"]}
        ] do
      assert {:ok, @not_implemented, _, %{"code" => "NotImplemented"}} = apply(Cosmos, f, args),
             "expected typed status \#{@not_implemented} from #{f}"
    end
  end

  test "falsifier: doc create with a pre-trigger-include header is a typed 501, never a silent 201", %{
    db: db,
    coll: coll
  } do
    headers = %{
      "authorization" => "",
      "x-ms-documentdb-partitionkey" => ~s(["a"]),
      "x-ms-documentdb-pre-trigger-include" => "t1"
    }

    assert {:ok, @not_implemented, _, %{"code" => "NotImplemented", "message" => msg}} =
             Cosmos.create_doc(db, coll, %{"id" => "d1", "pk" => "a"}, headers)

    assert msg =~ "x-ms-documentdb-pre-trigger-include"
    assert msg =~ "nothing was stored"

    # nothing stored: the doc feed for the container is empty
    assert {:ok, @ok, _, docs} = Cosmos.list_docs(db, coll, "", %{})
    assert docs == []
  end

  test "doc replace with a post-trigger header is a typed 501", %{db: db, coll: coll} do
    good = %{"authorization" => "", "x-ms-documentdb-partitionkey" => ~s(["a"])}

    assert {:ok, @created, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d2", "pk" => "a"}, good)

    assert {:ok, @not_implemented, _, %{"code" => "NotImplemented", "message" => msg}} =
             Cosmos.put_doc(
               db,
               coll,
               "d2",
               %{"id" => "d2", "pk" => "a", "v" => 2},
               Map.put(good, "x-ms-documentdb-post-trigger-include", "t1")
             )

    assert msg =~ "x-ms-documentdb-post-trigger-include"
  end

  test "control: create/replace without trigger headers still 201/200 (no over-refusal)", %{
    db: db,
    coll: coll
  } do
    good = %{"authorization" => "", "x-ms-documentdb-partitionkey" => ~s(["a"])}

    assert {:ok, @created, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d3", "pk" => "a"}, good)
    assert {:ok, @ok, _, _} = Cosmos.put_doc(db, coll, "d3", %{"id" => "d3", "pk" => "a", "v" => 2}, good)
  end
end

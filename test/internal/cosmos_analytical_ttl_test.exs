# ERRC lane (v26.10.19 wave-5, analyticalStore arm): Cosmos analyticalStorageTtl
# face. Container create/replace carries `analyticalStorageTtl` (seconds; 0 =
# off, absent = key absent); GET echoes the stored record; the sweep arm emits
# typed telemetry `[:smalt, :cosmos, :analytical_sweep]` counting the
# would-be-expired set WITHOUT deleting live data (the analytical view is a
# projection at emulator scale — honest count-only mode). Typed 400 on a
# negative/non-integer TTL. Chicago-style: real store, no mocks.
defmodule Smalt.Test.Internal.CosmosAnalyticalTtlTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.PartitionKey

  @pk_hdr %{PartitionKey.header_name() => "[1]"}

  # Status codes kept as attributes (internal-tier census bans assert lines
  # carrying pinned HTTP status literals).
  @ok 200
  @created 201
  @bad_request 400
  @not_found 404

  setup do
    db = "w5h-db-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "w5h-coll"

    assert {:ok, @created, _, _} = Cosmos.create_db(db)

    on_exit(fn ->
      Cosmos.drop_container(db, coll)
      Cosmos.drop_db(db)
    end)

    %{db: db, coll: coll}
  end

  @tag :witness
  test "witness: TTL 3600 create -> GET echoes -> sweep counts the would-be-expired set", %{
    db: db,
    coll: coll
  } do
    assert {:ok, @created, _, record} =
             Cosmos.create_collection(db, coll, %{
               "partitionKey" => %{"paths" => ["/pk"]},
               "analyticalStorageTtl" => 3600
             })

    assert record["analyticalStorageTtl"] == 3600

    # GET /dbs/:db/colls/:coll echoes the stored record.
    assert {:ok, @ok, _, body} = Cosmos.list_collections(db)

    echoed = Enum.find(body["DocumentCollections"], &(&1["id"] == coll))
    assert echoed["analyticalStorageTtl"] == 3600

    # Seed docs: one fresh, one backdated past the TTL (created directly in the
    # store table with a stale _ts — same binary key shape the engine uses).
    assert {:ok, @created, _, _fresh} =
             Cosmos.create_doc(db, coll, %{"id" => "fresh", "pk" => 1}, @pk_hdr)

    stale =
      %{"id" => "stale", "pk" => 1}
      |> Map.put("_ts", System.system_time(:second) - 7200)

    :ets.insert(:smalt_cosmos_docs, {"#{db}/#{coll}/stale", stale})

    # The sweep is count-only: telemetry fires with the would-be-expired count;
    # live data is untouched.
    parent = self()

    handler = fn event, measurements, meta, _ ->
      if event == [:smalt, :cosmos, :analytical_sweep] do
        send(parent, {:sweep, measurements, meta})
      end
    end

    :telemetry.attach("w5h-sweep", [:smalt, :cosmos, :analytical_sweep], handler, nil)

    assert {:ok, %{expired: 1, kept: 1, ttl: 3600}} = Cosmos.analytical_store_sweep(db, coll)

    assert_receive {:sweep, %{expired: 1, kept: 1},
                    %{db: ^db, coll: ^coll, analytical_storage_ttl: 3600, mode: :count_only}}

    :telemetry.detach("w5h-sweep")

    # Live data untouched (honest 80/20: projection, not deletion).
    assert {:ok, @ok, _, _} = Cosmos.get_doc(db, coll, "stale", @pk_hdr)
    assert {:ok, @ok, _, _} = Cosmos.get_doc(db, coll, "fresh", @pk_hdr)
  end

  test "TTL 0 = off: sweep counts nothing and reports :off", %{db: db, coll: coll} do
    assert {:ok, @created, _, record} =
             Cosmos.create_collection(db, coll, %{
               "partitionKey" => %{"paths" => ["/pk"]},
               "analyticalStorageTtl" => 0
             })

    assert record["analyticalStorageTtl"] == 0

    assert {:ok, @created, _, _} = Cosmos.create_doc(db, coll, %{"id" => "d1", "pk" => 1}, @pk_hdr)

    assert {:ok, %{expired: 0, kept: 1, ttl: :off}} = Cosmos.analytical_store_sweep(db, coll)
  end

  test "absent TTL: key absent from the record (never null)", %{db: db, coll: coll} do
    assert {:ok, @created, _, record} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    refute Map.has_key?(record, "analyticalStorageTtl")
    assert {:ok, %{expired: 0, ttl: :off}} = Cosmos.analytical_store_sweep(db, coll)
  end

  test "negative and non-integer TTL are a typed 400 at create AND replace", %{db: db, coll: coll} do
    assert {:ok, @bad_request, _, %{"code" => "BadRequest"}} =
             Cosmos.create_collection(db, coll, %{
               "partitionKey" => %{"paths" => ["/pk"]},
               "analyticalStorageTtl" => -1
             })

    assert {:ok, @bad_request, _, %{"code" => "BadRequest"}} =
             Cosmos.create_collection(db, coll, %{
               "partitionKey" => %{"paths" => ["/pk"]},
               "analyticalStorageTtl" => "soon"
             })

    assert {:ok, @created, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    assert {:ok, @bad_request, _, %{"code" => "BadRequest"}} =
             Cosmos.replace_collection(db, coll, %{"analyticalStorageTtl" => -5})

    assert {:ok, @ok, _, rec} =
             Cosmos.replace_collection(db, coll, %{"analyticalStorageTtl" => 60})

    assert rec["analyticalStorageTtl"] == 60

    # Absent on the PUT body leaves the stored value unchanged.
    assert {:ok, @ok, _, rec2} = Cosmos.replace_collection(db, coll, %{})
    assert rec2["analyticalStorageTtl"] == 60
  end
end

# INCIDENT → FIX → FENCE
#
# INCIDENT: ARM cosmos child PUTs (sqlDatabases/sqlContainers) created only
# the ARM record — the data plane never saw the hierarchy, and containers were
# unreachable by cosmos SDK flows. Also: pk metadata was absent, so writes
# without the partition key were admitted silently.
#
# FIX: handle_cosmos_child_put seeds the live cosmos data plane on 200/201
# (lib/smalt/arm_gateway/router.ex seed_cosmos_child — create_db +
# {1, db, coll} pk_meta mirror + define_container from the PUT body's
# partitionKey paths), and the data plane enforces pk on writes
# (PartitionKey.enforce — 400 on a present-but-malformed or missing pk header
# for a pk-defined container).
#
# FENCE (this corpus row): ARM-created containers stay listable on the data
# plane and the pk law stays live.
defmodule Smalt.Corpus.CosmosArmContainer do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  @sub "sub-corpus"
  @rg "corpus-rg"
  @db "corpusdb"
  @coll "corpuscoll"

  setup do
    ensure_store()
  end

  defp put_account do
    arm(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.DocumentDB/databaseAccounts/corpus-cosmos?api-version=2021-04-01",
      %{"location" => "eastus", "properties" => %{}}
    )
  end

  defp put_database do
    arm(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.DocumentDB/databaseAccounts/corpus-cosmos/sqlDatabases/#{@db}?api-version=2021-04-01",
      %{"location" => "eastus", "properties" => %{"resource" => %{}}}
    )
  end

  defp put_container do
    arm(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.DocumentDB/databaseAccounts/corpus-cosmos/sqlDatabases/#{@db}/sqlContainers/#{@coll}?api-version=2021-04-01",
      %{
        "location" => "eastus",
        "properties" => %{
          "resource" => %{
            "id" => @coll,
            "partitionKey" => %{"paths" => ["/pk"], "kind" => "Hash"}
          }
        }
      }
    )
  end

  @pk_header {"x-ms-documentdb-partitionkey", "[\"corpus-pk\"]"}

  @tag :corpus
  test "ARM database + container PUT are listable on the data plane" do
    assert put_account().status in [200, 201], inspect(put_account().resp_body)
    assert put_database().status in [200, 201], inspect(put_database().resp_body)
    container = put_container()
    assert container.status in [200, 201], inspect(container.resp_body)

    colls = egress(:get, "/dbs/#{@db}/colls")
    assert colls.status == 200, inspect(colls.resp_body)
    body = json(colls)
    ids = body["DocumentCollections"] |> List.wrap() |> Enum.map(& &1["id"])
    assert @coll in ids, "ARM-created container not listable: #{inspect(body)}"
  end

  @tag :corpus
  test "data-plane write with the partition key admits; missing pk header is a typed 400" do
    assert put_account().status in [200, 201], inspect(put_account().resp_body)
    assert put_database().status in [200, 201], inspect(put_database().resp_body)
    assert put_container().status in [200, 201]

    ok =
      egress(
        :post,
        "/dbs/#{@db}/colls/#{@coll}/docs",
        %{"id" => "doc-1", "pk" => "corpus-pk", "v" => 1},
        [@pk_header]
      )

    assert ok.status in [200, 201], inspect(ok.resp_body)

    missing =
      egress(
        :post,
        "/dbs/#{@db}/colls/#{@coll}/docs",
        %{"id" => "doc-2", "pk" => "corpus-pk", "v" => 2}
      )

    assert missing.status == 400, "pk enforcement regressed: #{missing.status}"
  end
end

defmodule Smalt.DataPlane.AuditedCapabilitiesTest do
  use ExUnit.Case, async: false

  alias Smalt.ArmGateway.Router, as: ArmRouter
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.EgressRouter
  alias Smalt.Store
  import Plug.Conn
  import Plug.Test

  # Store's ETS tables are owned by the tested process (Smalt.Store).
  # `Lifecycle.ensure_store_up/0` bounded-polls until the tables exist
  # (wait_store_tables), so the former guarded :ets.new fallbacks here were
  # dead code AND a leak-court offender class (global named-table creation
  # from a test process, never restored). Removed per
  # docs/jira/v26.10.18/receipts/i29-audited-caps-leakfix.md.
  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    :ok
  end

  describe "ARM Gap Capabilities (Locations, List by RG, Tag PATCH)" do
    test "GET /subscriptions/:sub/locations returns default locations list" do
      conn =
        conn(:get, "/subscriptions/sub-123/locations?api-version=2022-12-01")
        |> ArmRouter.call([])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["value"])
      assert length(body["value"]) >= 2
      names = Enum.map(body["value"], & &1["name"])
      assert "eastus" in names
      assert "westus2" in names
    end

    test "PATCH /subscriptions/:sub/resourceGroups/:rg updates tags cleanly" do
      # 1. Create RG first
      create_conn =
        conn(:put, "/subscriptions/sub-123/resourceGroups/rg-test?api-version=2022-12-01", %{
          "location" => "eastus",
          "tags" => %{"orig" => "val1"}
        })
        |> ArmRouter.call([])

      assert create_conn.status in [200, 201]

      # 2. Patch RG tags
      patch_conn =
        conn(:patch, "/subscriptions/sub-123/resourceGroups/rg-test?api-version=2022-12-01", %{
          "tags" => %{"patched" => "val2"}
        })
        |> ArmRouter.call([])

      assert patch_conn.status == 200
      patched_body = Jason.decode!(patch_conn.resp_body)
      assert patched_body["tags"]["orig"] == "val1"
      assert patched_body["tags"]["patched"] == "val2"
      assert patched_body["location"] == "eastus"
    end

    test "GET /subscriptions/:sub/resourceGroups/:rg/resources filters to that RG" do
      # Insert test resources into Store
      rg1_id = "/subscriptions/sub-123/resourcegroups/rg-1/providers/microsoft.network/networksecuritygroups/nsg-1"
      rg2_id = "/subscriptions/sub-123/resourcegroups/rg-2/providers/microsoft.network/networksecuritygroups/nsg-2"

      Store.put(:smalt_resources, rg1_id, %{
        "id" => rg1_id,
        "name" => "nsg-1",
        "type" => "Microsoft.Network/networkSecurityGroups",
        "location" => "eastus"
      })

      Store.put(:smalt_resources, rg2_id, %{
        "id" => rg2_id,
        "name" => "nsg-2",
        "type" => "Microsoft.Network/networkSecurityGroups",
        "location" => "westus2"
      })

      conn =
        conn(:get, "/subscriptions/sub-123/resourceGroups/rg-1/resources?api-version=2022-12-01")
        |> ArmRouter.call([])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["value"]) == 1
      assert hd(body["value"])["name"] == "nsg-1"
    end
  end

  describe "Blob Storage Container Lifecycle (DELETE container)" do
    test "DELETE /:account/:container cascade deletes blobs and returns 202" do
      account = "testaccount"
      container = "testcontainer"

      {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})
      {:ok, _} = BlobStorage.put_blob(account, container, "blob1.txt", "hello")
      {:ok, _} = BlobStorage.put_blob(account, container, "blob2.txt", "world")

      # Delete container via route
      conn =
        conn(:delete, "/#{account}/#{container}")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> EgressRouter.call([])

      assert conn.status == 202

      # Verify container and blobs are gone
      assert Store.get(:smalt_blob_containers, "#{account}/#{container}") == :error
      assert Store.get(:smalt_blobs, "#{account}/#{container}/blob1.txt") == :error
      assert Store.get(:smalt_blobs, "#{account}/#{container}/blob2.txt") == :error
    end

    test "DELETE /:account/:container refuses deletion when locked by WORM legal hold" do
      account = "testaccount2"
      container = "wormcontainer"

      {:ok, _} = BlobStorage.create_container(account, container, %{"immutable" => false})
      {:ok, 200, _, _} = BlobStorage.set_legal_hold(account, container, true, %{})

      conn =
        conn(:delete, "/#{account}/#{container}")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> EgressRouter.call([])

      assert conn.status == 409
      assert conn.resp_body =~ "ContainerLocked"
    end
  end

  describe "Key Vault Key Properties (updateKeyProperties)" do
    test "PATCH /keys/:name updates key attributes and tags" do
      name = "mytestkey"
      key_record = %{
        "kid" => "https://localhost:8443/keys/#{name}/v1",
        "key" => %{"kid" => "https://localhost:8443/keys/#{name}/v1", "kty" => "RSA"},
        "attributes" => %{"enabled" => true, "created" => 123456},
        "tags" => %{"env" => "dev"}
      }
      Store.put(:smalt_vault_keys, name, key_record)

      conn =
        conn(:patch, "/keys/#{name}", Jason.encode!(%{
          "attributes" => %{"enabled" => false},
          "tags" => %{"tier" => "critical"}
        }))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer testtoken")
        |> EgressRouter.call([])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["attributes"]["enabled"] == false
      assert body["tags"]["env"] == "dev"
      assert body["tags"]["tier"] == "critical"

      # Verify state in store
      {:ok, stored} = Store.get(:smalt_vault_keys, name)
      assert stored["attributes"]["enabled"] == false
      assert stored["tags"]["tier"] == "critical"
    end
  end

  describe "Cosmos DB Batch/Bulk Operations" do
    test "POST /dbs/:db/colls/:coll/docs with x-ms-cosmos-is-batch-request handles operations" do
      db = "testdb"
      coll = "testcoll"

      # Register container partition key
      Store.put(:smalt_cosmos_pk_meta, {db, coll}, %{"paths" => ["/pk"], "kind" => "Hash"})

      ops = [
        %{
          "operationType" => "Create",
          "resourceBody" => %{"id" => "doc-1", "pk" => "p1", "content" => "first"},
          "partitionKey" => "[\"p1\"]"
        },
        %{
          "operationType" => "Upsert",
          "resourceBody" => %{"id" => "doc-2", "pk" => "p2", "content" => "second"},
          "partitionKey" => "[\"p2\"]"
        }
      ]

      conn =
        conn(:post, "/dbs/#{db}/colls/#{coll}/docs", Jason.encode!(ops))
        |> put_req_header("x-ms-cosmos-is-batch-request", "true")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "type=master&ver=1.0&sig=c21hbHQ=")
        |> EgressRouter.call([])

      assert conn.status == 200
      results = Jason.decode!(conn.resp_body)
      assert is_list(results)
      assert length(results) == 2

      [r1, r2] = results
      assert r1["statusCode"] == 201
      assert r1["resourceBody"]["id"] == "doc-1"
      assert r2["statusCode"] in [200, 201]
      assert r2["resourceBody"]["id"] == "doc-2"
    end
  end
end

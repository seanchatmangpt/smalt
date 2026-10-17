defmodule ArmFr5TfDivergenceClosuresTest do
  @moduledoc """
  FR-5: azurerm 4.54 typed-divergence closures. Wire evidence kept in
  /tmp/tf-plan-probe.EBIxd7 and /tmp/tf-manual-* (2026-10-16). Enrichment
  happens at PUT-persist time, so GET stays verbatim; every assertion reads
  a real router PUT/GET round-trip.
  """

  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Defaults
  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Store.clear()

    Application.put_env(:smalt, :lro_delay_ms, 0)
    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2024-01-01"
      v -> v
    end
  end

  defp req(method, path, body) do
    type =
      case Regex.run(~r{providers/([^/]+/[^/]+)/}, path, capture: :all_but_first) do
        [t] -> t
        _ -> "Microsoft.Resources/resourceGroups"
      end

    path = "#{path}?api-version=#{api_v(type)}"

    conn =
      if body, do: Plug.Test.conn(method, path, body), else: Plug.Test.conn(method, path)

    call(conn)
  end

  defp put_res(path, body), do: req("PUT", path, body)
  defp get_res(path), do: req("GET", path, nil)
  defp post_res(path, body), do: req("POST", path, body)

  defp put_rg do
    put_res("/subscriptions/#{@sub}/resourceGroups/rg-fr5", %{"location" => "smalt-local"})
  end

  describe "persist-time enrichment" do
    test "vault PUT carries properties.vaultUri, name-interpolated" do
      put_rg()

      resp =
        put_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.KeyVault/vaults/kv-fr5",
          %{"location" => "smalt-local"}
        )

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)
      # KD-T5-F1: vaultUri echoes the gateway request authority (loopback-
      # reachable by design — azurerm 4.54 polls it directly); Plug.Test's
      # default conn authority is http://www.example.com.
      assert body["properties"]["vaultUri"] == "http://www.example.com/"
    end

    test "vault GET returns the enriched record verbatim" do
      put_rg()

      put_res(
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.KeyVault/vaults/kv-fr5b",
        %{"location" => "smalt-local"}
      )

      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.KeyVault/vaults/kv-fr5b"
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      # KD-T5-F1: persisted authority echo (GET stays verbatim).
      assert body["properties"]["vaultUri"] == "http://www.example.com/"
    end

    test "storage PUT carries primaryEndpoints consistent with metadata dnsSuffixes" do
      put_rg()

      resp =
        put_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stfr5",
          %{"location" => "smalt-local"}
        )

      assert resp.status in [200, 201, 202]

      # storageAccounts is LRO: the PUT returns the operation object, the
      # enriched record is read back with GET (lro_delay_ms=0 in setup).
      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stfr5"
        )

      assert resp.status == 200
      pe = Jason.decode!(resp.resp_body)["properties"]["primaryEndpoints"]

      assert pe["blob"] == "https://stfr5.blob.smalt.local/"
      assert pe["queue"] == "https://stfr5.queue.smalt.local/"
      assert pe["table"] == "https://stfr5.table.smalt.local/"
      assert pe["file"] == "https://stfr5.file.smalt.local/"
      assert pe["web"] == "https://stfr5.web.smalt.local/"
    end

    test "user-supplied values win over enrichment" do
      put_rg()

      resp =
        put_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.KeyVault/vaults/kv-fr5c",
          %{"location" => "smalt-local", "properties" => %{"vaultUri" => "https://override/"}}
        )

      assert Jason.decode!(resp.resp_body)["properties"]["vaultUri"] == "https://override/"
    end

    test "unknown type is not enriched" do
      props = %{"a" => 1}
      assert Defaults.enrich("Microsoft.Foo/bars", "n", "id", props) == props
    end

    test "enrich table covers exactly the four FR-5 families" do
      assert Map.keys(Defaults.enrich_table()) |> Enum.sort() == [
               "Microsoft.EventHub/namespaces",
               "Microsoft.KeyVault/vaults",
               "Microsoft.ServiceBus/namespaces",
               "Microsoft.Storage/storageAccounts"
             ]
    end
  end

  describe "ServiceBus namespace closures" do
    test "GET namespace carries real-ARM default property set + RootManageSharedAccessKey rule" do
      put_rg()

      put_res(
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.ServiceBus/namespaces/sbns-fr5",
        %{"location" => "smalt-local", "sku" => %{"name" => "Standard", "tier" => "Standard"}}
      )

      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.ServiceBus/namespaces/sbns-fr5"
        )

      assert resp.status == 200
      props = Jason.decode!(resp.resp_body)["properties"]

      assert props["serviceBusEndpoint"] == "https://sbns-fr5.servicebus.smalt.local:443/"
      assert props["status"] == "Active"
      assert props["zoneRedundant"] == false
      assert props["minimumTlsVersion"] == "1.2"
      assert is_binary(props["createdAt"])

      [root] = props["authorizationRules"]
      assert root["name"] == "RootManageSharedAccessKey"
      assert "Manage" in root["rights"]
    end

    test "networkRuleSets/default GET returns the real-ARM default shape" do
      put_rg()

      put_res(
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.ServiceBus/namespaces/sbns-fr5",
        %{"location" => "smalt-local", "sku" => %{"name" => "Standard", "tier" => "Standard"}}
      )

      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.ServiceBus/namespaces/sbns-fr5/networkRuleSets/default"
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert body["name"] == "default"
      assert body["type"] == "Microsoft.ServiceBus/namespaces/networkRuleSets"
      assert body["properties"]["defaultAction"] == "Allow"
      assert body["properties"]["ipRules"] == []
      assert body["properties"]["virtualNetworkRules"] == []
    end

    test "networkRuleSets/default GET on missing parent is 404 ResourceNotFound" do
      put_rg()

      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.ServiceBus/namespaces/nope/networkRuleSets/default"
        )

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "ResourceNotFound"
    end

    test "SB listKeys POST returns typed AccessKeys shape" do
      put_rg()

      put_res(
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.ServiceBus/namespaces/sbns-fr5",
        %{"location" => "smalt-local", "sku" => %{"name" => "Standard", "tier" => "Standard"}}
      )

      resp =
        post_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.ServiceBus/namespaces/sbns-fr5/authorizationRules/RootManageSharedAccessKey/listKeys",
          %{}
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert body["keyName"] == "RootManageSharedAccessKey"
      assert is_binary(body["primaryKey"]) and byte_size(body["primaryKey"]) > 0
      assert String.starts_with?(body["primaryConnectionString"], "Endpoint=")
      assert is_binary(body["secondaryKey"]) and byte_size(body["secondaryKey"]) > 0
      assert String.contains?(body["secondaryConnectionString"], "SharedAccessKey=")
    end
  end

  describe "EventHub namespace closures" do
    defp put_eh_ns(name) do
      put_res(
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.EventHub/namespaces/#{name}",
        %{"location" => "smalt-local", "sku" => %{"name" => "Standard", "tier" => "Standard"}}
      )
    end

    test "GET namespace carries the full deref-safe property set" do
      put_rg()
      put_eh_ns("ehns-fr5")

      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.EventHub/namespaces/ehns-fr5"
        )

      assert resp.status == 200
      props = Jason.decode!(resp.resp_body)["properties"]

      for field <- [
            "isAutoInflateEnabled",
            "maximumThroughputUnits",
            "clusterArmId",
            "createdAt",
            "updatedAt",
            "serviceBusEndpoint",
            "kafkaEnabled",
            "zoneRedundant",
            "status"
          ] do
        assert Map.has_key?(props, field), "EH namespace GET missing #{field}"
      end

      assert props["serviceBusEndpoint"] == "https://ehns-fr5.servicebus.smalt.local:443/"
      assert props["isAutoInflateEnabled"] == false
      assert props["maximumThroughputUnits"] == 0
    end

    test "networkRuleSets/default GET returns the default shape" do
      put_rg()
      put_eh_ns("ehns-fr5")

      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.EventHub/namespaces/ehns-fr5/networkRuleSets/default"
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["name"] == "default"
      assert body["properties"]["defaultAction"] == "Allow"
    end

    test "EH listKeys POST returns typed AccessKeys shape" do
      put_rg()
      put_eh_ns("ehns-fr5")

      resp =
        post_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.EventHub/namespaces/ehns-fr5/authorizationRules/RootManageSharedAccessKey/listKeys",
          %{}
        )

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["keyName"] == "RootManageSharedAccessKey"
      assert String.starts_with?(body["primaryConnectionString"], "Endpoint=")
    end
  end

  describe "storage listKeys" do
    test "POST listKeys returns the real-ARM keys array" do
      put_rg()

      put_res(
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stfr5keys",
        %{"location" => "smalt-local"}
      )

      resp =
        post_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stfr5keys/listKeys",
          %{}
        )

      assert resp.status == 200
      keys = Jason.decode!(resp.resp_body)["keys"]
      assert [%{"keyName" => "key1", "permissions" => "FULL"}, %{"keyName" => "key2"}] = keys
      assert Enum.all?(keys, &is_binary(&1["value"]) and byte_size(&1["value"]) > 0)
    end
  end

  describe "KD-T5 closures (T5 cleanroom azurerm 4.54, /tmp/tf-cleanroom.zq3HmW)" do
    test "vault PUT with an explicit host header echoes that authority as vaultUri" do
      put_rg()

      conn =
        Plug.Test.conn(
          "PUT",
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.KeyVault/vaults/kv-t5f1?api-version=#{api_v("Microsoft.KeyVault/vaults")}",
          %{"location" => "smalt-local"}
        )
        |> Map.put(:host, "localhost:39391")
        |> call()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      # localhost is normalized to 127.0.0.1 (Go clients dial [::1] for
      # localhost; the listeners bind 127.0.0.1 — cleanroom witness).
      assert body["properties"]["vaultUri"] == "http://127.0.0.1:39391/"
    end

    test "storage LRO terminal poll body carries the resource identity (KD-T5-F3)" do
      put_rg()

      path =
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stt5f3"

      resp = put_res(path, %{"location" => "smalt-local"})
      assert resp.status == 202

      {_, op_path} =
        Enum.find(resp.resp_headers, fn {k, _} -> k == "azure-asyncoperation" end)

      op_id = op_path |> String.split("/") |> List.last()

      poll = get_res("/subscriptions/#{@sub}/operations/#{op_id}")
      assert poll.status == 200
      body = Jason.decode!(poll.resp_body)

      assert body["status"] == "Succeeded"
      assert body["id"] == "#{path}"
      assert body["name"] == "stt5f3"
      assert body["type"] == "Microsoft.Storage/storageAccounts"
      assert body["properties"]["provisioningState"] == "Succeeded"
    end

    test "storage singleton service children synthesize real-ARM defaults (KD-T5-F4)" do
      put_rg()

      put_res(
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stt5f4",
        %{"location" => "smalt-local"}
      )

      for service <- ["fileServices", "queueServices", "tableServices"] do
        resp =
          get_res(
            "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stt5f4/#{service}/default"
          )

        assert resp.status == 200,
               "#{service}/default expected 200, got #{resp.status}"

        body = Jason.decode!(resp.resp_body)
        assert body["name"] == "default"
        assert body["type"] == "Microsoft.Storage/storageAccounts/#{service}"
        assert body["id"] ==
                 "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stt5f4/#{service}/default"
        assert is_map(body["properties"])
      end

      # missing parent account -> deny-by-default 404
      resp =
        get_res(
          "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/nostore/#{service_missing_parent()}/default"
        )

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "ResourceNotFound"
    end

    defp service_missing_parent, do: "fileServices"

    test "LRO InProgress poll body keeps the operation shape (no identity enrichment yet)" do
      put_rg()
      Application.put_env(:smalt, :lro_delay_ms, 60_000)

      path =
        "/subscriptions/#{@sub}/resourceGroups/rg-fr5/providers/Microsoft.Storage/storageAccounts/stt5f3b"

      resp = put_res(path, %{"location" => "smalt-local"})
      assert resp.status == 202

      {_, op_path} = Enum.find(resp.resp_headers, fn {k, _} -> k == "azure-asyncoperation" end)
      op_id = op_path |> String.split("/") |> List.last()

      poll = get_res("/subscriptions/#{@sub}/operations/#{op_id}")
      assert poll.status == 202
      body = Jason.decode!(poll.resp_body)
      assert body["status"] == "InProgress"
      refute Map.has_key?(body, "type")
      refute body["id"] == path

      Application.put_env(:smalt, :lro_delay_ms, 0)
    end
  end
end

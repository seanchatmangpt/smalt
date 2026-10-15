defmodule SmaltArmGatewayTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "Sovereign Smalt Subscription",
      "state" => "Enabled"
    })

    Application.put_env(:smalt, :lro_delay_ms, 0)
    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)

  # Idempotent Store boot: under plain `mix test` the app owns Smalt.Store;
  # under `mix test --no-start` we boot it per-test. If a previous test's
  # linked Store is still registered but dying, wait for it to exit first.
  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} ->
              ensure_store()
          after
            500 ->
              :ok
          end
        else
          :ok
        end
    end
  end

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2024-01-01"
      v -> v
    end
  end

  # ---------------------------------------------------------------------------
  # STS / token
  # ---------------------------------------------------------------------------
  test "STS OAuth2 Token Issuance provides valid JWT with v2 claims" do
    conn =
      conn(:post, "/oauth2/v2.0/token", %{
        "grant_type" => "client_credentials",
        "client_id" => "mock_id",
        "client_secret" => "mock_secret"
      })
      |> call()

    assert conn.status == 200

    assert %{"access_token" => token, "token_type" => "Bearer"} =
             body = Jason.decode!(conn.resp_body)

    assert body["expires_in"] == 3600
    assert is_binary(token)

    {:ok, claims} = Joken.peek_claims(token)
    assert claims["oid"] == "00000000-0000-0000-0000-000000000001"
    assert claims["sub"] == claims["oid"]
    assert claims["tid"] == "00000000-0000-0000-0000-000000000000"
    assert claims["azp"] == "00000000-0000-0000-0000-000000000000"
    assert claims["iss"] == "http://www.example.com/00000000-0000-0000-0000-000000000000/v2.0"
    assert "Contributor" in claims["roles"]
  end

  test "Tenant-scoped token route carries tenant tid and v2 issuer" do
    conn =
      conn(:post, "/72f988bf-86f1-41af-91ab-2d7cd011db47/oauth2/v2.0/token", %{
        "grant_type" => "client_credentials",
        "client_id" => "mock_id",
        "client_secret" => "mock_secret"
      })
      |> call()

    assert conn.status == 200

    {:ok, claims} =
      conn.resp_body |> Jason.decode!() |> Map.fetch!("access_token") |> Joken.peek_claims()

    assert claims["tid"] == "72f988bf-86f1-41af-91ab-2d7cd011db47"
    assert claims["iss"] == "http://www.example.com/72f988bf-86f1-41af-91ab-2d7cd011db47/v2.0"
  end

  # ---------------------------------------------------------------------------
  # Bootstrap / discovery endpoints
  # ---------------------------------------------------------------------------
  test "GET /metadata/endpoints returns azurerm bootstrap envelope" do
    conn = conn(:get, "/metadata/endpoints") |> call()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    # resourceManager host is env-driven (terraform lane points it at the live
    # listener); assert shape, not host.
    assert is_binary(body["resourceManager"]) and String.ends_with?(body["resourceManager"], "/")
    assert is_binary(body["graphEndpoint"])
    assert body["authentication"]["audiences"] == ["https://management.azure.com"]
  end

  test "GET /common/discovery/instance returns tenant discovery envelope" do
    conn = conn(:get, "/common/discovery/instance") |> call()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["tenantId"]
    assert body["tenant_discovery_endpoint"] =~ "openid-configuration"
    assert body["issuer"]
  end

  test "openid-configuration endpoints (root and tenant-scoped)" do
    root = conn(:get, "/.well-known/openid-configuration") |> call()
    assert root.status == 200

    assert %{"issuer" => issuer, "token_endpoint" => te, "jwks_uri" => _} =
             Jason.decode!(root.resp_body)

    assert issuer =~ "/v2.0"
    assert te =~ "/v2.0/token"

    tenant =
      conn(:get, "/72f988bf-86f1-41af-91ab-2d7cd011db47/v2.0/.well-known/openid-configuration")
      |> call()

    assert tenant.status == 200
    body = Jason.decode!(tenant.resp_body)
    # request-derived authority (lane 94): issuer mirrors the requesting
    # host (Plug.Test default "www.example.com"), not a hardcoded literal.
    assert body["issuer"] ==
             "http://www.example.com/72f988bf-86f1-41af-91ab-2d7cd011db47/v2.0"

    assert body["id_token_signing_alg_values_supported"] == ["HS256"]
  end

  test "GET /tenant and /tenants list the Sovereign tenant" do
    for path <- ["/tenant", "/tenants"] do
      conn = conn(:get, path) |> call()
      assert conn.status == 200
      assert %{"value" => [tenant]} = Jason.decode!(conn.resp_body)
      assert tenant["tenantId"] == "00000000-0000-0000-0000-000000000000"
      assert tenant["displayName"] == "Sovereign"
    end
  end

  # ---------------------------------------------------------------------------
  # Resource Group lifecycle + case normalization + LIST
  # ---------------------------------------------------------------------------
  test "Resource Group Lifecycle (PUT, GET, DELETE) via lowercase segment" do
    path = "/subscriptions/#{@sub}/resourcegroups/test-rg"

    put_conn = conn(:put, path, %{"location" => "eastus", "tags" => %{"env" => "dev"}}) |> call()
    assert put_conn.status == 201
    body = Jason.decode!(put_conn.resp_body)
    assert body["name"] == "test-rg"
    assert body["properties"]["provisioningState"] == "Succeeded"

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body)["name"] == "test-rg"

    # PUT again -> update (200)
    upd_conn = conn(:put, path, %{"location" => "westus"}) |> call()
    assert upd_conn.status == 200

    # ARM RG delete is LRO: 202 + Location + Retry-After; terminal GET 404.
    del_conn = conn(:delete, path) |> call()
    assert del_conn.status == 202
    assert [loc] = get_resp_header(del_conn, "location")
    assert String.starts_with?(loc, "http://www.example.com/subscriptions/#{@sub}/operations/")
    assert get_resp_header(del_conn, "retry-after") == ["1"]

    assert conn(:get, path) |> call() |> Map.get(:status) == 404
  end

  test "Resource Group routes accept camelCase resourceGroups segment" do
    path = "/subscriptions/#{@sub}/resourceGroups/Test-RG-Camel"

    assert conn(:put, path, %{"location" => "eastus"}) |> call() |> Map.get(:status) == 201

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body)["name"] == "Test-RG-Camel"
  end

  test "LIST resource groups returns prefix-scanned collection (both casings)" do
    for name <- ["rg-a", "rg-b"] do
      conn(:put, "/subscriptions/#{@sub}/resourcegroups/#{name}", %{"location" => "eastus"})
      |> call()
    end

    for seg <- ["resourcegroups", "resourceGroups"] do
      conn = conn(:get, "/subscriptions/#{@sub}/#{seg}") |> call()
      assert conn.status == 200
      assert %{"value" => rgs} = Jason.decode!(conn.resp_body)
      assert length(rgs) == 2
      assert Enum.map(rgs, & &1["name"]) |> Enum.sort() == ["rg-a", "rg-b"]
    end
  end

  # ---------------------------------------------------------------------------
  # api-version seam
  # ---------------------------------------------------------------------------
  test "missing api-version returns 400 MissingApiVersionParameter" do
    path =
      "/subscriptions/#{@sub}/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet-01"

    conn =
      conn(:put, path, %{
        "location" => "eastus",
        "properties" => %{"addressSpace" => %{"addressPrefixes" => ["10.0.0.0/16"]}}
      })
      |> call()

    assert conn.status == 400
    assert %{"error" => %{"code" => "MissingApiVersionParameter"}} = Jason.decode!(conn.resp_body)
  end

  test "invalid api-version returns 400 InvalidApiVersionParameter" do
    path =
      "/subscriptions/#{@sub}/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet-01?api-version=1999-01-01"

    conn =
      conn(:put, path, %{
        "location" => "eastus",
        "properties" => %{"addressSpace" => %{"addressPrefixes" => ["10.0.0.0/16"]}}
      })
      |> call()

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidApiVersionParameter"
    assert body["error"]["message"] =~ "1999-01-01"
  end

  test "Registry-driven api-version resolution: latest accepted, bogus refused" do
    type = "Microsoft.KeyVault/vaults"
    latest = Smalt.Registry.latest_version(type)
    assert is_binary(latest)
    refute Smalt.Registry.admitted?("Microsoft.Bogus/widgets")
  end

  # ---------------------------------------------------------------------------
  # Generic provider routes + GraphLaw
  # ---------------------------------------------------------------------------
  test "Virtual Network Resource Management" do
    vnet_type = "Microsoft.Network/virtualNetworks"

    path =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/vnet-01?api-version=#{api_v(vnet_type)}"

    payload = %{
      "location" => "eastus",
      "properties" => %{"addressPrefixes" => ["10.0.0.0/16"]}
    }

    put_conn = conn(:put, path, payload) |> call()
    assert put_conn.status == 201

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body)["name"] == "vnet-01"

    # update -> 200
    upd_conn = conn(:put, path, payload) |> call()
    assert upd_conn.status == 200

    # LIST per-RG provider type
    list_conn =
      conn(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks?api-version=#{api_v(vnet_type)}"
      )
      |> call()

    assert list_conn.status == 200
    assert %{"value" => items} = Jason.decode!(list_conn.resp_body)
    assert length(items) == 1

    # DELETE -> 200 empty body
    del_conn = conn(:delete, path) |> call()
    assert del_conn.status == 200
    assert del_conn.resp_body == ""
  end

  test "Ash GraphLaw Refusal on Invalid VM SKU returns HTTP 400 (pinned)" do
    path =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/cvm-01?api-version=#{api_v("Microsoft.Compute/virtualMachines")}"

    invalid_payload = %{
      "location" => "eastus",
      "properties" => %{"hardwareProfile" => %{"vmSize" => "Invalid_NonExistent_SKU_x86"}}
    }

    conn = conn(:put, path, invalid_payload) |> call()

    # PINNED: ARM validation failures are 400 (never 422)
    assert conn.status == 400
    response = Jason.decode!(conn.resp_body)
    assert response["error"]["code"] == "InvalidResourceShape"
    assert response["error"]["target"] == "AshGraphLaw.Enforcement"
  end

  test "Ash GraphLaw Admits Valid Confidential SKU" do
    path =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Compute/virtualMachines/cvm-02?api-version=#{api_v("Microsoft.Compute/virtualMachines")}"

    valid_payload = %{
      "location" => "eastus",
      "properties" => %{"vmSize" => "DC16ads_v5"}
    }

    conn = conn(:put, path, valid_payload) |> call()

    # virtualMachines is LRO-async: 202 + polling headers
    assert conn.status == 202
    assert [op_url] = get_resp_header(conn, "azure-asyncoperation")
    assert get_resp_header(conn, "retry-after") == ["1"]

    op_path = op_url |> URI.parse() |> Map.fetch!(:path)
    poll = conn(:get, op_path) |> call()
    assert poll.status in [200, 202]
    assert %{"status" => status} = Jason.decode!(poll.resp_body)
    assert status in ["InProgress", "Succeeded"]
  end

  test "unadmitted resource type is refused with GraphLaw envelope" do
    path =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Bogus/widgets/w1?api-version=2024-01-01"

    conn = conn(:put, path, %{"location" => "eastus"}) |> call()

    assert conn.status == 400
    assert %{"error" => %{"code" => "InvalidResourceShape"}} = Jason.decode!(conn.resp_body)
  end

  # ---------------------------------------------------------------------------
  # Child resources
  # ---------------------------------------------------------------------------
  test "subnets under virtualNetworks: PUT/GET/LIST/DELETE" do
    subnet_type = "Microsoft.Network/subnets"

    base =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/vnet-01/subnets"

    path = "#{base}/snet-01?api-version=#{api_v(subnet_type)}"

    put_conn = conn(:put, path, %{"properties" => %{"addressPrefix" => "10.0.1.0/24"}}) |> call()
    assert put_conn.status == 201
    body = Jason.decode!(put_conn.resp_body)
    assert body["type"] == subnet_type

    assert conn(:get, path) |> call() |> Map.get(:status) == 200

    list_conn = conn(:get, "#{base}?api-version=#{api_v(subnet_type)}") |> call()
    assert %{"value" => items} = Jason.decode!(list_conn.resp_body)
    assert length(items) == 1

    assert conn(:delete, path) |> call() |> Map.get(:status) == 200
    assert conn(:get, path) |> call() |> Map.get(:status) == 404
  end

  test "vault keys child route lifecycle" do
    key_type = "Microsoft.KeyVault/vaults/keys"

    base =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/kv-01/keys"

    path = "#{base}/key-01?api-version=#{api_v(key_type)}"

    put_conn =
      conn(:put, path, %{"location" => "eastus", "properties" => %{"kty" => "RSA-HSM"}}) |> call()

    assert put_conn.status == 201
    assert Jason.decode!(put_conn.resp_body)["type"] == key_type

    assert conn(:get, path) |> call() |> Map.get(:status) == 200
    assert conn(:delete, path) |> call() |> Map.get(:status) == 200
  end

  test "blob containers and immutabilityPolicies child routes" do
    container_type = "Microsoft.Storage/storageAccounts/blobServices/containers"
    policy_type = "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"
    bservices_type = "Microsoft.Storage/storageAccounts/blobServices"

    containers_base =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/st-01/blobServices/default/containers"

    put_conn =
      conn(:put, "#{containers_base}/cont-01?api-version=#{api_v(container_type)}", %{
        "location" => "eastus",
        "properties" => %{}
      })
      |> call()

    assert put_conn.status == 201

    assert Jason.decode!(put_conn.resp_body)["type"] ==
             "Microsoft.Storage/storageAccounts/blobServices/containers"

    list_conn = conn(:get, "#{containers_base}?api-version=#{api_v(container_type)}") |> call()
    assert %{"value" => items} = Jason.decode!(list_conn.resp_body)
    assert length(items) == 1

    # immutabilityPolicy under the container
    policy_path =
      "#{containers_base}/cont-01/immutabilityPolicies/ip-01?api-version=#{api_v(policy_type)}"

    ip_conn =
      conn(:put, policy_path, %{
        "location" => "eastus",
        "properties" => %{"immutabilityPeriodSinceCreationInDays" => 30}
      })
      |> call()

    assert ip_conn.status == 201

    assert Jason.decode!(ip_conn.resp_body)["type"] ==
             "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"

    assert conn(:get, policy_path) |> call() |> Map.get(:status) == 200

    # singleton blobServices/default (PUT then GET)
    bsvc_base =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/st-01/blobServices/default?api-version=#{api_v(bservices_type)}"

    assert conn(:put, bsvc_base, %{"location" => "eastus"}) |> call() |> Map.get(:status) == 201

    bsvc = conn(:get, bsvc_base) |> call()
    assert bsvc.status == 200

    # azapi setLegalHold action on the container (with If-Match)
    hold_conn =
      conn(:post, "#{containers_base}/cont-01/setLegalHold?api-version=2024-01-01", %{})
      |> put_req_header("if-match", "W/\"abc\"")
      |> call()

    assert hold_conn.status == 200
    hold_body = Jason.decode!(hold_conn.resp_body)
    assert hold_body["properties"]["legalHoldState"] == "locked"
    assert hold_body["properties"]["ifMatch"] == ["W/\"abc\""]

    # azapi lock action at any depth
    # The lock action requires an If-Match precondition (lib contract,
    # router.ex check_lock_precondition/2): missing header -> 412.
    lock_conn =
      conn(:post, "#{containers_base}/cont-01/lock?api-version=2024-01-01", %{})
      |> put_req_header("if-match", "\"0x8DA1A2B3C4D5E6F\"")
      |> call()

    assert lock_conn.status == 200
    assert Jason.decode!(lock_conn.resp_body)["type"] == "Microsoft.Authorization/locks"

    assert conn(:delete, "#{containers_base}/cont-01?api-version=#{api_v(container_type)}")
           |> call()
           |> Map.get(:status) == 200
  end

  # ---------------------------------------------------------------------------
  # Governance types via generic route (registry-gated)
  # ---------------------------------------------------------------------------
  test "roleAssignments PUT via generic route (registry-gated)" do
    ra_type = "Microsoft.Authorization/roleAssignments"

    path =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Authorization/roleAssignments/11111111-2222-3333-4444-555555555555?api-version=#{api_v(ra_type)}"

    conn =
      conn(:put, path, %{
        "location" => "eastus",
        "properties" => %{"roleDefinitionId" => "r", "principalId" => "p"}
      })
      |> call()

    assert conn.status == 201
    assert Jason.decode!(conn.resp_body)["type"] == ra_type
  end

  test "diagnosticSettings and DevTestLab schedules ride the generic route" do
    ds =
      conn(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Insights/diagnosticSettings/ds-01?api-version=#{api_v("Microsoft.Insights/diagnosticSettings")}",
        %{"location" => "eastus", "properties" => %{}}
      )
      |> call()

    assert ds.status == 201

    sched =
      conn(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.DevTestLab/schedules/sch-01?api-version=#{api_v("Microsoft.DevTestLab/schedules")}",
        %{"location" => "eastus", "properties" => %{}}
      )
      |> call()

    assert sched.status == 201
  end

  # ---------------------------------------------------------------------------
  # LRO storage account flow
  # ---------------------------------------------------------------------------
  test "storageAccounts PUT starts LRO and poll flips to Succeeded" do
    Application.put_env(:smalt, :lro_delay_ms, 50)

    path =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/st-lro?api-version=#{api_v("Microsoft.Storage/storageAccounts")}"

    put_conn =
      conn(:put, path, %{
        "location" => "eastus",
        "properties" => %{"skuName" => "Standard_LRS"}
      })
      |> call()

    assert put_conn.status == 202
    assert [%{"status" => "InProgress", "name" => op_id}] = [Jason.decode!(put_conn.resp_body)]
    assert get_resp_header(put_conn, "azure-asyncoperation") != []
    assert get_resp_header(put_conn, "location") != []
    assert get_resp_header(put_conn, "retry-after") == ["1"]

    # poll until Succeeded
    op_path =
      get_resp_header(put_conn, "azure-asyncoperation")
      |> hd()
      |> URI.parse()
      |> Map.fetch!(:path)

    final =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        poll = conn(:get, op_path) |> call()

        case Jason.decode!(poll.resp_body)["status"] do
          "Succeeded" -> {:halt, poll}
          _ -> {:cont, Process.sleep(25) && poll}
        end
      end)

    assert final
    assert %{"status" => "Succeeded", "id" => op_id_url} = Jason.decode!(final.resp_body)
    assert op_id_url == "/subscriptions/#{@sub}/operations/#{op_id}"

    # operation row is Store-backed
    assert match?({:ok, _}, Store.get(:smalt_operations, op_id))
  end

  # ---------------------------------------------------------------------------
  # Subscription-level lists
  # ---------------------------------------------------------------------------
  test "GET /subscriptions/:sub/providers returns deduped resourceTypes inventory" do
    conn(:put, "/subscriptions/#{@sub}/resourcegroups/inv-rg", %{"location" => "eastus"})
    |> call()

    conn(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/inv-rg/providers/Microsoft.Network/virtualNetworks/v1?api-version=#{api_v("Microsoft.Network/virtualNetworks")}",
      %{"location" => "eastus", "properties" => %{"addressPrefixes" => ["10.1.0.0/16"]}}
    )
    |> call()

    conn = conn(:get, "/subscriptions/#{@sub}/providers") |> call()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    types = body["resourceTypes"]
    assert is_list(types)

    assert Enum.any?(
             types,
             &(&1["resourceType"] == "virtualNetworks" and &1["namespace"] == "Microsoft.Network")
           )
  end

  # ---------------------------------------------------------------------------
  # Catch-all 404 envelope
  # ---------------------------------------------------------------------------
  test "catch-all 404 uses the proper ARM error envelope" do
    conn = conn(:get, "/no/such/route") |> call()
    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "RouteNotFound"
    assert is_binary(body["error"]["message"])
  end

  # ---------------------------------------------------------------------------
  # Throttle window lease: the previous fixed-window ETS key is pruned on every
  # counted request, so the rate table stays bounded to the current window
  # (previously it grew one key per second, unbounded, while a limit was set).
  # ---------------------------------------------------------------------------
  test "arm throttle prunes the previous fixed-window key" do
    ensure_store()

    Application.put_env(:smalt, :arm_rate_limit, 3)

    try do
      now = div(System.system_time(:millisecond), 1000)
      prev = {:smalt_arm_rate, now - 1}

      # Seed the prior window as if the last second's traffic had happened.
      :ets.insert(Smalt.ArmGateway.Router.rate_table_for_test(), {prev, 99})

      conn =
        conn(:get, "/subscriptions/#{@sub}") |> call()

      assert conn.status == 200

      # The stale window key is gone; only the current window's key remains.
      refute :ets.member(Smalt.ArmGateway.Router.rate_table_for_test(), prev)
      assert :ets.member(Smalt.ArmGateway.Router.rate_table_for_test(), {:smalt_arm_rate, now})

      # And the window counter still counts toward the limit (no regression to
      # the fixed-window 429 semantics fenced in c1_arm row 12).
      for _ <- 1..3, do: conn(:get, "/subscriptions/#{@sub}") |> call() |> Map.get(:status)
      throttled = conn(:get, "/subscriptions/#{@sub}") |> call()
      assert throttled.status == 429
      assert get_resp_header(throttled, "retry-after") == ["1"]
    after
      Application.put_env(:smalt, :arm_rate_limit, nil)
      :ets.delete_all_objects(:smalt_arm_rate)
    end
  end
end

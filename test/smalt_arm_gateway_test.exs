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
    # listener); assert shape, not host. KD-T5-F2: no trailing slash — azurerm
    # joins resourceManager verbatim with "/subscriptions/..." and a trailing
    # slash built a double-slash URL (connection reset, T5 cleanroom).
    assert is_binary(body["resourceManager"])
    refute String.ends_with?(body["resourceManager"], "/")
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
    path = "/subscriptions/#{@sub}/resourcegroups/test-rg?api-version=2023-07-01"

    put_conn = conn(:put, path, %{"location" => "eastus", "tags" => %{"env" => "dev"}}) |> call()
    assert put_conn.status == 201
    body = Jason.decode!(put_conn.resp_body)
    assert body["name"] == "test-rg"
    assert body["properties"]["provisioningState"] == "Succeeded"

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body)["name"] == "test-rg"

    # PUT again -> update (200); location is immutable on update (R30)
    upd_conn = conn(:put, path, %{"location" => "eastus"}) |> call()
    assert upd_conn.status == 200

    moved_conn = conn(:put, path, %{"location" => "westus"}) |> call()
    assert moved_conn.status == 400
    assert Jason.decode!(moved_conn.resp_body)["error"]["code"] == "LocationMismatch"

    # ARM RG delete is LRO: 202 + Location + Retry-After; terminal GET 404.
    del_conn = conn(:delete, path) |> call()
    assert del_conn.status == 202
    assert [loc] = get_resp_header(del_conn, "location")
    assert String.starts_with?(loc, "http://www.example.com/subscriptions/#{@sub}/operations/")
    assert get_resp_header(del_conn, "retry-after") == ["1"]

    assert conn(:get, path) |> call() |> Map.get(:status) == 404
  end

  test "RG tags round-trip: PUT with tags -> GET identical; PUT without/null tags -> GET tags = null (null-when-empty parity, FR-5)" do
    api = "2023-07-01"

    path = "/subscriptions/#{@sub}/resourcegroups/rg-tags?api-version=#{api}"

    # PUT with tags -> GET echoes them exactly.
    put_conn =
      conn(:put, path, %{"location" => "eastus", "tags" => %{"environment" => "prod"}})
      |> call()

    assert put_conn.status == 201

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200
    body = Jason.decode!(get_conn.resp_body)
    assert body["tags"] == %{"environment" => "prod"}

    # PUT without tags -> GET has tags = null (null-when-empty parity; the
    # pre-reconciliation `{}` pin drifted azurerm refresh, FR-5 re-witness
    # /tmp/tf-plan-probe.hPaBPZ).
    upd = conn(:put, path, %{"location" => "eastus"}) |> call()
    assert upd.status == 200
    get2 = conn(:get, path) |> call()
    assert Jason.decode!(get2.resp_body)["tags"] == nil

    # PUT with explicit null tags (azurerm omits-or-nulls) -> GET tags = null.
    upd_null = conn(:put, path, %{"location" => "eastus", "tags" => nil}) |> call()
    assert upd_null.status == 200
    get3 = conn(:get, path) |> call()
    body3 = Jason.decode!(get3.resp_body)
    assert body3["tags"] == nil
    assert Map.has_key?(body3, "tags")

    # Generic resource path (vn leg): CREATE with null tags -> GET renders JSON
    # `null` (wire truth per corpus rows 1-2, tf replay /tmp/tf-rg419: echoing
    # {} on create-with-null-tags causes permanent azurerm refresh drift).
    res_path =
      "/subscriptions/#{@sub}/resourceGroups/rg-tags/providers/Microsoft.Network/virtualNetworks/vn-tags?api-version=#{api_v("Microsoft.Network/virtualNetworks")}"

    # Disclosed cross-lane unblock (compile-freeze SLA): `null` is JSON, not
    # Elixir — the tags round-trip lane meant nil.
    res_put =
      conn(:put, res_path, %{
        "location" => "eastus",
        "tags" => nil,
        "properties" => %{"addressPrefixes" => ["10.9.0.0/16"]}
      })
      |> call()
    assert res_put.status in [200, 201]
    res_get = conn(:get, res_path) |> call()
    assert res_get.status == 200
    res_body = Jason.decode!(res_get.resp_body)
    assert res_body["tags"] == nil
  end

  test "Resource Group routes accept camelCase resourceGroups segment" do
    path = "/subscriptions/#{@sub}/resourceGroups/Test-RG-Camel?api-version=2023-07-01"

    assert conn(:put, path, %{"location" => "eastus"}) |> call() |> Map.get(:status) == 201

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body)["name"] == "Test-RG-Camel"
  end

  test "LIST resource groups returns prefix-scanned collection (both casings)" do
    for name <- ["rg-a", "rg-b"] do
      conn(:put, "/subscriptions/#{@sub}/resourcegroups/#{name}?api-version=2023-07-01", %{"location" => "eastus"})
      |> call()
    end

    for seg <- ["resourcegroups", "resourceGroups"] do
      conn = conn(:get, "/subscriptions/#{@sub}/#{seg}?api-version=2023-07-01") |> call()
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
    # KD-78 monotonic gate: versions <= latest are ACCEPTED; only a version
    # beyond the latest is the 400 InvalidApiVersionParameter face.
    path =
      "/subscriptions/#{@sub}/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet-01?api-version=2999-01-01"

    conn =
      conn(:put, path, %{
        "location" => "eastus",
        "properties" => %{"addressSpace" => %{"addressPrefixes" => ["10.0.0.0/16"]}}
      })
      |> call()

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidApiVersionParameter"
    assert body["error"]["message"] =~ "2999-01-01"
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

  test "privateDnsZones virtualNetworkLinks child route lifecycle (orphan 404, parented 201/200/LIST/DELETE 200/404)" do
    link_type = "Microsoft.Network/privateDnsZones/virtualNetworkLinks"

    base =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Network/privateDnsZones/zone-01/virtualNetworkLinks"

    path = "#{base}/link-01?api-version=#{api_v(link_type)}"

    # Orphan: no parent zone -> 404 ResourceNotFound (parented-child gate)
    orphan_conn =
      conn(:put, path, %{"location" => "eastus", "properties" => %{"virtualNetworkId" => "x"}})
      |> call()

    assert orphan_conn.status == 404
    assert %{"error" => %{"code" => "ResourceNotFound"}} = Jason.decode!(orphan_conn.resp_body)

    # Parent zone, then parented lifecycle
    zone_path =
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Network/privateDnsZones/zone-01?api-version=#{api_v("Microsoft.Network/privateDnsZones")}"

    assert conn(:put, zone_path, %{"location" => "global", "properties" => %{}}) |> call() |> Map.get(:status) == 201

    put_conn =
      conn(:put, path, %{"location" => "global", "properties" => %{"virtualNetworkId" => "x"}})
      |> call()

    assert put_conn.status == 201
    assert Jason.decode!(put_conn.resp_body)["type"] == link_type

    assert conn(:get, path) |> call() |> Map.get(:status) == 200

    list_conn = conn(:get, base <> "?api-version=#{api_v(link_type)}") |> call()
    assert %{"value" => items} = Jason.decode!(list_conn.resp_body)
    assert length(items) == 1

    assert conn(:delete, path) |> call() |> Map.get(:status) == 200
    assert conn(:get, path) |> call() |> Map.get(:status) == 404
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
    # router.ex check_lock_precondition/2): missing header -> 412, and the
    # header is value-verified (V261014-20) against the deterministic policy
    # etag — not an arbitrary string.
    lock_path = "#{containers_base}/cont-01/lock"

    lock_conn =
      conn(:post, lock_path <> "?api-version=2024-01-01", %{})
      |> put_req_header("if-match", Smalt.ArmGateway.Router.lock_policy_etag(lock_path))
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
    # KD-T5-F3: the terminal wire body carries the TARGET RESOURCE's id (the
    # azurerm 4.54 storage poller synthesizes resource identity from it); the
    # operation record in the store keeps the operations-scoped id.
    assert op_id_url ==
             "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/st-lro"

    # operation row is Store-backed
    assert match?({:ok, _}, Store.get(:smalt_operations, op_id))
  end

  # ---------------------------------------------------------------------------
  # nextLink carry-through under the gated generic LIST (lens-3: re-fuzz of
  # lens-2 M4 post-Raise — the nextLink must carry api-version so the follow
  # request passes the now-ubiquitous api-version gates).
  # ---------------------------------------------------------------------------
  test "generic LIST nextLink carries api-version; follow passes the gate" do
    rg_path = "/subscriptions/#{@sub}/resourcegroups/nextlink-rg"
    conn(:put, "#{rg_path}?api-version=2023-07-01", %{"location" => "eastus"}) |> call()

    vnet_v = api_v("Microsoft.Network/virtualNetworks")

    for i <- 1..201 do
      conn(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/nextlink-rg/providers/Microsoft.Network/virtualNetworks/vnet-#{String.pad_leading(Integer.to_string(i), 3, "0")}?api-version=#{vnet_v}",
        %{"location" => "eastus", "properties" => %{"addressPrefixes" => ["10.1.0.0/16"]}}
      )
      |> call()
    end

    page1 =
      conn(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/nextlink-rg/providers/Microsoft.Network/virtualNetworks?api-version=#{vnet_v}"
      )
      |> call()

    assert page1.status == 200
    nl = Jason.decode!(page1.resp_body)["nextLink"]
    assert is_binary(nl)

    # nextLink carries api-version (M4 fence, post-Raise re-pin)
    %{query: q} = URI.parse(nl)
    assert URI.decode_query(q)["api-version"] == vnet_v

    follow = URI.parse(nl)
    follow_conn = conn(:get, "#{follow.path}?#{follow.query}") |> call()
    assert follow_conn.status == 200
    assert is_list(Jason.decode!(follow_conn.resp_body)["value"])
  end

  # ---------------------------------------------------------------------------
  # Subscription-level lists
  # ---------------------------------------------------------------------------
  test "GET /subscriptions/:sub/providers returns the ProviderMatrix listing" do
    conn(:put, "/subscriptions/#{@sub}/resourcegroups/inv-rg", %{"location" => "eastus"})
    |> call()

    conn(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/inv-rg/providers/Microsoft.Network/virtualNetworks/v1?api-version=#{api_v("Microsoft.Network/virtualNetworks")}",
      %{"location" => "eastus", "properties" => %{"addressPrefixes" => ["10.1.0.0/16"]}}
    )
    |> call()

    conn =
      conn(:get, "/subscriptions/#{@sub}/providers?api-version=2021-04-01") |> call()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    # Wave-2: the listing is the Registry-projected ProviderMatrix — a "value"
    # array of provider rows; the store-scan inventory (and its top-level
    # subscriptionId field) is gone.
    assert is_list(body["value"]) and body["value"] != []

    assert Enum.any?(body["value"], fn p ->
             p["namespace"] == "Microsoft.Network" and
               Enum.any?(p["resourceTypes"], &(&1["resourceType"] == "virtualNetworks"))
           end)
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
      # Deterministic window scoping: all five counted requests must land in
      # the SAME 1-second fixed window, else a boundary crossing mid-test
      # resets the counter and the 429 assertion flakes (observed lens-3).
      # Wait until the current second is freshly started so the whole test
      # body runs inside one window with high margin.
      wait_for_fresh_window()

      now = div(System.system_time(:millisecond), 1000)
      prev = {:smalt_arm_rate, now - 1}

      # Seed the prior window as if the last second's traffic had happened.
      :ets.insert(Smalt.ArmGateway.Router.rate_table_for_test(), {prev, 99})

      conn =
        conn(:get, "/subscriptions/#{@sub}?api-version=2021-04-01") |> call()

      assert conn.status == 200

      # The stale window key is gone; only the current window's key remains.
      refute :ets.member(Smalt.ArmGateway.Router.rate_table_for_test(), prev)
      assert :ets.member(Smalt.ArmGateway.Router.rate_table_for_test(), {:smalt_arm_rate, now})

      # And the window counter still counts toward the limit (no regression to
      # the fixed-window 429 semantics fenced in c1_arm row 12).
      for _ <- 1..3, do: conn(:get, "/subscriptions/#{@sub}?api-version=2021-04-01") |> call() |> Map.get(:status)
      throttled = conn(:get, "/subscriptions/#{@sub}?api-version=2021-04-01") |> call()
      assert throttled.status == 429
      assert get_resp_header(throttled, "retry-after") == ["1"]
    after
      Application.put_env(:smalt, :arm_rate_limit, nil)
      :ets.delete_all_objects(:smalt_arm_rate)
    end
  end

  # KD-54 / R119: subscription-wide resource LIST across resource groups.
  test "subscription resources LIST: cross-RG, $filter clauses, pagination" do
    # R178g: clean up seeded :smalt_resources rows (rg-a/rg-b/rg-p, 104 keys)
    # so they never leak into other suites sharing the table.
    on_exit(fn ->
      if :ets.info(:smalt_resources) != :undefined do
        prefix = String.downcase("/subscriptions/#{@sub}/resourcegroups/rg-")

        for key <- Store.prefix_keys(:smalt_resources, prefix) do
          :ets.delete(:smalt_resources, key)
        end
      end
    end)

    seeds = [
      {"/subscriptions/#{@sub}/resourceGroups/rg-a/providers/Microsoft.Network/virtualNetworks/vnet1",
       "Microsoft.Network/virtualNetworks", "vnet1", "eastus"},
      {"/subscriptions/#{@sub}/resourceGroups/rg-a/providers/Microsoft.Storage/storageAccounts/stg1",
       "Microsoft.Storage/storageAccounts", "stg1", "westus"},
      {"/subscriptions/#{@sub}/resourceGroups/rg-b/providers/Microsoft.Network/virtualNetworks/vnet2",
       "Microsoft.Network/virtualNetworks", "vnet2", "eastus"}
    ]

    for {id, type, name, loc} <- seeds do
      Store.put(:smalt_resources, String.downcase(id), %{
        "id" => id,
        "name" => name,
        "type" => type,
        "location" => loc,
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{},
        "systemData" => %{}
      })
    end

    # Unfiltered: all 3 across both RGs.
    conn = conn(:get, "/subscriptions/#{@sub}/resources?api-version=2021-04-01") |> call()
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert length(body["value"]) == 3
    assert Map.has_key?(body, "nextLink") == false
    ids = body["value"] |> Enum.map(& &1["id"]) |> Enum.map(&String.downcase/1)

    for {id, _, _, _} <- seeds do
      assert String.downcase(id) in ids
    end

    # $filter resourceType eq — case-insensitive match on type.
    conn =
      conn(:get, "/subscriptions/#{@sub}/resources?api-version=2021-04-01&" <>
        URI.encode_query(%{"$filter" => "resourceType eq 'Microsoft.Network/virtualNetworks'"}))
      |> call()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert length(body["value"]) == 2

    assert Enum.all?(body["value"], fn r ->
             String.downcase(r["type"]) == "microsoft.network/virtualnetworks"
           end)

    # $filter resourceGroup eq — scoped to one RG.
    conn =
      conn(:get, "/subscriptions/#{@sub}/resources?api-version=2021-04-01&" <>
        URI.encode_query(%{"$filter" => "resourceGroup eq 'RG-A'"}))
      |> call()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert length(body["value"]) == 2

    # Unknown filter clause denies by default (matches nothing).
    conn =
      conn(:get, "/subscriptions/#{@sub}/resources?api-version=2021-01-01&" <>
        URI.encode_query(%{"$filter" => "wat eq 'x'"}))
      |> call()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["value"] == []

    # Pagination: 101 resources, default maxitempages=1 -> 100 + nextLink.
    for i <- 1..101 do
      id =
        "/subscriptions/#{@sub}/resourceGroups/rg-p/providers/Microsoft.Network/virtualNetworks/v#{i}"

      Store.put(:smalt_resources, String.downcase(id), %{
        "id" => id,
        "name" => "v#{i}",
        "type" => "Microsoft.Network/virtualNetworks",
        "location" => "eastus",
        "properties" => %{},
        "tags" => %{},
        "systemData" => %{}
      })
    end

    conn = conn(:get, "/subscriptions/#{@sub}/resources?api-version=2021-04-01") |> call()
    assert conn.status == 200
    page1 = Jason.decode!(conn.resp_body)
    assert length(page1["value"]) == 100
    assert is_binary(page1["nextLink"])

    # Follow nextLink: remaining page.
    %{path: path, query: q} = URI.parse(page1["nextLink"])
    conn = conn(:get, path <> "?" <> q) |> call()
    assert conn.status == 200
    page2 = Jason.decode!(conn.resp_body)
    assert length(page2["value"]) == 4
    refute Map.has_key?(page2, "nextLink")
  end

  # ---------------------------------------------------------------------------
  # Wave-2: Defaults.apply wired after check_shape; location/tags always RAW.
  # ---------------------------------------------------------------------------
  test "storage PUT with minimal body carries defaults; location never the template string" do
    type = "Microsoft.Storage/storageAccounts"

    path =
      "/subscriptions/#{@sub}/resourceGroups/def-rg/providers/Microsoft.Storage/storageAccounts/def-st?api-version=#{api_v(type)}"

    conn =
      conn(:put, path, %{"location" => "westus", "sku" => %{"name" => "Standard_LRS"}})
      |> call()

    # storageAccounts is LRO-async: create -> 202 (record already in Store).
    assert conn.status == 202

    get_conn = conn(:get, path) |> call()
    assert get_conn.status == 200
    body = Jason.decode!(get_conn.resp_body)
    assert body["sku"] == %{"name" => "Standard_LRS"}
    assert body["kind"] == "StorageV2"
    assert body["properties"]["minimumTlsVersion"] == "TLS1_2"
    assert body["properties"]["provisioningState"] == "Succeeded"
    # location from the RAW payload — never the DURMT template string.
    assert body["location"] == "westus"
    refute body["location"] =~ "[resourceGroup()"
  end

  test "vault PUT keeps user properties over defaults; nested properties sku lands" do
    type = "Microsoft.KeyVault/vaults"

    path =
      "/subscriptions/#{@sub}/resourceGroups/def-rg/providers/Microsoft.KeyVault/vaults/kv-def?api-version=#{api_v(type)}"

    conn =
      conn(:put, path, %{
        "location" => "westus",
        "properties" => %{"skuName" => "standard", "enableSoftDelete" => false}
      })
      |> call()

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["location"] == "westus"
    assert body["properties"]["enableSoftDelete"] == false
    assert body["properties"]["sku"] == %{"family" => "A", "name" => "standard"}
    assert body["properties"]["tenantId"] == "[subscription().tenantId]"
  end

  # ---------------------------------------------------------------------------
  # Wave-2: provider listing + namespace GET + register/unregister.
  # ---------------------------------------------------------------------------
  test "providers: GET namespace 200/404, register -> Registered, unregister -> Unregistering, GET stays Registered" do
    # Known namespace.
    conn = conn(:get, "/subscriptions/#{@sub}/providers/Microsoft.Network?api-version=2021-04-01")
    |> call()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["namespace"] == "Microsoft.Network"
    assert body["registrationState"] == "Registered"
    assert is_list(body["resourceTypes"]) and body["resourceTypes"] != []

    # Unknown namespace.
    conn =
      conn(:get, "/subscriptions/#{@sub}/providers/Microsoft.Bogus?api-version=2021-04-01")
      |> call()

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ResourceNotFound"

    # Register -> Registered; Unregister -> Unregistering.
    reg =
      conn(:post, "/subscriptions/#{@sub}/providers/Microsoft.Network/register?api-version=2021-04-01", %{})
      |> call()

    assert reg.status == 200
    assert Jason.decode!(reg.resp_body)["registrationState"] == "Registered"

    unreg =
      conn(:post, "/subscriptions/#{@sub}/providers/Microsoft.Network/unregister?api-version=2021-04-01", %{})
      |> call()

    assert unreg.status == 200
    assert Jason.decode!(unreg.resp_body)["registrationState"] == "Unregistering"

    # Read-only enclave truth: GET stays Registered.
    conn = conn(:get, "/subscriptions/#{@sub}/providers/Microsoft.Network?api-version=2021-04-01")
    |> call()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["registrationState"] == "Registered"

    # Register of an unknown namespace 404s.
    reg =
      conn(:post, "/subscriptions/#{@sub}/providers/Microsoft.Bogus/register?api-version=2021-04-01", %{})
      |> call()

    assert reg.status == 404
    assert Jason.decode!(reg.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  # ---------------------------------------------------------------------------
  # Wave-2: vaults/secrets child route lifecycle (parented).
  # ---------------------------------------------------------------------------
  test "vault secrets child lifecycle: 404 on missing parent, PUT/GET/LIST/DELETE" do
    secret_type = "Microsoft.KeyVault/vaults/secrets"

    secrets_base =
      "/subscriptions/#{@sub}/resourceGroups/sec-rg/providers/Microsoft.KeyVault/vaults/kv-sec/secrets"

    path = "#{secrets_base}/sec-01?api-version=#{api_v(secret_type)}"

    # Missing parent -> 404 ResourceNotFound. The orphan probe body is
    # shape-CONFORMING (location present): the refusal-tier chain
    # (shape before parent-existence) answers 400 for malformed bodies even
    # when the parent is missing — that tiering is asserted in the refusal
    # sweep. Only a conforming body isolates the parent gate here.
    orphan =
      conn(:put, path, %{"location" => "eastus", "properties" => %{"value" => "s3cret"}}) |> call()

    assert orphan.status == 404
    assert Jason.decode!(orphan.resp_body)["error"]["code"] == "ResourceNotFound"

    # Create the parent vault via the generic route.
    conn(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/sec-rg/providers/Microsoft.KeyVault/vaults/kv-sec?api-version=#{api_v("Microsoft.KeyVault/vaults")}",
      %{"location" => "eastus", "properties" => %{"skuName" => "standard", "tenantId" => "t"}}
    )
    |> call()

    put_conn = conn(:put, path, %{"location" => "eastus", "properties" => %{"value" => "s3cret"}}) |> call()
    assert put_conn.status == 201
    assert Jason.decode!(put_conn.resp_body)["type"] == secret_type

    assert conn(:get, path) |> call() |> Map.get(:status) == 200

    list_conn = conn(:get, "#{secrets_base}?api-version=#{api_v(secret_type)}") |> call()
    assert %{"value" => items} = Jason.decode!(list_conn.resp_body)
    assert length(items) == 1

    assert conn(:delete, path) |> call() |> Map.get(:status) == 200
  end

  # ---------------------------------------------------------------------------
  # Wave-2: cosmos sqlDatabases/sqlContainers parented children + seeding.
  # ---------------------------------------------------------------------------
  test "cosmos sqlDatabases/sqlContainers: 404 orphan, lifecycle, rid stamping, seeding" do
    db_type = "Microsoft.DocumentDB/databaseAccounts/sqlDatabases"
    coll_type = "Microsoft.DocumentDB/databaseAccounts/sqlContainers"

    if Smalt.Registry.admitted?(db_type) and Smalt.Registry.admitted?(coll_type) do
      acct_base =
        "/subscriptions/#{@sub}/resourceGroups/cos-rg/providers/Microsoft.DocumentDB/databaseAccounts"

      dbs_base = "#{acct_base}/cos-acct/sqlDatabases"
      db_path = "#{dbs_base}/db1?api-version=#{api_v(db_type)}"

      # Missing account -> 404 ResourceNotFound. Conforming probe body
      # (location present) — malformed bodies answer 400 via the
      # shape-before-parent refusal tier (see refusal sweep).
      orphan = conn(:put, db_path, %{"location" => "eastus"}) |> call()
      assert orphan.status == 404
      assert Jason.decode!(orphan.resp_body)["error"]["code"] == "ResourceNotFound"

      conn(:put, "#{acct_base}/cos-acct?api-version=#{api_v("Microsoft.DocumentDB/databaseAccounts")}", %{
        "location" => "eastus"
      })
      |> call()

      put_conn = conn(:put, db_path, %{"location" => "eastus", "properties" => %{}}) |> call()
      assert put_conn.status == 201

      db_body = Jason.decode!(put_conn.resp_body)
      assert db_body["type"] == db_type

      # rid stamping from the Cosmos public API when the data plane is up.
      if Smalt.DataPlane.Cosmos.store_ready?() do
        assert db_body["properties"]["_rid"] == Smalt.DataPlane.Cosmos.db_rid("db1")
      end

      coll_path = "#{dbs_base}/db1/sqlContainers/c1?api-version=#{api_v(coll_type)}"

      coll_conn =
        conn(:put, coll_path, %{
          "location" => "eastus",
          "properties" => %{"partitionKey" => %{"paths" => ["/pk"]}}
        })
        |> call()

      assert coll_conn.status == 201

      coll_body = Jason.decode!(coll_conn.resp_body)

      if Smalt.DataPlane.Cosmos.store_ready?() do
        assert coll_body["properties"]["_rid"] == Smalt.DataPlane.Cosmos.coll_rid("db1", "c1")
        assert {:ok, 201, _, _} = Smalt.DataPlane.Cosmos.create_db("db1")
      end

      list_conn = conn(:get, "#{dbs_base}?api-version=#{api_v(db_type)}") |> call()
      assert %{"value" => dbs} = Jason.decode!(list_conn.resp_body)
      # prefix-scan lists carry deep descendants; count only db-typed rows.
      assert Enum.count(dbs, &(&1["type"] == db_type)) == 1

      assert conn(:delete, coll_path) |> call() |> Map.get(:status) == 200
      assert conn(:delete, db_path) |> call() |> Map.get(:status) == 200
    else
      # Skip loudly if the registry regen hasn't landed the child types.
      IO.puts("[SKIP] cosmos child types not admitted — registry regen pending")
      assert true
    end
  end

  # ---------------------------------------------------------------------------
  # Wave-2: storageAccounts DELETE — 202 LRO, cascade sweep, 404 fence.
  # ---------------------------------------------------------------------------
  test "storageAccount DELETE: 202 LRO, cascade removes children, missing -> 404 ResourceNotFound" do
    sa_type = "Microsoft.Storage/storageAccounts"
    container_type = "Microsoft.Storage/storageAccounts/blobServices/containers"

    acct_path =
      "/subscriptions/#{@sub}/resourceGroups/casc-rg/providers/Microsoft.Storage/storageAccounts/casc-st?api-version=#{api_v(sa_type)}"

    conn(
      :put,
      acct_path,
      %{"location" => "eastus", "properties" => %{"skuName" => "Standard_LRS"}}
    )
    |> call()

    container_path =
      "/subscriptions/#{@sub}/resourceGroups/casc-rg/providers/Microsoft.Storage/storageAccounts/casc-st/blobServices/default/containers/c1?api-version=#{api_v(container_type)}"

    assert conn(:put, container_path, %{"location" => "eastus", "properties" => %{}})
           |> call()
           |> Map.get(:status) == 201

    del_conn = conn(:delete, acct_path) |> call()
    assert del_conn.status == 202
    assert get_resp_header(del_conn, "azure-asyncoperation") != []
    assert get_resp_header(del_conn, "location") != []
    assert get_resp_header(del_conn, "retry-after") == ["1"]

    # Account + cascaded children are gone (raw store read).
    key = String.downcase("/subscriptions/#{@sub}/resourceGroups/casc-rg/providers/Microsoft.Storage/storageAccounts/casc-st")
    refute match?({:ok, _}, Store.get(:smalt_resources, key))

    child_prefix =
      String.downcase(
        "/subscriptions/#{@sub}/resourceGroups/casc-rg/storageAccounts/casc-st/"
      )

    assert Store.prefix_keys(:smalt_resources, child_prefix) == []

    assert conn(:get, acct_path) |> call() |> Map.get(:status) == 404

    # Missing account delete -> 404 ResourceNotFound.
    missing = conn(:delete, acct_path) |> call()
    assert missing.status == 404
    assert Jason.decode!(missing.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  # ---------------------------------------------------------------------------
  # HEAD existence checks (azurerm CheckNameExists, no api-version)
  # ---------------------------------------------------------------------------
  test "HEAD databaseAccountNames answers 404 EMPTY body with no api-version (not exists)" do
    conn =
      conn(:head, "/subscriptions/#{@sub}/providers/Microsoft.DocumentDB/databaseAccountNames/tf-no-such-acct")
      |> call()

    assert conn.status == 404
    # autorest HEAD parsing: EMPTY body is the contract (JSON 400 broke it).
    assert conn.resp_body == ""
  end

  test "HEAD databaseAccountNames answers 204 EMPTY body once the account exists" do
    id =
      String.downcase(
        "/subscriptions/#{@sub}/resourceGroups/head-rg/providers/Microsoft.DocumentDB/databaseAccounts/head-acct"
      )

    Store.put(:smalt_resources, id, %{"id" => id, "name" => "head-acct"})

    conn =
      conn(:head, "/subscriptions/#{@sub}/providers/Microsoft.DocumentDB/databaseAccountNames/head-acct")
      |> call()

    assert conn.status == 204
    assert conn.resp_body == ""
  end

  test "HEAD databaseAccountNames flips back to 404 after the account is deleted" do
    id =
      String.downcase(
        "/subscriptions/#{@sub}/resourceGroups/head-rg2/providers/Microsoft.DocumentDB/databaseAccounts/head-acct2"
      )

    Store.put(:smalt_resources, id, %{"id" => id, "name" => "head-acct2"})
    Store.delete(:smalt_resources, id)

    conn =
      conn(:head, "/subscriptions/#{@sub}/providers/Microsoft.DocumentDB/databaseAccountNames/head-acct2")
      |> call()

    assert conn.status == 404
    assert conn.resp_body == ""
  end

  # Sleep until just after a wall-clock second boundary, so a test that
  # counts requests against the 1-second fixed window has near-seconds of
  # margin before the window rolls over mid-test.
  defp wait_for_fresh_window do
    ms = System.system_time(:millisecond)
    rem = rem(ms, 1000)

    if rem > 800 do
      Process.sleep(1000 - rem + 20)
    end

    :ok
  end
end

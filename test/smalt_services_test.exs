defmodule SmaltServicesTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router, as: ArmRouter
  alias Smalt.EgressRouter
  alias Smalt.Registry
  alias Smalt.Store

  @arm_opts ArmRouter.init([])
  @egress_opts EgressRouter.init([])

  # A known-good hex64 measurement in the MAA baseline (see setup).
  @measurement String.duplicate("ab", 32)
  @off_baseline_measurement String.duplicate("cd", 32)

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    Application.put_env(:smalt, :maa_measurement_baseline, [@measurement])

    on_exit(fn -> Application.delete_env(:smalt, :maa_measurement_baseline) end)

    default_sub = "00000000-0000-0000-0000-000000000000"

    Store.put(:smalt_subscriptions, default_sub, %{
      "id" => "/subscriptions/#{default_sub}",
      "subscriptionId" => default_sub,
      "displayName" => "Sovereign Smalt Subscription",
      "state" => "Enabled"
    })

    :ok
  end

  # Helpers -------------------------------------------------------------------

  defp av(type), do: "?api-version=#{Registry.latest_version(type)}"

  defp arm_put(path, type, body, opts \\ []) do
    conn(:put, path <> av(type), body)
    |> maybe_xms_version(opts[:blob] || false)
    |> ArmRouter.call(@arm_opts)
  end

  defp maybe_xms_version(conn, true), do: conn |> put_req_header("x-ms-version", "2021-04-01")
  defp maybe_xms_version(conn, false), do: conn

  # Poll an LRO operation (202 responses carry Azure-AsyncOperation) to a
  # terminal status via the router's polling route.
  defp await_lro(conn) do
    assert conn.status == 202

    op_path =
      get_resp_header(conn, "azure-asyncoperation") |> hd() |> URI.parse() |> Map.get(:path)

    poll(op_path)
  end

  defp poll(op_path) do
    conn = conn(:get, op_path) |> ArmRouter.call(@arm_opts)
    body = Jason.decode!(conn.resp_body)

    case body["status"] do
      "Succeeded" -> conn
      _ -> poll(op_path)
    end
  end

  # ===========================================================================
  # 1. ARM Registration & Discovery Across All 15 Smalt Services
  # ===========================================================================
  test "Registry contains all 15 consumed Project Smalt service types" do
    types = Registry.admitted_resource_types()
    assert length(types) >= 15

    # Check Tier 1
    assert "Microsoft.KeyVault/managedHSMs" in types
    assert "Microsoft.ConfidentialLedger/ledgers" in types
    assert "Microsoft.ConfidentialLedger/managedCCFs" in types
    assert "Microsoft.Attestation/attestationProviders" in types

    # Check Tier 2
    assert "Microsoft.Compute/virtualMachines" in types
    assert "Microsoft.App/containerApps" in types
    assert "Microsoft.ContainerService/managedClusters" in types

    # Check Tier 3
    assert "Microsoft.Storage/storageAccounts" in types
    assert "Microsoft.DocumentDB/databaseAccounts" in types
    assert "Microsoft.Purview/accounts" in types

    # Check Tier 4
    assert "Microsoft.Network/virtualNetworks" in types
    assert "Microsoft.Network/privateDnsZones" in types
    assert "Microsoft.ServiceBus/namespaces" in types
    assert "Microsoft.EventGrid/topics" in types
    assert "Microsoft.EventHub/namespaces" in types
    assert "Microsoft.OperationalInsights/workspaces" in types
  end

  test "ARM Gateway PUT/GET for Tier 1: Confidential Ledger & Managed HSM" do
    sub = "00000000-0000-0000-0000-000000000000"
    rg = "smalt-sec-rg"

    # 1. Put Resource Group
    conn(:put, "/subscriptions/#{sub}/resourcegroups/#{rg}", %{"location" => "eastus"})
    |> ArmRouter.call(@arm_opts)

    # 2. Put Confidential Ledger (DefaultShape: location required)
    acl_type = "Microsoft.ConfidentialLedger/ledgers"

    acl_path =
      "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.ConfidentialLedger/ledgers/smalt-acl"

    put_conn =
      arm_put(acl_path, acl_type, %{
        "location" => "eastus",
        "properties" => %{"ledgerType" => "Private"}
      })

    assert put_conn.status == 201
    assert Jason.decode!(put_conn.resp_body)["type"] == acl_type

    # GET it back
    get_conn = conn(:get, acl_path <> av(acl_type)) |> ArmRouter.call(@arm_opts)
    assert get_conn.status == 200

    # 3. Put Managed HSM (ManagedHsmShape: location + properties.skuName)
    hsm_type = "Microsoft.KeyVault/managedHSMs"

    hsm_path =
      "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.KeyVault/managedHSMs/smalt-hsm"

    hsm_conn =
      arm_put(hsm_path, hsm_type, %{
        "location" => "eastus",
        "properties" => %{"skuName" => "Standard_B1"}
      })

    assert hsm_conn.status == 201

    # Negative: HSM payload missing required properties.skuName -> 400
    # InvalidResourceShape (GraphLaw shape enforcement is live).
    malformed_conn =
      arm_put(
        "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.KeyVault/managedHSMs/smalt-hsm-bad",
        hsm_type,
        %{"location" => "eastus", "properties" => %{}}
      )

    assert malformed_conn.status == 400
    assert Jason.decode!(malformed_conn.resp_body)["error"]["code"] == "InvalidResourceShape"

    # Negative: missing api-version -> 400 MissingApiVersionParameter
    missing_av_conn =
      conn(:put, hsm_path, %{
        "location" => "eastus",
        "properties" => %{"skuName" => "Standard_B1"}
      })
      |> ArmRouter.call(@arm_opts)

    assert missing_av_conn.status == 400

    assert Jason.decode!(missing_av_conn.resp_body)["error"]["code"] ==
             "MissingApiVersionParameter"

    # KD-78 monotonic api-version admission (operator ruling, fenced in
    # test/api_version_admission_test.exs): a STALE but parseable version
    # admits normally; only > latest -> 400 InvalidApiVersionParameter.
    stale_av_conn =
      conn(:put, hsm_path <> "?api-version=1999-01-01", %{
        "location" => "eastus",
        "properties" => %{"skuName" => "Standard_B1"}
      })
      |> ArmRouter.call(@arm_opts)

    assert stale_av_conn.status in 200..299
    refute Jason.decode!(stale_av_conn.resp_body)["error"]

    future_av_conn =
      conn(:put, hsm_path <> "-future?api-version=2099-01-01", %{
        "location" => "eastus",
        "properties" => %{"skuName" => "Standard_B1"}
      })
      |> ArmRouter.call(@arm_opts)

    assert future_av_conn.status == 400

    assert Jason.decode!(future_av_conn.resp_body)["error"]["code"] ==
             "InvalidApiVersionParameter"
  end

  test "ARM Gateway PUT/GET for Tier 2: AKS Enclave Clusters and WASI Container Apps" do
    sub = "00000000-0000-0000-0000-000000000000"
    rg = "smalt-compute-rg"

    # AKS (DefaultShape: location required)
    aks_type = "Microsoft.ContainerService/managedClusters"

    aks_path =
      "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.ContainerService/managedClusters/smalt-aks"

    aks_conn =
      arm_put(aks_path, aks_type, %{
        "location" => "eastus",
        "properties" => %{"dnsPrefix" => "smalt-enclave"}
      })

    assert aks_conn.status == 201

    # Container App WASI (DefaultShape: location required)
    wasi_type = "Microsoft.App/containerApps"

    wasi_path =
      "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.App/containerApps/graphlaw-wasi"

    wasi_conn =
      arm_put(wasi_path, wasi_type, %{
        "location" => "eastus",
        "properties" => %{"template" => %{"containers" => []}}
      })

    assert wasi_conn.status == 201

    # Negative: malformed shape (missing required location) -> 400
    # InvalidResourceShape
    malformed_conn =
      arm_put(wasi_path <> "-bad", wasi_type, %{"properties" => %{"template" => %{}}})

    assert malformed_conn.status == 400
    assert Jason.decode!(malformed_conn.resp_body)["error"]["code"] == "InvalidResourceShape"
  end

  test "ARM Gateway PUT/GET for Tier 3 & 4: Purview, Sentinel, Storage, EventHub" do
    sub = "00000000-0000-0000-0000-000000000000"
    rg = "smalt-gov-rg"

    # Purview (DefaultShape)
    purview_type = "Microsoft.Purview/accounts"

    conn =
      arm_put(
        "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Purview/accounts/smalt-purview",
        purview_type,
        %{"location" => "eastus"}
      )

    assert conn.status == 201

    # Sentinel Log Analytics Workspace (DefaultShape)
    sentinel_type = "Microsoft.OperationalInsights/workspaces"

    sentinel_path =
      "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.OperationalInsights/workspaces/smalt-siem"

    conn = arm_put(sentinel_path, sentinel_type, %{"location" => "eastus"})
    assert conn.status == 201

    # Storage Account (StorageAccountShape: location + properties.skuName;
    # LRO type -> 202 + Azure-AsyncOperation, then poll to Succeeded)
    storage_type = "Microsoft.Storage/storageAccounts"

    storage_path =
      "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Storage/storageAccounts/smaltwormstore"

    storage_conn =
      arm_put(storage_path, storage_type, %{
        "location" => "eastus",
        "properties" => %{"skuName" => "Standard_LRS"}
      })

    assert storage_conn.status == 202
    poll_conn = await_lro(storage_conn)
    assert poll_conn.status == 200
    assert Jason.decode!(poll_conn.resp_body)["status"] == "Succeeded"

    # EventHub Namespace (DefaultShape)
    eh_type = "Microsoft.EventHub/namespaces"

    conn =
      arm_put(
        "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.EventHub/namespaces/smalt-events",
        eh_type,
        %{"location" => "eastus"}
      )

    assert conn.status == 201
  end

  # ===========================================================================
  # 2. Data Plane Parity: Azure Confidential Ledger (ACL)
  # ===========================================================================
  test "Confidential Ledger Merkle Tree Append and Receipt Generation" do
    entry = %{
      "matter_id" => "MATTER-7492",
      "bates_stamp" => "ATH-00004921",
      "sha256" => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    }

    # Append entry
    post_conn = conn(:post, "/app/transactions", entry)
    post_conn = EgressRouter.call(post_conn, @egress_opts)
    assert post_conn.status == 201

    receipt = Jason.decode!(post_conn.resp_body)
    assert is_binary(receipt["transactionId"])
    assert is_binary(receipt["merkle_root"])
    assert receipt["contents"]["matter_id"] == "MATTER-7492"

    # Verify retrieval
    get_conn = conn(:get, "/app/transactions/#{receipt["transactionId"]}")
    get_conn = EgressRouter.call(get_conn, @egress_opts)
    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body)["merkle_root"] == receipt["merkle_root"]
  end

  # ===========================================================================
  # 3. Data Plane Parity: Microsoft Azure Attestation (MAA) Token Issuance
  # ===========================================================================
  test "Microsoft Azure Attestation provides verifiable JWT token for baseline measurement" do
    measurement_quote = %{
      "measurement" => @measurement,
      "attestation_type" => "sevsnpvm",
      "tee_type" => "AMD-SEV-SNP"
    }

    conn = conn(:post, "/attest/Tpm", measurement_quote)
    conn = EgressRouter.call(conn, @egress_opts)
    assert conn.status == 200

    result = Jason.decode!(conn.resp_body)
    assert is_binary(result["token"])
    assert result["claims"]["x-ms-compliance-status"] == "azure-compliant-cvm"

    # Negative: a well-formed hex64 measurement NOT in the baseline is refused
    # with 400 attestationFailedVerdict.
    off_baseline_conn =
      conn(:post, "/attest/Tpm", %{"measurement" => @off_baseline_measurement})
      |> EgressRouter.call(@egress_opts)

    assert off_baseline_conn.status == 400

    assert Jason.decode!(off_baseline_conn.resp_body)["error"]["code"] ==
             "attestationFailedVerdict"

    # Negative: malformed (non-hex64) measurement is refused the same way.
    malformed_conn =
      conn(:post, "/attest/Tpm", %{"measurement" => "4a8c9b...mock...snp"})
      |> EgressRouter.call(@egress_opts)

    assert malformed_conn.status == 400
    assert Jason.decode!(malformed_conn.resp_body)["error"]["code"] == "attestationFailedVerdict"
  end

  # ===========================================================================
  # 4. Data Plane Parity: Azure Immutable Blob Storage (WORM & XML)
  # ===========================================================================
  test "Azure Immutable Blob Storage container WORM policy and XML listing" do
    account = "smaltwormstore"
    container = "evidence-vault"

    # Create WORM Container (blob routes require x-ms-version)
    put_container =
      conn(:put, "/#{account}/#{container}", %{})
      |> put_req_header("x-ms-version", "2021-04-01")

    put_container = EgressRouter.call(put_container, @egress_opts)
    assert put_container.status == 201

    # Put Block Blob
    blob_content = "RAW BATES STAMPED LITIGATION EVIDENCE EXHIBIT A"

    put_blob =
      conn(:put, "/#{account}/#{container}/exhibit_a.pdf", blob_content)
      |> put_req_header("content-type", "application/pdf")
      |> put_req_header("x-ms-version", "2021-04-01")

    put_blob = EgressRouter.call(put_blob, @egress_opts)
    assert put_blob.status == 201
    blob_meta = Jason.decode!(put_blob.resp_body)
    assert is_binary(blob_meta["etag"])

    # Attempt overwrite on WORM container -> Refused with HTTP 409 Conflict
    overwrite_attempt =
      conn(:put, "/#{account}/#{container}/exhibit_a.pdf", "TAMPERED DATA")
      |> put_req_header("content-type", "application/pdf")
      |> put_req_header("x-ms-version", "2021-04-01")

    overwrite_attempt = EgressRouter.call(overwrite_attempt, @egress_opts)
    assert overwrite_attempt.status == 409
    err = Jason.decode!(overwrite_attempt.resp_body)["error"]
    assert is_map(err) and err["code"] == "ContainerLocked"

    # GET Blob content
    get_blob =
      conn(:get, "/#{account}/#{container}/exhibit_a.pdf")
      |> put_req_header("x-ms-version", "2021-04-01")

    get_blob = EgressRouter.call(get_blob, @egress_opts)
    assert get_blob.status == 200
    assert get_blob.resp_body == blob_content

    # List Blobs in XML format for Azure SDK
    list_xml =
      conn(:get, "/#{account}/#{container}")
      |> put_req_header("x-ms-version", "2021-04-01")

    list_xml = EgressRouter.call(list_xml, @egress_opts)
    assert list_xml.status == 200
    assert String.contains?(list_xml.resp_body, "<EnumerationResults")
    assert String.contains?(list_xml.resp_body, "<Name>exhibit_a.pdf</Name>")
  end

  # ===========================================================================
  # 5. Data Plane Parity: Event Grid CloudEvents 1.0 Streaming
  # ===========================================================================
  test "Event Grid accepts CloudEvents 1.0 and routes to subscribers" do
    topic = "discovery-events"

    cloudevent = %{
      "specversion" => "1.0",
      "type" => "com.microsoft.azure.blob.created",
      "source" => "/subscriptions/0000/resourceGroups/smalt-rg/storageAccounts/smaltwormstore",
      "id" => "ev-001",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "data" => %{"blobUrl" => "https://smaltwormstore.blob.core.windows.net/evidence/doc1.pdf"}
    }

    pub_conn =
      conn(:post, "/topics/#{topic}/events", Jason.encode!([cloudevent]))
      |> put_req_header("content-type", "application/json")

    pub_conn = EgressRouter.call(pub_conn, @egress_opts)
    assert pub_conn.status == 200

    list_conn = conn(:get, "/topics/#{topic}/events")
    list_conn = EgressRouter.call(list_conn, @egress_opts)
    assert list_conn.status == 200
    events = Jason.decode!(list_conn.resp_body)
    assert length(events) >= 1
    assert hd(events)["id"] == "ev-001"
  end
end

defmodule Kd79BlobApiVersionWireTest do
  # KD-COVERS: KD-79 (vaultUri loopback-by-design fence anchor; canonical row in
  # docs/jira/v26.10.14/KNOWN_DIVERGENCES.md — this file's KD-83 legs ride the
  # same KD-T5 storage-arm census, and KD-79's falsifier surface is exercised
  # by the KD-T5-F1 legs in test/arm/fr5_tf_divergence_closures_test.exs).
  @moduledoc """
  KD-83 wire fence (registered as KD-83; file name retains kd79 lane history): azurerm 4.54.0 issues `Microsoft.Storage/storageAccounts/blobServices`
  ARM calls with api-version 2023-05-01 (witnessed:
  /tmp/tf-cleanroom.fe6rSw/tf-apply.log — InvalidApiVersionParameter naming
  2021-04-01 as latest). The blob-family lattice top in the registry pack
  (smalt-substrate-pack ontology, tb-blobsvc) is advanced to 2023-05-01 and
  the monotonic gate admits it.

  Literal-version pins (not latest_version/1) so an ontology regression to
  2021-04-01 re-fails this fence.
  """

  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "kd79-rg"
  @witnessed "2023-05-01"

  setup do
    # i21 armor: resilient clear rides out async-sibling ETS teardown
    # (SmaltTest.Wire.resilient_clear!/0; replaces ensure_store/0 + bare
    # Store.clear() — same race, weaker armor, see egress_dispatch_test).
    SmaltTest.Wire.resilient_clear!()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "KD-83 wire fence",
      "state" => "Enabled"
    })

    # Real storage account parent through the real router.
    put_parent!(
      "providers/Microsoft.Storage/storageAccounts/kd79store",
      %{"location" => "eastus", "properties" => %{}},
      "parent SA"
    )

    # Real resource group parent.
    put_parent!("", %{"location" => "eastus"}, "parent RG")

    :ok
  after
    Store.clear()
  end

  test "registry lattice top for blobServices is the witnessed 2023-05-01" do
    assert Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices") == @witnessed
  end

  test "azurerm-witnessed 2023-05-01 admitted on blobServices PUT (not InvalidApiVersionParameter)" do
    conn = arm_put("providers/Microsoft.Storage/storageAccounts/kd79store/blobServices/default")

    refute invalid_api_version?(conn),
           "blobServices PUT at 2023-05-01 refused with InvalidApiVersionParameter: #{conn.status} #{response_body(conn)}"
  end

  test "witnessed version admitted on containers PUT + GET" do
    put_conn =
      arm_put(
        "providers/Microsoft.Storage/storageAccounts/kd79store/blobServices/default/containers/kd79c"
      )

    refute invalid_api_version?(put_conn),
           "container PUT refused: #{put_conn.status} #{response_body(put_conn)}"

    get_conn =
      arm_get(
        "providers/Microsoft.Storage/storageAccounts/kd79store/blobServices/default/containers/kd79c"
      )

    refute invalid_api_version?(get_conn),
           "container GET refused: #{get_conn.status} #{response_body(get_conn)}"
  end

  test "future version refused typed, naming the witnessed latest" do
    conn =
      arm_put(
        "providers/Microsoft.Storage/storageAccounts/kd79store/blobServices/default",
        "2099-12-31"
      )

    assert conn.status == 400
    body = response_body(conn)
    assert body =~ "InvalidApiVersionParameter"
    assert body =~ @witnessed
  end

  ## helpers

  # Real-router parent fixture whose failure names the fixture (a setup assert
  # otherwise reads as a cryptic bare assert). Fixture discipline unchanged.
  defp put_parent!(child_path, payload, fixture_name) do
    uri =
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/#{child_path}?api-version=#{@witnessed}"

    conn =
      :put
      |> conn(uri, Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")

    resp = Router.call(conn, @opts)

    assert resp.status in [200, 201, 202],
           "#{fixture_name} creation failed: #{resp.status} #{resp.resp_body}"
  end

  defp arm_put(child_path, version \\ @witnessed) do
    uri =
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/#{child_path}?api-version=#{version}"

    conn =
      :put
      |> conn(uri, Jason.encode!(%{"location" => "eastus", "properties" => %{}}))
      |> put_req_header("content-type", "application/json")

    Router.call(conn, @opts)
  end

  defp arm_get(child_path, version \\ @witnessed) do
    uri =
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/#{child_path}?api-version=#{version}"

    :get |> conn(uri) |> Router.call(@opts)
  end

  defp invalid_api_version?(conn) do
    conn.status == 400 and response_body(conn) =~ "InvalidApiVersionParameter"
  end

  defp response_body(conn), do: conn.resp_body || ""
end

defmodule Kd79BlobApiVersionWireTest do
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
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "KD-83 wire fence",
      "state" => "Enabled"
    })

    # Real storage account parent through the real router.
    sa_path =
      "providers/Microsoft.Storage/storageAccounts/kd79store"

    payload = %{"location" => "eastus", "properties" => %{}}

    conn =
      :put
      |> conn(
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/#{sa_path}?api-version=#{@witnessed}",
        Jason.encode!(payload)
      )
      |> put_req_header("content-type", "application/json")

    resp = Router.call(conn, @opts)
    assert resp.status in [200, 201, 202], "parent SA creation failed: #{resp.status}"

    # Real resource group parent.
    conn =
      :put
      |> conn(
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}?api-version=#{@witnessed}",
        Jason.encode!(%{"location" => "eastus"})
      )
      |> put_req_header("content-type", "application/json")

    resp = Router.call(conn, @opts)
    assert resp.status in [200, 201, 202], "parent RG creation failed: #{resp.status}"

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

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> ensure_store()
          end
        end
    end
  end
end

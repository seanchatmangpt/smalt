# AZURE-FIDELITY lane 7 gate: create-blade validation surface.
#
# Chicago discipline: real in-process dispatch through Smalt.ArmGateway.Router,
# real Smalt.Store rows (seeded consumption = real resource PUTs), real
# SkuQuota availability law. No mocks.
#
# Context: solo (integration tier, in-process dispatch).
defmodule Smalt.Integration.SkuQuotaTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @api_version "2021-04-01"
  @created 201
  @accepted 202
  @conflict 409
  @ok 200
  @not_found 404

  test "ResourceSkus list carries the documented shape (resourceType, locations, restrictions, family)" do
    conn =
      get("/subscriptions/sub-sku/providers/Microsoft.Compute/skus?api-version=#{@api_version}")

    assert conn.status == @ok

    skus = Jason.decode!(conn.resp_body)["value"]
    assert is_list(skus) and length(skus) >= 3

    for sku <- skus do
      assert sku["resourceType"] == "virtualMachines"
      assert is_binary(sku["name"])
      assert is_binary(sku["family"])
      assert is_list(sku["locations"]) and sku["locations"] != []
      assert is_list(sku["restrictions"])
    end

    names = Enum.map(skus, & &1["name"])
    assert "Standard_D2s_v5" in names
    assert "Standard_NC6" in names

    # Restriction law: Standard_NC6 carries a NotAvailableForSubscription
    # restriction naming `local` (create blade greys it out there).
    nc6 = Enum.find(skus, &(&1["name"] == "Standard_NC6"))
    assert nc6["family"] == "standardNCSeries"

    restriction =
      Enum.find(nc6["restrictions"], &(&1["reasonCode"] == "NotAvailableForSubscription"))

    assert %{"type" => "Location", "values" => values} = restriction
    assert "local" in values

    # D-family skus ship unrestricted.
    d2 = Enum.find(skus, &(&1["name"] == "Standard_D2s_v5"))
    assert d2["restrictions"] == []
  end

  test "$filter=location eq 'local' answers only skus available in local" do
    conn =
      get(
        "/subscriptions/sub-sku/providers/Microsoft.Compute/skus?api-version=#{@api_version}" <>
          "&$filter=location%20eq%20'local'"
      )

    assert conn.status == @ok
    names = Enum.map(Jason.decode!(conn.resp_body)["value"], & &1["name"])
    assert "Standard_NC6" not in names
    assert "Standard_D2s_v5" in names
  end

  test "quota usage reflects seeded consumption (Compute family + Network counts)" do
    sub = "sub-skuquota-#{System.system_time(:millisecond)}"
    rg = "rg-skuquota"

    # Seeded consumption: real PUTs of two D-family VMs in eastus.
    for i <- 1..2 do
      conn =
        put(
          "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Compute/virtualMachines/d-vm-#{i}?api-version=#{@api_version}",
          %{"location" => "eastus", "vmSize" => "Standard_D2s_v5"}
        )

      assert conn.status in [@created, @accepted],
             "seed PUT d-vm-#{i}: #{conn.status} #{inspect(conn.resp_body)}"
    end

    conn =
      get(
        "/subscriptions/#{sub}/providers/Microsoft.Compute/locations/eastus/usages?api-version=#{@api_version}"
      )

    assert conn.status == @ok

    rows = Jason.decode!(conn.resp_body)["value"]

    for row <- rows do
      assert %{
               "name" => %{"value" => _, "localizedValue" => _},
               "currentValue" => _,
               "limit" => _,
               "unit" => _
             } = row
    end

    ds = Enum.find(rows, &(&1["name"]["value"] == "standardDSv5Family"))
    assert ds["currentValue"] == 2
    assert ds["limit"] == 100

    nc = Enum.find(rows, &(&1["name"]["value"] == "standardNCSeries"))
    assert nc["currentValue"] == 0

    # Network quota rows count real stored vnets/nsgs.
    conn =
      get(
        "/subscriptions/#{sub}/providers/Microsoft.Network/locations/eastus/usages?api-version=#{@api_version}"
      )

    assert conn.status == @ok
    net_rows = Jason.decode!(conn.resp_body)["value"]
    assert Enum.find(net_rows, &(&1["name"]["value"] == "virtualNetworks"))["currentValue"] == 0
  end

  test "unavailable-SKU PUT answers the documented SKUNotAvailableAvailability 409 and never persists" do
    sub = "sub-sku409-#{System.system_time(:millisecond)}"

    path =
      "/subscriptions/#{sub}/resourceGroups/rg-sku409/providers/Microsoft.Compute/virtualMachines/nc-vm?api-version=#{@api_version}"

    conn =
      put(path, %{
        "location" => "local",
        "vmSize" => "Standard_NC6"
      })

    assert conn.status == @conflict,
           "expected 409, got: #{conn.status} #{inspect(conn.resp_body)}"

    err = Jason.decode!(conn.resp_body)["error"]
    assert err["code"] == "SKUNotAvailableAvailability"
    assert err["message"] =~ "Standard_NC6"
    assert err["message"] =~ "local"
    assert err["target"] == "Standard_NC6"
    assert err["innererror"] == %{}

    # Nothing persisted.
    conn = get(path)
    assert conn.status == @not_found
  end

  test "available-SKU PUT passes: LRO 202 accept, record persisted, GET reads back" do
    sub = "sub-skuok-#{System.system_time(:millisecond)}"

    path =
      "/subscriptions/#{sub}/resourceGroups/rg-skuok/providers/Microsoft.Compute/virtualMachines/d-vm-ok?api-version=#{@api_version}"

    conn = put(path, %{"location" => "local", "vmSize" => "Standard_D2s_v5"})

    # Real ARM create convention for virtualMachines: 202 + async operation.
    assert conn.status == @accepted,
           "expected 202, got: #{conn.status} #{inspect(conn.resp_body)}"

    op = Jason.decode!(conn.resp_body)
    assert op["status"] == "InProgress"
    assert op["resourceId"] =~ "/virtualMachines/d-vm-ok"

    # The record persists at PUT time; the async operation rides on top.
    conn = get(path)
    assert conn.status == @ok
    assert Jason.decode!(conn.resp_body)["name"] == "d-vm-ok"
  end

  # ---------------------------------------------------------------------------

  defp get(path), do: dispatch(:get, path, nil)
  defp put(path, body), do: dispatch(:put, path, body)

  defp dispatch(method, path, body) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    Router.call(Plug.Conn.fetch_query_params(conn), [])
  end
end

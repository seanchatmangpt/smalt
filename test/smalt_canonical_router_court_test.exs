defmodule Smalt.CanonicalRouterCourtTest do
  use ExUnit.Case, async: false

  # v26.10.31 inversion (WO-06): the court pins ROUTING SEMANTICS (the
  # ash_gateway flag contract), not the gateway module location.
  # `@router_module` is the dialect gateway seam — one attribute edit
  # re-points it if the ARM gateway relocates at strip time.
  @router_module Smalt.ArmGateway.Router

  @deep "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Network/dnsResolverPolicies/drp1/dnssecurityrules/rule1?api-version=2025-05-01"
  @collection "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Network/dnsResolverPolicies/drp1/dnssecurityrules?api-version=2025-05-01"
  @existing_face "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Network/virtualNetworks/vnet1?api-version=2021-04-01"

  defp dispatch(method, path, body \\ nil) do
    body_binary = body && Jason.encode!(body)

    conn =
      Plug.Test.conn(method, path, body_binary)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    %Plug.Conn{} = conn1 = @router_module.call(conn, [])
    {conn1.status, conn1.resp_body}
  end

  test "flag OFF (default): deep child path falls to the typed catch-all 404" do
    assert {404, body} = dispatch("PUT", @deep, %{"location" => "westus"})

    assert body =~ "RouteNotFound"
  end

  test "flag ON, api-version absent: passes through to the legacy 400 (parity)" do
    Application.put_env(:smalt, :ash_gateway, true)

    try do
      no_av = String.replace(@deep, "?api-version=2025-05-01", "")
      # pass-through reaches the legacy typed catch-all (4-seg deep paths are
      # never claimed without api-version; RouteNotFound is the pinned face)
      assert {404, body} = dispatch("PUT", no_av, %{"location" => "westus"})
      assert body =~ "RouteNotFound"
    after
      Application.put_env(:smalt, :ash_gateway, false)
    end
  end

  test "flag ON: deep child PUT claims + creates via Ash arm_put" do
    Application.put_env(:smalt, :ash_gateway, true)

    try do
      assert {201, body} = dispatch("PUT", @deep, %{"location" => "westus", "properties" => %{"p" => 1}})
      assert body =~ "dnssecurityrules/rule1"

      # GET named → 200 envelope
      assert {200, body} = dispatch("GET", @deep)
      assert body =~ "provisioningState"

      # GET collection (odd rest, 3 segs) → 200 value list
      assert {200, body} = dispatch("GET", @collection)
      assert body =~ "\"value\""

      # DELETE → 200
      assert {200, body} = dispatch("DELETE", @deep)
      assert body =~ "Deleted"
    after
      Application.put_env(:smalt, :ash_gateway, false)
    end
  end

  test "flag ON: existing 2-segment CRUD face still answers via the law-guard exclusion" do
    Application.put_env(:smalt, :ash_gateway, true)

    try do
      {status, body} =
        dispatch("PUT", @existing_face, %{
          "location" => "westus",
          "properties" => %{"addressPrefixes" => ["10.0.0.0/16"]}
        })

      assert status in [200, 201]
      # legacy envelope: provisioningState + id (CanonicalRouter envelope differs)
      assert body =~ "provisioningState"
      assert body =~ "/virtualNetworks/vnet1\""
    after
      Application.put_env(:smalt, :ash_gateway, false)
    end
  end
end

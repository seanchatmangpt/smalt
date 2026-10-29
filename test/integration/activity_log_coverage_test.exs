# CONVERGENCE lane V7: activity-log hook coverage — RG-level writes + deployment
# completions. AF-L5 hooked the generic resource PUT/PATCH/DELETE faces only;
# X2 witnessed a bare RG-put never landing in the log. This court proves the
# RG put/delete and a deployment completion each land exactly one event with
# the documented operationName/caller/resourceId.
#
# Chicago discipline: real dispatch through Smalt.ArmGateway.Router (real
# bearer mint via Smalt.Auth.StsKey.mint/1, real Store rows, real ETS ring),
# assertions on the real wire envelope. No mocks.

defmodule Smalt.Internal.ArmActivityLogCoverageTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.{Router, ActivityLog}

  @caller "99999999-8888-7777-6666-555555555555"
  @sub "sub-actlog-v7"

  setup do
    ActivityLog.reset()
    {:ok, rg: "rg-actlog-v7-#{rand()}"}
  after
    ActivityLog.reset()
  end

  test "RG put lands one event with the resourceGroups/write operationName", %{rg: rg} do
    conn = dispatch(:put, rg_path(rg), %{"location" => "eastus"})

    assert conn.status in [200, 201]

    %{"value" => [event]} = query()

    assert event["caller"] == @caller
    assert event["status"]["value"] == "Succeeded"
    assert event["resourceId"] == rg_id(rg)
    assert event["operationName"]["value"] == "Microsoft.Resources/resourceGroups/write"
    assert event["resourceGroup"] == rg
  end

  test "RG delete lands one event with the resourceGroups/delete operationName", %{rg: rg} do
    assert dispatch(:put, rg_path(rg), %{"location" => "eastus"}).status in [200, 201]

    ActivityLog.reset()

    conn = dispatch(:delete, rg_path(rg))
    assert conn.status in [200, 202]

    %{"value" => [event]} = query()

    assert event["caller"] == @caller
    assert event["status"]["value"] == "Succeeded"
    assert event["resourceId"] == rg_id(rg)
    assert event["operationName"]["value"] == "Microsoft.Resources/resourceGroups/delete"
    assert event["resourceGroup"] == rg
  end

  test "deployment completion lands one event with deployments/write", %{rg: rg} do
    assert dispatch(:put, rg_path(rg), %{"location" => "eastus"}).status in [200, 201]

    ActivityLog.reset()

    dep_name = "dep-actlog-#{rand()}"

    dep_path =
      "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.Resources/deployments/#{dep_name}"

    conn =
      dispatch(:put, dep_path, %{
        "properties" => %{"mode" => "Incremental", "template" => %{"resources" => []}}
      })

    assert conn.status == 200

    %{"value" => [event]} = query()

    assert event["operationName"]["value"] == "Microsoft.Resources/deployments/write"
    assert event["resourceId"] == dep_path
    assert event["caller"] == @caller
    assert event["status"]["value"] == "Succeeded"
    assert event["resourceGroup"] == rg
  end

  test "failed RG put (no location) records NO event", %{rg: rg} do
    conn = dispatch(:put, rg_path(rg), %{})

    assert conn.status == 400
    assert %{"value" => []} = query()
  end

  # -- helpers -------------------------------------------------------------------

  defp rand, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp rg_path(rg),
    do: "/subscriptions/#{@sub}/resourceGroups/#{rg}?api-version=2021-04-01"

  defp rg_id(rg), do: "/subscriptions/#{@sub}/resourceGroups/#{rg}"

  defp token do
    now = System.system_time(:second)

    claims = %{
      "aud" => "https://management.azure.com/",
      "iss" => "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0",
      "exp" => now + 600,
      "nbf" => now,
      "tid" => "00000000-0000-0000-0000-000000000000",
      "appid" => @caller
    }

    {:ok, token} = Smalt.Auth.StsKey.mint(claims)
    token
  end

  defp query(query_string \\ nil) do
    qs = if query_string, do: String.replace("#{query_string}&", " ", "%20"), else: ""

    conn =
      dispatch(
        :get,
        "/subscriptions/#{@sub}/providers/microsoft.insights/eventtypes/management/values?#{qs}api-version=2015-04-01"
      )

    assert conn.status == 200

    Jason.decode!(conn.resp_body)
  end

  defp dispatch(method, path, body \\ nil, opts \\ []) do
    base = conn(method, path, body && Jason.encode!(body))

    base =
      if body,
        do: Plug.Conn.put_req_header(base, "content-type", "application/json"),
        else: base

    base =
      case Keyword.get(opts, :auth) do
        nil -> Plug.Conn.put_req_header(base, "authorization", "Bearer #{token()}")
        token -> Plug.Conn.put_req_header(base, "authorization", "Bearer #{token}")
      end

    Router.call(Plug.Conn.fetch_query_params(base), [])
  end
end

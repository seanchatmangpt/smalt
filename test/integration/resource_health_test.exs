# CONVERGENCE lane V9 — Microsoft.ResourceHealth/availabilityStatuses arm_gateway
# integration court.
#
# Chicago discipline: real router dispatch, real Store rows, real computed
# health (Smalt.Arm.ResourceHealth synthetic-Available law). No mocks.
#
# Legs:
#   1. subscription-scope list: every provisioned resource Available, documented
#      availabilityStatus shape (properties.availabilityState/summary), 200
#   2. unknown subscription -> 404 SubscriptionNotFound
#   3. per-resource current face: Available + nested properties
#  4. unknown resource -> 404
#   5. recorded transition surfaces in current + list faces
#   6. api-version missing -> 400 MissingApiVersionParameter

defmodule Smalt.Integration.ResourceHealthTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Arm.ResourceHealth, as: Health
  alias Smalt.ArmGateway.Router

  @sub "00000000-0000-0000-0000-000000000000"
  @rg "rg-v9rh"
  @nsg "nsg-v9rh-#{System.system_time(:microsecond) |> Integer.to_string() |> String.slice(-8, 8)}"

  setup do
    put_rg =
      dispatch(:put, "/subscriptions/#{@sub}/resourceGroups/#{@rg}?api-version=2021-04-01", %{
        "location" => "eastus"
      })

    assert put_rg.status in [200, 201]

    put_nsg =
      dispatch(:put, nsg_path(), %{
        "location" => "eastus"
      })

    assert put_nsg.status in [200, 201]

    :ok
  end

  test "subscription-scope list: every provisioned resource Available, documented shape" do
    conn = dispatch(:get, list_path())

    assert conn.status == 200
    %{"value" => values} = Jason.decode!(conn.resp_body)
    assert is_list(values) and length(values) >= 1

    for row <- values do
      assert row["type"] == "Microsoft.ResourceHealth/availabilityStatuses"
      assert is_binary(row["id"]) and String.contains?(String.downcase(row["id"]), @sub)

      # Documented state vocabulary. A transition leg running earlier in the
      # same seed may add a Degraded row for its OWN resource — that is the
      # honest recompute through :smalt_arm_health, not pollution.
      assert row["properties"]["availabilityState"] in ["Available", "Degraded", "Unavailable"]
      assert is_binary(row["properties"]["summary"]) and row["properties"]["summary"] != ""
      assert is_binary(row["properties"]["occurredTime"])
    end

    # The shared @nsg carries no recorded transition, so its row MUST be
    # synthetic-Available (the law under test).
    nsg_row =
      Enum.find(values, fn row -> String.contains?(row["id"], @nsg) end)

    assert %{"properties" => %{"availabilityState" => "Available"}} = nsg_row
  end

  test "unknown subscription -> 404 SubscriptionNotFound" do
    conn = dispatch(:get, "/subscriptions/sub-does-not-exist-v9/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01")

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "SubscriptionNotFound"
  end

  test "per-resource current face: Available with nested properties" do
    conn = dispatch(:get, current_path())

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["type"] == "Microsoft.ResourceHealth/availabilityStatuses"
    assert body["properties"]["availabilityState"] == "Available"
    assert is_binary(body["properties"]["summary"])
    assert String.contains?(body["id"], "/providers/Microsoft.ResourceHealth/availabilityStatuses/current")
  end

  test "unknown resource -> 404" do
    conn =
      dispatch(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Network/networkSecurityGroups/nsg-missing-v9/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01"
      )

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "NotFound"
  end

  test "recorded transition surfaces in the current + history faces" do
    # Own resource: a recorded Degraded transition persists in :smalt_arm_health
    # ETS for the process lifetime, so this leg must never write to the shared
    # @nsg (order-independent court law).
    nsg = "nsg-v9rh-deg-#{System.system_time(:microsecond) |> Integer.to_string() |> String.slice(-8, 8)}"

    put =
      dispatch(:put, nsg_path(nsg), %{
        "location" => "eastus"
      })

    assert put.status in [200, 201]

    {:ok, rec} =
      Health.record_transition(
        @sub,
        @rg,
        "Microsoft.Network/networkSecurityGroups",
        nsg,
        "Degraded",
        "OperatorInitiated"
      )

    assert rec["availabilityState"] == "Degraded"

    current = dispatch(:get, current_path(nsg))
    assert current.status == 200
    body = Jason.decode!(current.resp_body)
    assert body["properties"]["availabilityState"] == "Degraded"

    history = dispatch(:get, resource_list_path(nsg))
    assert history.status == 200
    %{"value" => rows} = Jason.decode!(history.resp_body)
    assert length(rows) >= 1
    assert Enum.any?(rows, fn r -> r["properties"]["availabilityState"] == "Degraded" end)
  end

  test "api-version missing -> 400 MissingApiVersionParameter" do
    conn = dispatch(:get, "/subscriptions/#{@sub}/providers/Microsoft.ResourceHealth/availabilityStatuses")

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  # -- paths -------------------------------------------------------------------

  defp nsg_path(name \\ @nsg) do
    "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Network/networkSecurityGroups/#{name}?api-version=2021-04-01"
  end

  defp list_path do
    "/subscriptions/#{@sub}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01"
  end

  defp current_path(name \\ @nsg) do
    "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Network/networkSecurityGroups/#{name}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01"
  end

  defp resource_list_path(name \\ @nsg) do
    "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Network/networkSecurityGroups/#{name}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01"
  end

  defp dispatch(method, path, body \\ nil) do
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

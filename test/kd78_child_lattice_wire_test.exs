defmodule Smalt.Kd78ChildLatticeWireTest do
  @moduledoc """
  KD-78 monotonic-pattern wire fence for the child-type lattice tops bumped
  this lane: `Microsoft.ServiceBus/namespaces/queues` and
  `Microsoft.EventHub/namespaces/eventhubs` now cap at the witnessed
  azurerm 4.54 child-PUT version 2024-01-01 (witness: tf-cleanroom apply
  + tf-plan-probe InvalidApiVersionParameter receipts naming 2024-01-01
  vs cap 2021-04-01).

  Contract:
    - SB queue child PUT at api-version 2024-01-01 -> admitted (2xx)
    - EH eventhub child PUT at api-version 2024-01-01 -> admitted (2xx)
    - both types at a version NEWER than the latest -> 400
      InvalidApiVersionParameter naming Registry.latest_version/1
    - older versions stay admitted (monotonic <= law)
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry
  alias Smalt.Store

  @opts Router.init([])

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    :ok
  end

  describe "SB queue child lattice top (KD-78 monotonic pattern)" do
    @tag kd78_child_lattice: true
    test "SB queue child PUT at 2024-01-01 -> admitted (2xx)" do
      sb_put_ns("sbq-lat-ns")
      path = child_path(:sb_queue, "sbq-lat-ns", "q-2024")

      conn = put_child(path, "2024-01-01")

      assert conn.status in [200, 201],
             "expected 2024-01-01 admitted for queues, got #{conn.status}: #{conn.resp_body}"

      assert body(conn)["type"] == "Microsoft.ServiceBus/namespaces/queues"
    end

    @tag kd78_child_lattice: true
    test "SB queue child PUT at 2021-04-01 (older) still admitted — monotonic law" do
      sb_put_ns("sbq-old-ns")
      path = child_path(:sb_queue, "sbq-old-ns", "q-old")

      conn = put_child(path, "2021-04-01")

      assert conn.status in [200, 201],
             "expected 2021-04-01 still admitted, got #{conn.status}: #{conn.resp_body}"
    end

    @tag kd78_child_lattice: true
    test "SB queue child PUT at 2099-01-01 (newer) -> 400 InvalidApiVersionParameter naming latest" do
      sb_put_ns("sbq-new-ns")
      path = child_path(:sb_queue, "sbq-new-ns", "q-future")

      conn = put_child(path, "2099-01-01")

      assert conn.status == 400
      assert body(conn)["error"]["code"] == "InvalidApiVersionParameter"

      assert body(conn)["error"]["message"] =~
               Registry.latest_version("Microsoft.ServiceBus/namespaces/queues")
    end
  end

  describe "EH eventhub child lattice top (KD-78 monotonic pattern)" do
    @tag kd78_child_lattice: true
    test "EH eventhub child PUT at 2024-01-01 -> admitted (2xx)" do
      eh_put_ns("ehh-lat-ns")
      path = child_path(:eh_hub, "ehh-lat-ns", "hub-2024")

      conn = put_child(path, "2024-01-01")

      assert conn.status in [200, 201],
             "expected 2024-01-01 admitted for eventhubs, got #{conn.status}: #{conn.resp_body}"

      assert body(conn)["type"] == "Microsoft.EventHub/namespaces/eventhubs"
    end

    @tag kd78_child_lattice: true
    test "EH eventhub child PUT at 2021-04-01 (older) still admitted — monotonic law" do
      eh_put_ns("ehh-old-ns")
      path = child_path(:eh_hub, "ehh-old-ns", "hub-old")

      conn = put_child(path, "2021-04-01")

      assert conn.status in [200, 201],
             "expected 2021-04-01 still admitted, got #{conn.status}: #{conn.resp_body}"
    end

    @tag kd78_child_lattice: true
    test "EH eventhub child PUT at 2099-01-01 (newer) -> 400 InvalidApiVersionParameter naming latest" do
      eh_put_ns("ehh-new-ns")
      path = child_path(:eh_hub, "ehh-new-ns", "hub-future")

      conn = put_child(path, "2099-01-01")

      assert conn.status == 400
      assert body(conn)["error"]["code"] == "InvalidApiVersionParameter"

      assert body(conn)["error"]["message"] =~
               Registry.latest_version("Microsoft.EventHub/namespaces/eventhubs")
    end
  end

  # -- helpers -------------------------------------------------------------------

  defp child_path(:sb_queue, ns, name),
    do: "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}/queues/#{name}"

  defp child_path(:eh_hub, ns, name),
    do: "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventHub/namespaces/#{ns}/eventhubs/#{name}"

  defp put_child(path, ver) do
    conn(:put, path <> "?api-version=#{ver}", %{
      "location" => "eastus",
      "properties" => %{}
    })
    |> Router.call(@opts)
  end

  defp sb_put_ns(ns) do
    conn(
      :put,
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}?api-version=2024-01-01",
      %{"location" => "eastus", "properties" => %{"skuName" => "Standard"}}
    )
    |> Router.call(@opts)
    |> then(fn c ->
      assert c.status in [200, 201], "SB namespace seed failed: #{c.status} #{c.resp_body}"
      c
    end)
  end

  defp eh_put_ns(ns) do
    conn(
      :put,
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventHub/namespaces/#{ns}?api-version=2024-01-01",
      %{"location" => "eastus", "properties" => %{"isAutoInflateEnabled" => false}}
    )
    |> Router.call(@opts)
    |> then(fn c ->
      assert c.status in [200, 201], "EH namespace seed failed: #{c.status} #{c.resp_body}"
      c
    end)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
end

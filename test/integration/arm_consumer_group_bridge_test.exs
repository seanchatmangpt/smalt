defmodule Smalt.Internal.ArmConsumerGroupBridgeTest do
  use ExUnit.Case, async: false

  # W2J witness (b7 enforce): the ARM plane consumer-group routes delegate to
  # the wave-1 engine. Over real dispatch (Plug.Router.call in-process, auth
  # :anonymous in the test env):
  #
  #   ARM PUT consumergroup -> 201 -> engine consumer_group_exists? true
  #   ARM GET  -> 200 (engine-backed envelope with engine created-ts)
  #   ARM re-PUT preserves the engine created-ts (ARM PUT idempotency law)
  #   ARM DELETE -> 200 -> engine consumer_group_exists? false
  #   ARM DELETE $default -> 409 ConsumerGroupNotDeletable (engine face)
  #
  # Context: solo (internal tier, in-process dispatch).

  import Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Messaging.EventHubs
  alias Smalt.Store

  @not_found 404
  @not_deletable 409

  @api_version "2021-04-01"
  @rg "/subscriptions/sub-w2j/resourceGroups/rg-w2j"
  @ns "ns-w2j"
  @hub "hub-w2j"
  @cg_type "Microsoft.EventHub/namespaces/eventhubs/consumergroups"

  setup do
    EventHubs.ensure_tables()

    # Parent gate: seed the namespace and eventhub the way the generic ARM
    # resource PUT stores them (providers/-prefixed key).
    ns_key = String.downcase("#{@rg}/providers/Microsoft.EventHub/namespaces/#{@ns}")

    hub_key =
      String.downcase(
        "#{@rg}/providers/Microsoft.EventHub/namespaces/#{@ns}/eventhubs/#{@hub}"
      )

    Store.put(:smalt_resources, ns_key, %{
      "id" => "#{@rg}/providers/Microsoft.EventHub/namespaces/#{@ns}",
      "name" => @ns,
      "type" => "Microsoft.EventHub/namespaces",
      "properties" => %{}
    })

    Store.put(:smalt_resources, hub_key, %{
      "id" => "#{@rg}/providers/Microsoft.EventHub/namespaces/#{@ns}/eventhubs/#{@hub}",
      "name" => @hub,
      "type" => "Microsoft.EventHub/namespaces/eventhubs",
      "properties" => %{}
    })

    :ok
  end

  defp arm_req(method, path, body \\ nil) do
    url = "#{path}?api-version=#{@api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp cg_url(name \\ "cg-w2j") do
    "#{@rg}/providers/Microsoft.EventHub/namespaces/#{@ns}/eventhubs/#{@hub}/consumergroups/#{name}"
  end

  test "ARM PUT 201 -> engine exists -> GET 200 -> DELETE -> engine gone" do
    put_conn = arm_req(:put, cg_url(), %{"location" => "eastus", "properties" => %{"userMetadata" => "w2j"}})
    assert put_conn.status == 201
    assert EventHubs.consumer_group_exists?(@hub, "cg-w2j")

    get_conn = arm_req(:get, cg_url())
    assert get_conn.status == 200

    body = Jason.decode!(get_conn.resp_body)
    assert body["name"] == "cg-w2j"
    assert body["type"] == @cg_type
    assert body["properties"]["createdAt"]

    # Engine created-ts preserved across ARM re-PUT (engine idempotency law).
    {:ok, rec1} = EventHubs.get_consumer_group(@hub, "cg-w2j")
    reput_conn = arm_req(:put, cg_url(), %{"location" => "eastus", "properties" => %{"userMetadata" => "v2"}})
    assert reput_conn.status in [200, 201]
    {:ok, rec2} = EventHubs.get_consumer_group(@hub, "cg-w2j")
    assert rec2["created"] == rec1["created"]

    del_conn = arm_req(:delete, cg_url())
    assert del_conn.status == 200
    refute EventHubs.consumer_group_exists?(@hub, "cg-w2j")

    # Unknown group over ARM dispatch answers the typed 404 face.
    missing = arm_req(:delete, cg_url("cg-w2j-missing"))
    assert missing.status == @not_found
    assert Jason.decode!(missing.resp_body)["error"]["code"] == "ConsumerGroupNotFound"
  end

  test "$default cannot be deleted over ARM (engine 409 face)" do
    default_del = arm_req(:delete, cg_url("$default"))

    assert default_del.status == @not_deletable

    assert Jason.decode!(default_del.resp_body)["error"]["code"] ==
             "ConsumerGroupNotDeletable"
  end
end

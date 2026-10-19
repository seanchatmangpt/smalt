defmodule Smalt.SbChildrenTest do
  @moduledoc """
  azurerm child-resource parity for messaging: ServiceBus queues/topics/
  subscriptions and EventHub eventhubs/consumergroups as ARM children
  (azurerm 4.54 wire form .../namespaces/:ns/{queues,topics,eventhubs}/...).

  Each child type gets a full lifecycle: api-version requirement, invalid
  api-version, 404 ResourceNotFound on missing parent namespace, PUT 201 -> PUT
  200, GET carries entity properties, LIST via Store.list_prefix, DELETE ->
  GET 404. Also covers the nested-provider diagnosticSettings route arm and
  the .../lock If-Match precondition.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])

  setup do
    ensure_store()
    Store.clear()
    :ok
  end

  # -- ServiceBus queues ---------------------------------------------------------

  describe "ServiceBus queues" do
    @tag sb_children: "queue-lifecycle"
    test "full lifecycle: 201 PUT, 200 re-PUT, GET, LIST, DELETE, GET 404" do
      put_ns("sbns1")
      path = sb_path("sbns1", "queues", "q1")
      props = %{"requiresSession" => true, "lockDuration" => "PT1M", "maxDeliveryCount" => 10}

      conn =
        conn(:put, path <> "?api-version=2021-04-01", %{
          "location" => "eastus",
          "properties" => props
        })
        |> Router.call(@opts)

      assert conn.status == 201
      record = body(conn)
      assert record["type"] == "Microsoft.ServiceBus/namespaces/queues"
      assert record["name"] == "q1"
      assert record["properties"]["requiresSession"] == true
      assert record["properties"]["lockDuration"] == "PT1M"
      assert record["properties"]["maxDeliveryCount"] == 10

      reconn =
        conn(:put, path <> "?api-version=2021-04-01", %{
          "location" => "eastus",
          "properties" => props
        })
        |> Router.call(@opts)

      assert reconn.status == 200

      get_conn = conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert get_conn.status == 200
      # id follows the landed subnet/container child pattern: rg + rel path
      # (no /providers/ segment), matching handle_child_put's record shape.
      assert body(get_conn)["id"] ==
               "/subscriptions/sub-1/resourceGroups/rg-1/namespaces/sbns1/queues/q1"

      list_conn =
        conn(:get, sb_list_path("sbns1", "queues") <> "?api-version=2021-04-01")
        |> Router.call(@opts)

      assert list_conn.status == 200
      names = Enum.map(body(list_conn)["value"], & &1["name"])
      assert "q1" in names

      del_conn = conn(:delete, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert del_conn.status == 200

      gone = conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {gone.status, code(gone)}
    end

    @tag sb_children: "queue-api-version"
    test "missing api-version -> 400 MissingApiVersionParameter" do
      put_ns("sbns2")

      conn =
        conn(:put, sb_path("sbns2", "queues", "q9"), %{"location" => "eastus"})
        |> Router.call(@opts)

      assert {400, "MissingApiVersionParameter"} = {conn.status, code(conn)}
    end

    @tag sb_children: "queue-api-version"
    test "stale api-version admits monotonically; > latest -> 400 InvalidApiVersionParameter" do
      put_ns("sbns3")

      # KD-78 monotonic admission (fenced in test/api_version_admission_test.exs):
      # stale but parseable versions admit normally.
      stale_conn =
        conn(:put, sb_path("sbns3", "queues", "q9") <> "?api-version=1999-01-01", %{
          "location" => "eastus"
        })
        |> Router.call(@opts)

      assert {201, nil} = {stale_conn.status, code(stale_conn)}

      # Only a version NEWER than the registry latest refuses.
      future_conn =
        conn(:put, sb_path("sbns3", "queues", "q9f") <> "?api-version=2099-01-01", %{
          "location" => "eastus"
        })
        |> Router.call(@opts)

      assert {400, "InvalidApiVersionParameter"} = {future_conn.status, code(future_conn)}
    end

    @tag sb_children: "queue-missing-parent"
    test "404 ResourceNotFound on PUT/GET/LIST/DELETE under a missing parent namespace" do
      path = sb_path("ghostns", "queues", "q1")

      put_conn =
        conn(:put, path <> "?api-version=2021-04-01", %{"location" => "eastus"})
        |> Router.call(@opts)

      assert {404, "ResourceNotFound"} = {put_conn.status, code(put_conn)}

      get_conn = conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {get_conn.status, code(get_conn)}

      list_conn =
        conn(:get, sb_list_path("ghostns", "queues") <> "?api-version=2021-04-01")
        |> Router.call(@opts)

      assert {404, "ResourceNotFound"} = {list_conn.status, code(list_conn)}

      del_conn = conn(:delete, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {del_conn.status, code(del_conn)}
    end
  end

  # -- ServiceBus topics + subscriptions ------------------------------------------

  describe "ServiceBus topics and subscriptions" do
    @tag sb_children: "topic-lifecycle"
    test "topic lifecycle: 201, GET, LIST, DELETE" do
      put_ns("sbns4")
      path = sb_path("sbns4", "topics", "t1")

      conn =
        conn(:put, path <> "?api-version=2021-04-01", %{
          "location" => "eastus",
          "properties" => %{"maxSizeInMegabytes" => 1024}
        })
        |> Router.call(@opts)

      assert conn.status == 201
      assert body(conn)["type"] == "Microsoft.ServiceBus/namespaces/topics"
      assert body(conn)["properties"]["maxSizeInMegabytes"] == 1024

      assert conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> ok?()
      assert list_contains?(sb_list_path("sbns4", "topics"), "t1")

      assert conn(:delete, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> status() ==
               200

      gone = conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {gone.status, code(gone)}
    end

    @tag sb_children: "subscription-lifecycle"
    test "subscription lifecycle under topic parent" do
      put_ns("sbns5")
      put_child("sbns5", "topics", "t1")
      path = sb_path("sbns5", "topics/t1/subscriptions", "s1")

      conn =
        conn(:put, path <> "?api-version=2021-04-01", %{
          "location" => "eastus",
          "properties" => %{"maxDeliveryCount" => 5, "lockDuration" => "PT30S"}
        })
        |> Router.call(@opts)

      assert conn.status == 201
      assert body(conn)["type"] == "Microsoft.ServiceBus/namespaces/topics/subscriptions"
      assert body(conn)["properties"]["maxDeliveryCount"] == 5

      assert conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> ok?()
      assert list_contains?(sb_list_path("sbns5", "topics/t1/subscriptions"), "s1")

      assert conn(:delete, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> status() ==
               200

      gone = conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {gone.status, code(gone)}
    end

    @tag sb_children: "subscription-missing-parent"
    test "404 when parent topic is missing" do
      put_ns("sbns6")

      conn =
        conn(
          :put,
          sb_path("sbns6", "topics/t1/subscriptions", "s1") <> "?api-version=2021-04-01",
          %{
            "location" => "eastus"
          }
        )
        |> Router.call(@opts)

      assert {404, "ResourceNotFound"} = {conn.status, code(conn)}
    end
  end

  # -- EventHub eventhubs + consumergroups -----------------------------------------

  describe "EventHub eventhubs and consumergroups" do
    @tag eh_children: "eventhub-lifecycle"
    test "eventhub lifecycle: 201, GET, LIST, DELETE" do
      put_eh_ns("ehns1")
      path = eh_path("ehns1", "eventhubs", "hub1")

      conn =
        conn(:put, path <> "?api-version=2021-04-01", %{
          "location" => "eastus",
          "properties" => %{"partitionCount" => 4, "messageRetentionInDays" => 1}
        })
        |> Router.call(@opts)

      assert conn.status == 201
      assert body(conn)["type"] == "Microsoft.EventHub/namespaces/eventhubs"
      assert body(conn)["properties"]["partitionCount"] == 4

      assert conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> ok?()
      assert list_contains?(eh_list_path("ehns1", "eventhubs"), "hub1")

      assert conn(:delete, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> status() ==
               200

      gone = conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {gone.status, code(gone)}
    end

    @tag eh_children: "consumergroup-lifecycle"
    test "consumergroup lifecycle under eventhub parent" do
      put_eh_ns("ehns2")
      put_eh_child("ehns2", "eventhubs", "hub1")
      path = eh_path("ehns2", "eventhubs/hub1/consumergroups", "cg1")

      conn =
        conn(:put, path <> "?api-version=2021-04-01", %{
          "location" => "eastus",
          "properties" => %{"userMetadata" => "dev"}
        })
        |> Router.call(@opts)

      assert conn.status == 201
      assert body(conn)["type"] == "Microsoft.EventHub/namespaces/eventhubs/consumergroups"

      assert conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> ok?()
      assert list_contains?(eh_list_path("ehns2", "eventhubs/hub1/consumergroups"), "cg1")

      assert conn(:delete, path <> "?api-version=2021-04-01") |> Router.call(@opts) |> status() ==
               200

      gone = conn(:get, path <> "?api-version=2021-04-01") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {gone.status, code(gone)}
    end

    @tag eh_children: "consumergroup-list-default"
    test "consumergroup LIST always carries $default; hub with 2 CGs lists 3" do
      put_eh_ns("ehns3")
      put_eh_child("ehns3", "eventhubs", "hubd")
      put_eh_child("ehns3", "eventhubs/hubd/consumergroups", "cg-a")
      put_eh_child("ehns3", "eventhubs/hubd/consumergroups", "cg-b")

      list_conn =
        conn(
          :get,
          eh_list_path("ehns3", "eventhubs/hubd/consumergroups") <> "?api-version=2021-04-01"
        )
        |> Router.call(@opts)

      assert list_conn.status == 200
      value = body(list_conn)["value"]
      names = Enum.map(value, & &1["name"])
      assert Enum.sort(names) == ["$default", "cg-a", "cg-b"]

      default = Enum.find(value, &(&1["name"] == "$default"))
      assert default["type"] == "Microsoft.EventHub/namespaces/eventhubs/consumergroups"

      assert default["id"] ==
               "/subscriptions/sub-1/resourceGroups/rg-1/namespaces/ehns3/eventhubs/hubd/consumergroups/$default"

      assert is_map(default["properties"])

      # empty hub: value is exactly [$default]
      put_eh_child("ehns3", "eventhubs", "hub-empty")

      empty_conn =
        conn(
          :get,
          eh_list_path("ehns3", "eventhubs/hub-empty/consumergroups") <> "?api-version=2021-04-01"
        )
        |> Router.call(@opts)

      assert empty_conn.status == 200
      assert [%{"name" => "$default"}] = body(empty_conn)["value"]
    end

    @tag eh_children: "eventhub-missing-parent"
    test "404 when parent namespace is missing" do
      conn =
        conn(:put, eh_path("ghosteh", "eventhubs", "hub1") <> "?api-version=2021-04-01", %{
          "location" => "eastus"
        })
        |> Router.call(@opts)

      assert {404, "ResourceNotFound"} = {conn.status, code(conn)}
    end
  end

  # -- Nested-provider diagnosticSettings (lane 70 addition) ------------------------

  describe "nested-provider diagnosticSettings" do
    @tag diags_nested: "put-get-delete"
    test "PUT/GET/DELETE at arbitrary depth under a storageAccount" do
      put_sa("sa1")
      path = sa_diags_path("sa1", "ds1")

      conn =
        conn(:put, path <> "?api-version=2021-05-01-preview", %{
          "location" => "global",
          "properties" => %{"eventHubName" => "eh-1"}
        })
        |> Router.call(@opts)

      assert conn.status == 201
      record = body(conn)
      assert record["type"] == "Microsoft.Insights/diagnosticSettings"
      assert record["name"] == "ds1"
      assert record["properties"]["eventHubName"] == "eh-1"

      get_conn = conn(:get, path <> "?api-version=2021-05-01-preview") |> Router.call(@opts)
      assert get_conn.status == 200
      assert body(get_conn)["properties"]["eventHubName"] == "eh-1"

      del_conn = conn(:delete, path <> "?api-version=2021-05-01-preview") |> Router.call(@opts)
      assert del_conn.status == 200

      gone = conn(:get, path <> "?api-version=2021-05-01-preview") |> Router.call(@opts)
      assert {404, "ResourceNotFound"} = {gone.status, code(gone)}
    end

    @tag diags_nested: "route-not-found"
    test "non-diagnosticSettings glob falls through to RouteNotFound" do
      conn =
        conn(
          :delete,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa-x/providers/Microsoft.Fake/deep/path?api-version=2021-04-01"
        )
        |> Router.call(@opts)

      assert {404, "RouteNotFound"} = {conn.status, code(conn)}
    end
  end

  # -- azapi lock If-Match precondition ----------------------------------------------

  describe "azapi lock If-Match precondition" do
    @tag azapi_lock: "if-match-required"
    test "POST lock without If-Match -> 412 PreconditionFailed" do
      put_policy()

      conn = conn(:post, lock_path()) |> Router.call(@opts)
      assert conn.status == 412
      assert body(conn)["error"]["code"] == "PreconditionFailed"
    end

    @tag azapi_lock: "if-match-present"
    test "POST lock with If-Match -> 200 lock envelope" do
      put_policy()

      # The precondition is value-verified (V261014-20): the header must carry
      # the deterministic policy etag over the REQUEST PATH (no query string —
      # that is what conn.request_path carries on the wire).
      conn =
        conn(:post, lock_path())
        |> put_req_header(
          "if-match",
          Smalt.ArmGateway.Router.lock_policy_etag(
            String.replace_trailing(lock_path(), "?api-version=2023-05-01", "")
          )
        )
        |> Router.call(@opts)

      assert conn.status == 200
      assert body(conn)["type"] == "Microsoft.Authorization/locks"
    end
  end

  # -- Helpers ------------------------------------------------------------------------

  # Guarantee the shared Store is alive: other suites stop the main app tree
  # to run private trees; on_exit restores it, but never assume run order.
  defp ensure_store do
    SmaltTest.Lifecycle.ensure_store_up()
  end

  defp sb_path(ns, leaf, name),
    do:
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}/#{leaf}/#{name}"

  defp sb_list_path(ns, leaf),
    do:
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}/#{leaf}"

  defp eh_path(ns, leaf, name),
    do:
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventHub/namespaces/#{ns}/#{leaf}/#{name}"

  defp eh_list_path(ns, leaf),
    do:
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventHub/namespaces/#{ns}/#{leaf}"

  defp sa_diags_path(sa, name),
    do:
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/#{sa}/providers/Microsoft.Insights/diagnosticSettings/#{name}"

  defp lock_path do
    "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa-1/blobServices/default/containers/c-1/immutabilityPolicies/default/lock?api-version=2023-05-01"
  end

  defp put_ns(ns) do
    conn(
      :put,
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}?api-version=2021-04-01",
      %{"location" => "eastus", "properties" => %{"skuName" => "Standard"}}
    )
    |> Router.call(@opts)
    |> assert_status(201)
  end

  defp put_eh_ns(ns) do
    conn(
      :put,
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventHub/namespaces/#{ns}?api-version=2021-04-01",
      %{"location" => "eastus", "properties" => %{"skuName" => "Standard"}}
    )
    |> Router.call(@opts)
    |> assert_status(201)
  end

  defp put_child(ns, leaf, name) do
    conn(:put, sb_path(ns, leaf, name) <> "?api-version=2021-04-01", %{"location" => "eastus"})
    |> Router.call(@opts)
    |> assert_status(201)
  end

  defp put_eh_child(ns, leaf, name) do
    conn(:put, eh_path(ns, leaf, name) <> "?api-version=2021-04-01", %{"location" => "eastus"})
    |> Router.call(@opts)
    |> assert_status(201)
  end

  defp put_sa(sa) do
    conn(
      :put,
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/#{sa}?api-version=2021-04-01",
      %{"location" => "eastus", "properties" => %{"skuName" => "Standard_LRS"}}
    )
    |> Router.call(@opts)
    # storageAccount PUT rides LRO: 202 Accepted with an operation path
    |> assert_status(202)
  end

  defp put_policy do
    put_sa("sa-1")

    conn(
      :put,
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/sa-1/blobServices/default/containers/c-1?api-version=2023-05-01",
      %{"location" => "eastus"}
    )
    |> Router.call(@opts)
    |> assert_status(201)
  end

  defp assert_status(conn, want) do
    assert conn.status == want, "expected #{want}, got #{conn.status}: #{conn.resp_body}"
    conn
  end

  defp ok?(conn), do: conn.status == 200

  defp status(conn), do: conn.status

  defp list_contains?(list_path, name) do
    conn = conn(:get, list_path <> "?api-version=2021-04-01") |> Router.call(@opts)
    assert conn.status == 200
    name in Enum.map(body(conn)["value"], & &1["name"])
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp code(conn), do: body(conn)["error"]["code"]
end

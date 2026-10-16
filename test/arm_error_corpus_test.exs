defmodule Smalt.ArmErrorCorpusTest do
  @moduledoc """
  Table-driven conformance corpus pinning EVERY ARM error path
  `Smalt.ArmGateway.Router` can emit, plus one success-envelope row.

  Each row drives a minimal Plug.Test request against the REAL router and
  asserts {status, error.code, target presence} exactly. Every row cites the
  router file:line of the `send_arm_error` / refusal call site it pins.
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

  # -- Corpus rows -------------------------------------------------------------

  describe "ARM error corpus" do
    @tag corpus: "MissingApiVersionParameter"
    test "400 MissingApiVersionParameter on PUT without api-version" do
      # lib/smalt/arm_gateway/router.ex:402 (check_api_version nil branch)
      conn =
        conn(:put, "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1", %{
          "location" => "smalt-local"
        })
        |> Router.call(@opts)

      assert {400, "MissingApiVersionParameter"} = {conn.status, code(conn)}
      refute Map.has_key?(body(conn)["error"], "target")
    end

    @tag corpus: "InvalidApiVersionParameter"
    test "400 InvalidApiVersionParameter on stale api-version for admitted type" do
      # lib/smalt/arm_gateway/router.ex:422-429 (check_version mismatch branch)
      path =
        "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1?api-version=1999-01-01"

      conn =
        conn(:put, path, %{"location" => "smalt-local"})
        |> Router.call(@opts)

      assert {400, "InvalidApiVersionParameter"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "1999-01-01"
      refute Map.has_key?(body(conn)["error"], "target")
    end

    @tag corpus: "ResourceGroupNotFound"
    test "404 ResourceGroupNotFound on GET of a missing resource group" do
      # lib/smalt/arm_gateway/router.ex:214 (handle_rg_get :error branch)
      conn =
        conn(:get, "/subscriptions/sub-1/resourceGroups/nope-rg?api-version=2021-04-01")
        |> Router.call(@opts)

      assert {404, "ResourceGroupNotFound"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "nope-rg"
    end

    @tag corpus: "SubscriptionNotFound"
    test "404 SubscriptionNotFound on GET of a missing subscription" do
      # lib/smalt/arm_gateway/router.ex:566 (GET /subscriptions/:sub_id :error branch)
      conn =
        conn(:get, "/subscriptions/sub-missing?api-version=2021-04-01")
        |> Router.call(@opts)

      assert {404, "SubscriptionNotFound"} = {conn.status, code(conn)}
    end

    @tag corpus: "ResourceNotFound"
    test "404 ResourceNotFound on GET of a missing top-level resource" do
      # lib/smalt/arm_gateway/router.ex:273 (handle_resource_get :error branch)
      conn =
        conn(
          :get,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventGrid/topics/ghost?api-version=2021-04-01"
        )
        |> Router.call(@opts)

      assert {404, "ResourceNotFound"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "ghost"
    end

    @tag corpus: "ResourceNotFound-child"
    test "404 ResourceNotFound on GET of a missing child resource" do
      # lib/smalt/arm_gateway/router.ex:316 (handle_child_get :error branch)
      conn =
        conn(
          :get,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Network/virtualNetworks/vnet-x/subnets/sub-x?api-version=2021-04-01"
        )
        |> Router.call(@opts)

      assert {404, "ResourceNotFound"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "sub-x"
    end

    @tag corpus: "InvalidResourceShape-shape-invalid"
    test "400 InvalidResourceShape (target AshGraphLaw.Enforcement) on shape-invalid PUT" do
      # lib/smalt/arm_gateway/router.ex:461 -> :167-180 send_graphlaw_refusal
      # (check_shape {:invalid, issues} branch; VNetShape requires 2 properties)
      conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Network/virtualNetworks/vnet-1?api-version=2021-04-01",
          %{"garbage" => true}
        )
        |> Router.call(@opts)

      assert {400, "InvalidResourceShape"} = {conn.status, code(conn)}
      assert target(conn) == "AshGraphLaw.Enforcement"
      assert body(conn)["error"]["message"] =~ "GraphLaw validation failure"
    end

    @tag corpus: "InvalidResourceShape-unadmitted"
    test "400 InvalidResourceShape (target AshGraphLaw.Enforcement) on unadmitted-type PUT" do
      # lib/smalt/arm_gateway/router.ex:437 -> :167-180 send_graphlaw_refusal
      # (check_admitted nil branch; ARM never returns 422 — refusal pinned at 400)
      conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Fake/things/thing-1?api-version=2021-04-01",
          %{"location" => "smalt-local"}
        )
        |> Router.call(@opts)

      assert {400, "InvalidResourceShape"} = {conn.status, code(conn)}
      assert target(conn) == "AshGraphLaw.Enforcement"
      assert body(conn)["error"]["message"] =~ "not an admitted ontology individual"
    end

    @tag corpus: "RouteNotFound"
    test "404 RouteNotFound on unknown path" do
      # lib/smalt/arm_gateway/router.ex:796 (catch-all match _)
      conn =
        conn(:get, "/definitely/not/a/route")
        |> Router.call(@opts)

      assert {404, "RouteNotFound"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "/definitely/not/a/route"
    end

    @tag corpus: "ActionNotFound"
    test "404 ActionNotFound on a POST to a non-action provider path" do
      # lib/smalt/arm_gateway/router.ex:358 (handle_action, action not in @actions)
      conn =
        conn(
          :post,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Compute/virtualMachines/vm-1/notanaction?api-version=2021-04-01"
        )
        |> Router.call(@opts)

      assert {404, "ActionNotFound"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "notanaction"
    end

    @tag corpus: "OperationNotFound"
    test "404 OperationNotFound on GET of an unknown LRO operation id" do
      # lib/smalt/arm_gateway/router.ex:578 (LRO polling :error branch)
      conn =
        conn(:get, "/subscriptions/sub-1/operations/deadbeef0000?api-version=2021-04-01")
        |> Router.call(@opts)

      assert {404, "OperationNotFound"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "deadbeef0000"
    end

    @tag corpus: "LRO-async"
    test "LRO PUT returns 202 with Azure-AsyncOperation header; polling yields 200 Succeeded" do
      # lib/smalt/arm_gateway/router.ex:244-251 (lro_type? 202 branch) and
      # lib/smalt/arm_gateway/router.ex:571-575 (operations polling, 200 on Succeeded)
      conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/lroacct?api-version=2021-04-01",
          %{"location" => "smalt-local", "properties" => %{"skuName" => "standard"}}
        )
        |> Router.call(@opts)

      assert conn.status == 202
      assert [async_url] = Plug.Conn.get_resp_header(conn, "azure-asyncoperation")
      assert async_url =~ "/subscriptions/sub-1/operations/"

      op_path = async_url |> URI.parse() |> Map.fetch!(:path)

      op = poll_until_succeeded(op_path)

      assert op["status"] == "Succeeded"
      assert is_binary(op["name"])
    end

    @tag corpus: "success-envelope"
    test "success envelope: resource GET carries id/name/type/location/properties.provisioningState" do
      # lib/smalt/arm_gateway/router.ex:231-238 (record shape) via :254/:257 PUT,
      # and :270 (handle_resource_get 200 with the stored record)
      put_conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventGrid/topics/topic-1?api-version=2021-04-01",
          %{"location" => "eastus", "properties" => %{"retentionInDays" => "1"}}
        )
        |> Router.call(@opts)

      assert put_conn.status == 201

      get_conn =
        conn(
          :get,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.EventGrid/topics/topic-1?api-version=2021-04-01"
        )
        |> Router.call(@opts)

      assert get_conn.status == 200

      record = body(get_conn)
      assert is_binary(record["id"]) and record["id"] =~ "/providers/Microsoft.EventGrid/topics/topic-1"
      assert record["name"] == "topic-1"
      assert record["type"] == "Microsoft.EventGrid/topics"
      assert record["location"] == "eastus"
      assert record["properties"]["provisioningState"] == "Succeeded"
    end
  end

  # -- Corpus completeness: every send_arm_error / refusal site has a row ------

  test "corpus covers every send_arm_error code emitted by the router" do
    source = File.read!("lib/smalt/arm_gateway/router.ex")

    emitted =
      Regex.scan(~r/send_arm_error\(\s*conn,\s*(\d+),\s*"([A-Za-z]+)"/s, source)
      |> Enum.map(fn [_, status, code] -> {String.to_integer(status), code} end)
      |> Enum.sort()
      |> Enum.uniq()

    assert emitted == [
             {400, "InvalidApiVersionParameter"},
             {400, "MissingApiVersionParameter"},
             {404, "ActionNotFound"},
             {404, "OperationNotFound"},
             {404, "ResourceGroupNotFound"},
             {404, "ResourceNotFound"},
             {404, "RouteNotFound"},
             {404, "SubscriptionNotFound"}
           ]
  end

  # -- Wire-court shape-consistency (xaas prior-art import, lens-5 cycle 2) -----
  # The router has THREE distinct envelope emit paths — send_arm_error/5,
  # send_graphlaw_refusal/2 and the inline throttled/1 (429) — and the wire
  # must not distinguish them by shape (xaas wire-parity §4.6 pattern): every
  # refusal is a map-shaped `error` with string code + message and the ARM
  # present-but-empty innererror, target present IFF the refusal is a GraphLaw
  # one. One court, three sources, one shape.
  describe "envelope shape-consistency across emit paths" do
    test "send_arm_error, send_graphlaw_refusal and inline 429 emit one consistent envelope shape" do
      arm_error =
        conn(:get, "/definitely/not/a/route")
        |> Router.call(@opts)

      graphlaw =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Fake/things/thing-1?api-version=2021-04-01",
          %{"location" => "smalt-local"}
        )
        |> Router.call(@opts)

      # Deterministic 429: seed the current window at its limit via the prior
      # window's key, then spend it (same scoping as the gateway throttle test:
      # fresh-window wait + seed + cleanup, so no stray 429 leaks to adjacent
      # suites in the same run).
      throttled =
        try do
          Application.put_env(:smalt, :arm_rate_limit, 3)
          wait_for_fresh_window()

          now = div(System.system_time(:millisecond), 1000)

          :ets.insert(
            Router.rate_table_for_test(),
            {{:smalt_arm_rate, now - 1}, 99}
          )

          1..4
          |> Enum.reduce(nil, fn _, _ ->
            conn(:get, "/subscriptions/sub-1?api-version=2021-04-01") |> Router.call(@opts)
          end)
        after
          Application.put_env(:smalt, :arm_rate_limit, nil)
          :ets.delete_all_objects(:smalt_arm_rate)
        end

      assert arm_error.status == 404
      assert graphlaw.status == 400
      assert throttled.status == 429

      envelope = fn c ->
        Jason.decode!(c.resp_body)["error"]
      end

      for {conn, kind} <- [{arm_error, :arm}, {graphlaw, :graphlaw}, {throttled, :throttle}] do
        err = envelope.(conn)

        assert is_map(err), "envelope from #{kind} is not a map"

        assert is_binary(err["code"]) and is_binary(err["message"]),
               "envelope from #{kind} lacks string code/message"

        assert match?(%{}, err["innererror"]),
               "envelope from #{kind} lacks the present-but-empty innererror"

        # HTTP-layer consistency: every refusal is JSON.
        assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() |> String.starts_with?("application/json")
      end

      # target: a string whenever present (GraphLaw pins the enforcement
      # target; the catch-all RouteNotFound pins the request path), and the
      # throttle envelope carries none.
      assert is_binary(envelope.(graphlaw)["target"])
      assert is_binary(envelope.(arm_error)["target"])
      refute Map.has_key?(envelope.(throttled), "target")
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp wait_for_fresh_window do
    now = div(System.system_time(:millisecond), 1000)

    if System.system_time(:millisecond) - now * 1000 > 800 do
      Process.sleep(300)
    end
  end

  defp poll_until_succeeded(path, attempts \\ 50)

  defp poll_until_succeeded(_path, 0), do: flunk("LRO never reached Succeeded")

  defp poll_until_succeeded(path, attempts) do
    conn = conn(:get, path) |> Router.call(@opts)
    op = body(conn)

    if op["status"] == "Succeeded" do
      assert conn.status == 200
      op
    else
      assert conn.status == 202
      Process.sleep(10)
      poll_until_succeeded(path, attempts - 1)
    end
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp code(conn), do: body(conn)["error"]["code"]

  defp target(conn), do: body(conn)["error"]["target"]

  # The router itself is stateless over public ETS; the Store GenServer is
  # started defensively so this file also runs under `mix test --no-start`
  # when the shared tree's application start is blocked by a concurrent lane.
  defp ensure_store do
    SmaltTest.Lifecycle.ensure_store_up()

    :ok
  end
end

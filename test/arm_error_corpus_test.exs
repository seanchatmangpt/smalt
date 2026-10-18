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
    # Pin GLOBAL :lro_delay_ms to 0 (i22 forensics, mechanism lane 2): async
    # suites mutate this global (test/lro_test.exs:35 sets 20ms), stretching
    # per-poll latency; the env is only honored at flip evaluation, so pinning
    # here makes LRO flips immediate regardless of concurrent mutation.
    prev_delay = Application.get_env(:smalt, :lro_delay_ms)
    Application.put_env(:smalt, :lro_delay_ms, 0)
    on_exit(fn ->
      case prev_delay do
        nil -> Application.delete_env(:smalt, :lro_delay_ms)
        v -> Application.put_env(:smalt, :lro_delay_ms, v)
      end
    end)

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
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1",
          %{
            "location" => "smalt-local"
          }
        )
        |> Router.call(@opts)

      assert {400, "MissingApiVersionParameter"} = {conn.status, code(conn)}
      refute Map.has_key?(body(conn)["error"], "target")
    end

    @tag corpus: "InvalidApiVersionParameter"
    test "400 InvalidApiVersionParameter on stale api-version for admitted type" do
      # lib/smalt/arm_gateway/router.ex:422-429 (check_version mismatch branch)
      path =
        "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1?api-version=2999-01-01"

      conn =
        conn(:put, path, %{"location" => "smalt-local"})
        |> Router.call(@opts)

      # KD-78 monotonic gate: <= latest accepted; beyond-latest is the 400 face.
      assert {400, "InvalidApiVersionParameter"} = {conn.status, code(conn)}
      assert body(conn)["error"]["message"] =~ "2999-01-01"
      refute Map.has_key?(body(conn)["error"], "target")
    end

    @tag corpus: "ResourceGroupNotFound"
    test "404 ResourceGroupNotFound on GET of a missing resource group" do
      # lib/smalt/arm_gateway/router.ex:214 (handle_rg_get :error branch)
      conn =
        conn(:get, "/subscriptions/sub-1/resourceGroups/nope-rg?api-version=2023-07-01")
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

    @tag corpus: "InvalidResourceShape-details-multi-issue"
    test "400 InvalidResourceShape carries error.details rows (one per SHACL issue) on multi-issue refusal" do
      # lib/smalt/arm_gateway/router.ex check_shape {:invalid, issues} branch:
      # VNetShape requires location AND addressPrefixes; empty payload -> 2 issues
      # -> 2 details rows {code: InvalidResourceShape, message, target: path}.
      conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Network/virtualNetworks/vnet-details?api-version=2021-04-01",
          %{}
        )
        |> Router.call(@opts)

      assert {400, "InvalidResourceShape"} = {conn.status, code(conn)}

      details = body(conn)["error"]["details"]
      assert is_list(details)
      assert length(details) == 2

      for row <- details do
        assert %{"code" => "InvalidResourceShape", "message" => m, "target" => t} = row

        assert m in [
                 "virtualNetworks require location.",
                 "virtualNetworks require addressPrefixes."
               ]

        assert t in ["location", "addressPrefixes"]
      end

      targets = Enum.map(details, & &1["target"]) |> Enum.sort()
      assert targets == ["addressPrefixes", "location"]
    end

    @tag corpus: "InvalidResourceShape-details-absent-refused"
    test "error.details ABSENT on refused-path refusal (no SHACL issues to nest)" do
      # lib/smalt/arm_gateway/router.ex check_shape {:refused, reason} branch:
      # unadmitted-type refusal passes details == [] -> envelope byte-identical
      # to pre-details shape (details key absent, not present-but-empty).
      conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Fake/things/thing-d?api-version=2021-04-01",
          %{"location" => "smalt-local"}
        )
        |> Router.call(@opts)

      assert {400, "InvalidResourceShape"} = {conn.status, code(conn)}
      refute Map.has_key?(body(conn)["error"], "details")
    end

    @tag corpus: "InvalidResourceShape-details-absent-valid"
    test "details ABSENT on shape-valid PUT (no-issue path)" do
      # check_shape :ok branch: no refusal emitted; success envelope carries no
      # error object and therefore no details key (no-op path pinned).
      conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Network/virtualNetworks/vnet-ok?api-version=2021-04-01",
          %{"location" => "smalt-local", "properties" => %{"addressPrefixes" => ["10.0.0.0/16"]}}
        )
        |> Router.call(@opts)

      assert conn.status in 200..299
      # Success envelope: no error object at all (hence no details row).
      refute Map.has_key?(body(conn), "error")
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

    @tag corpus: "LocationMismatch"
    test "400 LocationMismatch on resource group PUT that changes location" do
      # lib/smalt/arm_gateway/router.ex:536 (R30 location-immutability refusal)
      conn(
        :put,
        "/subscriptions/sub-1/resourceGroups/rg-lm?api-version=2023-07-01",
        %{"location" => "eastus"}
      )
      |> Router.call(@opts)

      conn =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-lm?api-version=2023-07-01",
          %{"location" => "westus"}
        )
        |> Router.call(@opts)

      assert {400, "LocationMismatch"} = {conn.status, code(conn)}
      err = body(conn)["error"]
      assert err["message"] =~ "rg-lm" or is_binary(err["message"])
      assert err["message"] =~ "location"
      assert match?(%{}, err["innererror"])
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

      assert is_binary(record["id"]) and
               record["id"] =~ "/providers/Microsoft.EventGrid/topics/topic-1"

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

    assert emitted ==
             Enum.sort([
               # (400, "InvalidResourceShape") registered by the EventGrid-topics
               # lane: eg_input_schema_param's typed PUT refusal (was previously
               # only reachable through send_graphlaw_refusal, outside this
               # census's send_arm_error regex).
               {400, "InvalidApiVersionParameter"},
               {400, "InvalidResourceShape"},
               {400, "LocationMismatch"},
               {400, "MissingApiVersionParameter"},
               # Cross-lane integration: codes emitted by concurrently landed
               # source edits (sb-rules lane, azapi filter lane) registered here.
               {400, "InvalidAction"},
               {400, "InvalidFilter"},
               {404, "ActionNotFound"},
               {404, "OperationNotFound"},
               {404, "ResourceGroupNotFound"},
               {404, "ResourceNotFound"},
               {404, "RouteNotFound"},
               {404, "RuleNotFound"},
               {404, "SubscriptionNotFound"},
               # ARM secret rotation trigger (v26.10.16 console C4 lane): typed
               # 409 when the ARM record exists but carries no data-plane version
               # to rotate.
               {409, "SecretVersionNotFound"}
             ])
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
      prev_rate_limit = Application.get_env(:smalt, :arm_rate_limit)

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
          if is_nil(prev_rate_limit) do
            Application.delete_env(:smalt, :arm_rate_limit)
          else
            Application.put_env(:smalt, :arm_rate_limit, prev_rate_limit)
          end

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
        assert Plug.Conn.get_resp_header(conn, "content-type")
               |> hd()
               |> String.starts_with?("application/json")
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

  # Bounded retry-until-terminal (i22 hardening, mirrors i21 sweep_until_terminal):
  # the LRO completion write races concurrent suites under a shared store, so a short
  # attempt budget can flake. Poll until terminal or a generous 5000 ms deadline,
  # then flunk with a TYPED message naming the last observed status.
  # Forensics (mechanism lane 2): async suites mutate GLOBAL :lro_delay_ms
  # (test/lro_test.exs:35 sets 20ms; affidavit_ingestion, arm_cascade,
  # enclave_engine/state, runtime_contracts also touch it), stretching per-poll
  # latency under load, and Store.clear can delete the op row mid-poll. The env
  # is only honored at flip evaluation, so pinning it to 0 in setup makes flips
  # immediate regardless of concurrent mutation.
  @poll_deadline_ms 5000

  defp poll_until_succeeded(path, deadline \\ System.monotonic_time(:millisecond) + @poll_deadline_ms)

  defp poll_until_succeeded(path, deadline) do
    conn = conn(:get, path) |> Router.call(@opts)
    op = body(conn)

    cond do
      op["status"] == "Succeeded" ->
        assert conn.status == 200, "expected 200 on terminal poll, got #{conn.status}"
        op

      conn.status == 202 ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "LRO never reached Succeeded within #{@poll_deadline_ms} ms " <>
              "(path=#{path}, last_status=#{inspect(op["status"])})"
          )
        end

        Process.sleep(10)
        poll_until_succeeded(path, deadline)

      true ->
        flunk("unexpected poll status #{conn.status} for #{path}: #{inspect(op)}")
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

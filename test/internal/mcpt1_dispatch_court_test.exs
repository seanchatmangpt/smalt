defmodule Internal.MCPT1DispatchCourtTest do
  # MCP-T1 lane (v26.10.22): EXPL-8 T1 repair — the 5 wave-6 MCP tools were
  # implemented in Smalt.Mcp.Router but unreachable at the wire because the
  # generated descriptor was stale (32 capabilities vs 37 TTL capabilityIds).
  #
  # Court asserts dispatchability through the REAL wire face
  # (Plug.Test -> Smalt.Mcp.Router.call/2): tools/list must include all five,
  # tools/call must dispatch (isError false), an unknown id stays
  # TOOL_NOT_FOUND (negative control), a mutating id gets ACTUATION_REFUSED
  # (the read-only gate leg, EXPL-8 T4 fence), and the drift fence
  # length(Descriptor.capabilities()) == count(TTL capabilityIds) holds.
  use ExUnit.Case, async: false

  alias Smalt.Mcp.Descriptor
  alias Smalt.Mcp.Router

  @wave6 ~w(kv.rotationpolicy.get dns.zones.list eg.schemaregistry.groups monitor.alerts.list cosmos.ttl.effective)

  @ttl_path "lib/smalt/mcp/gen/smalt_mcp_surface.ttl"

  # -- wire helpers -----------------------------------------------------------

  defp rpc(method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => params
      })

    conn =
      Plug.Test.conn("POST", "/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp call_tool(name, args \\ %{}) do
    rpc("tools/call", %{"name" => name, "arguments" => args})
  end

  # -- drift fence ------------------------------------------------------------

  test "descriptor capability count equals TTL capabilityId count (drift fence)" do
    ttl_count =
      @ttl_path
      |> File.read!()
      |> then(&Regex.scan(~r/ema:capabilityId\s+"[^"]+"/, &1))
      |> length()

    assert ttl_count == 37
    assert map_size(Descriptor.capabilities()) == ttl_count
  end

  # -- tools/list -------------------------------------------------------------

  test "tools/list includes all five wave-6 tools" do
    resp = rpc("tools/list", %{})

    names = resp["result"]["tools"] |> Enum.map(& &1["name"]) |> MapSet.new()

    for t <- @wave6 do
      assert t in names, "expected #{t} in tools/list"
    end

    assert length(resp["result"]["tools"]) == 37
  end

  # -- per-tool dispatch (real collaborators, seeded state) --------------------

  test "cosmos.ttl.effective dispatches over the wire (the EXPL-8 probe tool)" do
    {:ok, 201, _, _} = Smalt.DataPlane.Cosmos.create_db("mcpt1-db")
    {:ok, 201, _, _} =
      Smalt.DataPlane.Cosmos.create_collection("mcpt1-db", "mcpt1-coll", %{
        "analyticalStorageTtl" => 3600
      })

    resp = call_tool("cosmos.ttl.effective", %{"db" => "mcpt1-db", "coll" => "mcpt1-coll"})

    assert resp["result"]["isError"] == false
    sc = resp["result"]["structuredContent"]
    assert sc["effective_ttl"] == 3600
  end

  test "kv.rotationpolicy.get dispatches (typed not-found, NOT TOOL_NOT_FOUND)" do
    resp = call_tool("kv.rotationpolicy.get", %{"name" => "mcpt1-no-such-key"})

    sc = resp["result"]["structuredContent"]

    # dispatched into the invoke clause: typed substrate-level refusal, the
    # dispatch-level TOOL_NOT_FOUND fence must NOT fire
    refute sc["code"] == "TOOL_NOT_FOUND"
    refute sc["code"] == "ACTUATION_REFUSED"
    assert sc["code"] == "INVALID_PARAMS"
  end

  test "dns.zones.list dispatches over the wire (real ARM DNS store, empty is a list)" do
    resp = call_tool("dns.zones.list", %{"rg" => "mcpt1-rg"})

    assert resp["result"]["isError"] == false

    sc = resp["result"]["structuredContent"]
    assert sc["rg"] == "mcpt1-rg"
    assert sc["zones"] == []
    assert sc["count"] == 0
  end

  test "eg.schemaregistry.groups dispatches over the wire (real schema-registry store)" do
    resp = call_tool("eg.schemaregistry.groups", %{})

    assert resp["result"]["isError"] == false

    sc = resp["result"]["structuredContent"]
    assert is_list(sc["groups"])
    assert sc["count"] == length(sc["groups"])
  end

  test "monitor.alerts.list dispatches over the wire (real metric-alerts store)" do
    resp = call_tool("monitor.alerts.list", %{"sub" => "mcpt1-sub", "rg" => "mcpt1-rg"})

    assert resp["result"]["isError"] == false

    sc = resp["result"]["structuredContent"]
    assert sc["sub"] == "mcpt1-sub"
    assert is_list(sc["alerts"])
    assert sc["count"] == length(sc["alerts"])
  end

  # -- negative control + read-only gate leg (T4) -------------------------------

  test "unknown tool stays TOOL_NOT_FOUND (negative control)" do
    resp = call_tool("mcpt1.not.a.tool", %{})

    assert resp["result"]["isError"] == true

    sc = resp["result"]["structuredContent"]
    assert sc["code"] == "TOOL_NOT_FOUND"
  end

  test "mutating tool id is ACTUATION_REFUSED (read-only gate leg)" do
    resp = call_tool("kv.rotationpolicy.put", %{"name" => "k", "policy" => %{}})

    assert resp["result"]["isError"] == true

    sc = resp["result"]["structuredContent"]
    assert sc["code"] == "ACTUATION_REFUSED"
  end

  # -- BK-MCPW: JSON-RPC parse-error envelope ----------------------------------

  test "malformed JSON body renders the JSON-RPC -32700 PARSE_ERROR envelope (BK-MCPW)" do
    conn =
      Plug.Test.conn("POST", "/", ~s({"jsonrpc": "2.0", ))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])

    assert conn.status == 400

    resp = Jason.decode!(conn.resp_body)
    assert resp["jsonrpc"] == "2.0"
    assert resp["id"] == nil
    assert resp["error"]["code"] == -32_700
    assert resp["error"]["data"]["code"] == "PARSE_ERROR"
    assert resp["error"]["data"]["message"] == "invalid JSON body"
  end

  # -- BK-JRPC2: JSON-RPC invalid-request envelope ------------------------------

  test "valid JSON that is not a JSON-RPC 2.0 request renders -32600 (BK-JRPC2)" do
    conn =
      Plug.Test.conn("POST", "/", ~s({"foo": 1}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])

    assert conn.status == 400

    resp = Jason.decode!(conn.resp_body)
    assert resp["jsonrpc"] == "2.0"
    assert resp["id"] == nil
    assert resp["error"]["code"] == -32_600
    assert resp["error"]["data"]["code"] == "INVALID_REQUEST"
  end

  test "wrong jsonrpc version renders -32600, not -32602 (BK-JRPC2)" do
    conn =
      Plug.Test.conn("POST", "/", ~s({"jsonrpc": "1.0", "id": 1, "method": "tools/list"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Router.call(conn, [])

    assert conn.status == 400

    resp = Jason.decode!(conn.resp_body)
    assert resp["error"]["code"] == -32_600
    assert resp["error"]["data"]["code"] == "INVALID_REQUEST"
  end
end

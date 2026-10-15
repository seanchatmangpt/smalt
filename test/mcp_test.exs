defmodule Smalt.McpTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @default_sub "00000000-0000-0000-0000-000000000000"

  defp rpc(method, params \\ %{}, id \\ 1) do
    conn(
      :post,
      "/",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    )
    |> Smalt.Mcp.Router.call([])
  end

  defp decoded(conn) do
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    Jason.decode!(conn.resp_body)
  end

  defp result(conn), do: conn |> decoded() |> Map.fetch!("result")

  defp structured(conn) do
    conn |> result() |> Map.fetch!("structuredContent")
  end

  defp refusal_code(conn) do
    result = result(conn)
    assert result["isError"] == true
    result["structuredContent"]["code"]
  end

  setup do
    # Real substrate state: seed store rows the read tools read back.
    Smalt.Store.put(
      :smalt_resources,
      String.downcase(
        "/subscriptions/#{@default_sub}/resourceGroups/mcp-rg/providers/Microsoft.Storage/storageAccounts/mcpacct"
      ),
      %{
        "id" =>
          "/subscriptions/#{@default_sub}/resourceGroups/mcp-rg/providers/Microsoft.Storage/storageAccounts/mcpacct",
        "name" => "mcpacct",
        "type" => "Microsoft.Storage/storageAccounts",
        "location" => "eastus",
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{}
      }
    )

    Smalt.Store.put(:smalt_blobs, "mcpacct/mcpcontainer/notes.txt", %{
      "name" => "notes.txt",
      "etag" => "\"abc\"",
      "content" => "hello",
      "content_length" => 5,
      "last_modified" => "2026-10-14T00:00:00Z",
      "headers" => %{"content-type" => "text/plain"}
    })

    Smalt.Store.put(:smalt_vault_keys, "mcp-key", %{
      "name" => "mcp-key",
      "kty" => "RSA",
      "key_material" => <<1, 2, 3>>,
      "attributes" => %{"enabled" => true}
    })

    :ok
  end

  # ---------------------------------------------------------------------------
  # Protocol
  # ---------------------------------------------------------------------------

  test "GET / advertises the JSON-RPC surface" do
    conn =
      conn(:get, "/")
      |> Smalt.Mcp.Router.call([])

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["service"] == "smalt-mcp"
  end

  test "initialize returns protocol version and server info" do
    body = rpc("initialize", %{"protocolVersion" => "2024-11-05"}) |> decoded()

    assert body["jsonrpc"] == "2.0"
    assert body["result"]["protocolVersion"] == "2024-11-05"
    assert body["result"]["serverInfo"]["name"] == "smalt-mcp"
  end

  test "tools/list exposes exactly the 8 read-only tools, all readOnlyHint" do
    tools =
      rpc("tools/list")
      |> result()
      |> Map.fetch!("tools")

    names = Enum.map(tools, & &1["name"]) |> Enum.sort()

    assert names == [
             "arm.get",
             "blob.list",
             "cosmos.query",
             "doctor.summary",
             "kv.get",
             "sb.peek",
             "substrate.capabilities",
             "substrate.status"
           ]

    assert Enum.all?(tools, fn t -> t["annotations"]["readOnlyHint"] == true end)
    assert Enum.all?(tools, fn t -> t["inputSchema"]["type"] == "object" end)
  end

  test "malformed JSON body -> typed parse error" do
    conn =
      conn(:post, "/", "{not json")
      |> Smalt.Mcp.Router.call([])

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32_700
    assert body["error"]["data"]["code"] == "PARSE_ERROR"
  end

  test "unknown JSON-RPC method -> -32601 METHOD_NOT_FOUND" do
    conn = rpc("resources/list")
    body = decoded(conn)

    assert body["error"]["code"] == -32_601
    assert body["error"]["data"]["code"] == "METHOD_NOT_FOUND"
  end

  # ---------------------------------------------------------------------------
  # Each tool against real substrate modules
  # ---------------------------------------------------------------------------

  test "substrate.status reports live substrate over real modules" do
    status =
      rpc("tools/call", %{"name" => "substrate.status", "arguments" => %{}}) |> structured()

    assert status["status"] == "ok"
    assert status["store_alive"] == true
    assert status["mcp_read_only_surface"] == true
    assert status["ports"]["control_plane"] == Smalt.Registry.control_plane_port()
  end

  test "substrate.capabilities is Registry-derived" do
    caps =
      rpc("tools/call", %{"name" => "substrate.capabilities", "arguments" => %{}}) |> structured()

    assert caps["admitted_resource_types"] == Smalt.Registry.admitted_resource_types()

    assert caps["admitted_resource_type_count"] ==
             length(Smalt.Registry.admitted_resource_types())

    assert Map.has_key?(caps["api_versions"], "Microsoft.Storage/storageAccounts")
    assert "substrate.status" in caps["mcp_tools"]
  end

  test "arm.get returns the seeded resource record" do
    record =
      rpc("tools/call", %{
        "name" => "arm.get",
        "arguments" => %{
          "resource_group" => "mcp-rg",
          "resource_type" => "Microsoft.Storage/storageAccounts",
          "resource_name" => "mcpacct"
        }
      })
      |> structured()

    assert record["name"] == "mcpacct"
    assert record["type"] == "Microsoft.Storage/storageAccounts"
    assert record["properties"]["provisioningState"] == "Succeeded"
  end

  test "arm.get missing resource -> typed RESOURCE_NOT_FOUND refusal" do
    conn =
      rpc("tools/call", %{
        "name" => "arm.get",
        "arguments" => %{
          "resource_group" => "nope",
          "resource_type" => "Microsoft.Storage/storageAccounts",
          "resource_name" => "ghost"
        }
      })

    assert refusal_code(conn) == "RESOURCE_NOT_FOUND"
  end

  test "cosmos.query returns the SDK wire shape from the real store" do
    # Seed a doc directly the way the Cosmos data plane stores them.
    db = "mcpdb"
    coll = "mcpcoll"

    Smalt.Store.put(:smalt_cosmos_docs, "#{db}/#{coll}/doc1", %{
      "id" => "doc1",
      "mcp" => true
    })

    body =
      rpc("tools/call", %{"name" => "cosmos.query", "arguments" => %{"db" => db, "coll" => coll}})
      |> structured()

    assert body["_count"] >= 1
    assert Enum.any?(body["Documents"], fn d -> d["id"] == "doc1" end)
  end

  test "blob.list returns content-free metadata only" do
    body =
      rpc("tools/call", %{
        "name" => "blob.list",
        "arguments" => %{"account" => "mcpacct", "container" => "mcpcontainer"}
      })
      |> structured()

    assert body["count"] == 1
    [blob] = body["blobs"]
    assert blob["name"] == "notes.txt"
    assert Map.has_key?(blob, "content_length")
    # Content-free: raw bytes never cross the wire.
    refute Map.has_key?(blob, "content")
  end

  test "sb.peek reads queue messages without settlement" do
    queue = "mcp-peek-queue"
    Smalt.Amqp.QueueStore.ensure_queue(queue)
    Smalt.Amqp.QueueStore.enqueue(queue, "hello-mcp")

    body =
      rpc("tools/call", %{
        "name" => "sb.peek",
        "arguments" => %{"queue" => queue, "message_count" => 5}
      })
      |> structured()

    assert body["count"] == 1
    assert body["messages"] |> hd() |> Map.get("body") == "hello-mcp"

    # Peek is read-only: the message is still there on a second peek.
    body2 =
      rpc("tools/call", %{"name" => "sb.peek", "arguments" => %{"queue" => queue}})
      |> structured()

    assert body2["count"] == 1
  end

  test "kv.get returns the public key record, never key material" do
    body =
      rpc("tools/call", %{"name" => "kv.get", "arguments" => %{"name" => "mcp-key"}})
      |> structured()

    assert body["name"] == "mcp-key"
    assert body["kty"] == "RSA"
    refute Map.has_key?(body, "key_material")
  end

  test "kv.get missing key -> typed RESOURCE_NOT_FOUND refusal" do
    conn = rpc("tools/call", %{"name" => "kv.get", "arguments" => %{"name" => "ghost-key"}})
    assert refusal_code(conn) == "RESOURCE_NOT_FOUND"
  end

  test "doctor.summary reports real supervisor children and table readiness" do
    summary = rpc("tools/call", %{"name" => "doctor.summary", "arguments" => %{}}) |> structured()

    assert summary["status"] == "healthy"
    assert summary["cosmos_store_ready"] == true
    assert summary["vault_keys_table_ready"] == true
    assert summary["store_alive"] == true
    assert is_list(summary["supervisor_children"])
    assert Enum.any?(summary["supervisor_children"], fn c -> c["id"] == "Smalt.Store" end)
  end

  # ---------------------------------------------------------------------------
  # Law enforcement: unknown tool + actuation refusals
  # ---------------------------------------------------------------------------

  test "unknown tool -> typed TOOL_NOT_FOUND refusal" do
    conn = rpc("tools/call", %{"name" => "cosmos.put", "arguments" => %{}})

    # "cosmos.put" carries an actuation verb -> the stronger actuation verdict.
    assert refusal_code(conn) == "ACTUATION_REFUSED"
  end

  test "plain unknown tool id -> TOOL_NOT_FOUND" do
    conn = rpc("tools/call", %{"name" => "definitely.not.a.tool", "arguments" => %{}})
    assert refusal_code(conn) == "TOOL_NOT_FOUND"
  end

  test "actuation tool attempts are refused with typed ACTUATION_REFUSED" do
    for name <- [
          "arm.put",
          "blob.put",
          "blob.delete",
          "kv.encrypt",
          "sb.complete",
          "substrate.actuate",
          "kv.unwrapKey",
          "cosmos.delete_doc"
        ] do
      conn = rpc("tools/call", %{"name" => name, "arguments" => %{}}, name)

      assert refusal_code(conn) == "ACTUATION_REFUSED"
      result = result(conn)
      assert result["content"] |> hd() |> Map.get("text") =~ "read-only"
    end
  end

  test "non-string tool name is refused, never dispatched" do
    conn = rpc("tools/call", %{"name" => 42, "arguments" => %{}})
    assert refusal_code(conn) == "ACTUATION_REFUSED"
  end

  test "generated descriptor agrees with the router surface (fail-closed gate)" do
    descriptor_ids = Smalt.Mcp.Descriptor.capabilities() |> Map.keys() |> Enum.sort()

    wire_ids =
      rpc("tools/list")
      |> result()
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert descriptor_ids == wire_ids
    assert Smalt.Mcp.Descriptor.read_only_surface?()
    # Fail-closed: unregistered ids demand authority.
    assert Smalt.Mcp.Descriptor.requires_authority?("arm.put")
    refute Smalt.Mcp.Descriptor.requires_authority?("arm.get")
  end
end

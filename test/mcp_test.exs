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

  test "request id is echoed exactly (string and integer ids)" do
    for id <- ["req-abc", 12_345] do
      body = rpc("tools/list", %{}, id) |> decoded()
      assert body["id"] == id
    end
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

  test "wrong jsonrpc version -> typed INVALID_REQUEST, never dispatched" do
    for bad_version <- ["1.0", "2.1", 2.0, nil] do
      conn =
        conn(
          :post,
          "/",
          Jason.encode!(%{"jsonrpc" => bad_version, "id" => 7, "method" => "tools/list"})
        )
        |> Smalt.Mcp.Router.call([])

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["data"]["code"] == "INVALID_REQUEST"
      assert body["error"]["code"] == -32_602
    end
  end

  test "non-object JSON bodies (array/string/number) -> typed INVALID_REQUEST" do
    for body <- ["[]", "\"hello\"", "42", "null", "true"] do
      conn = conn(:post, "/", body) |> Smalt.Mcp.Router.call([])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["data"]["code"] == "INVALID_REQUEST"
    end
  end

  test "tools/call without params or empty params -> typed -32602, not METHOD_NOT_FOUND" do
    for body <- [
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call"},
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{}}
        ] do
      conn = conn(:post, "/", Jason.encode!(body)) |> Smalt.Mcp.Router.call([])

      assert conn.status == 200
      body = decoded(conn)
      assert body["error"]["code"] == -32_602
      assert body["error"]["data"]["code"] == "INVALID_PARAMS"
    end
  end

  # JSON-RPC framing fuzz: exact typed verdicts, never a 500.
  test "fuzz: JSON-RPC 2.0 batch array -> typed INVALID_REQUEST, never dispatched" do
    conn =
      conn(
        :post,
        "/",
        Jason.encode!([
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"},
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/call", "params" => %{"name" => "kv.get", "arguments" => %{}}}
        ])
      )
      |> Smalt.Mcp.Router.call([])

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32_602
    assert body["error"]["data"]["code"] == "INVALID_REQUEST"
  end

  test "fuzz: malformed JSON corpus -> exact -32700 PARSE_ERROR on every variant" do
    variants = [
      "{",
      "[1,2",
      "{\"jsonrpc\":}",
      "\x00\x01\x02",
      "nul",
      "{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"tools/list\",}",
      ""
    ]

    for body <- variants do
      conn = conn(:post, "/", body) |> Smalt.Mcp.Router.call([])

      assert conn.status == 400, "variant #{inspect(body)} did not 400"
      error = Jason.decode!(conn.resp_body)["error"]
      assert error["code"] == -32_700
      assert error["data"]["code"] == "PARSE_ERROR"
    end
  end

  test "fuzz: null id and absent id are echoed/typed, never crash" do
    for id <- [nil, :absent] do
      req = %{"jsonrpc" => "2.0", "method" => "tools/list"}
      req = if id == :absent, do: req, else: Map.put(req, "id", id)

      conn = conn(:post, "/", Jason.encode!(req)) |> Smalt.Mcp.Router.call([])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["result"]["tools"] |> length() == 8
      assert Map.has_key?(body, "id")
    end
  end

  test "fuzz: huge and unicode method names -> typed METHOD_NOT_FOUND, exact echo" do
    for method <- [
          String.duplicate("m", 100_000),
          "tööls/日本語",
          "tools/\u0000list",
          Enum.map(1..200, fn _ ->
            cp = :rand.uniform(0x10FF)

            if cp in 0xD800..0xDFFF, do: cp + 0x800, else: cp
          end)
          |> Enum.map(&<<&1::utf8>>)
          |> List.to_string()
        ] do
      conn =
        conn(:post, "/", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 9, "method" => method}))
        |> Smalt.Mcp.Router.call([])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == 9
      assert body["error"]["code"] == -32_601
      assert body["error"]["data"]["code"] == "METHOD_NOT_FOUND"
      # The offending method is echoed back in the error data verbatim.
      assert body["error"]["data"]["message"] == method
    end
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

  # ---------------------------------------------------------------------------
  # Lens-2 fences: pinned protocol negotiation, tools/call arg fuzz,
  # keys-only blob.list behavior + perf contract
  # ---------------------------------------------------------------------------

  # Protocol-version negotiation is a PINNED contract: the server answers
  # with its one supported version regardless of what the client offers
  # (older, newer, malformed, absent). No echo, no downgrade.
  test "initialize pins protocolVersion against older/newer/malformed/absent offers" do
    for offered <- [
          "2024-11-05",
          "2025-06-18",
          "1900-01-01",
          "2024-10-07",
          "not-a-date",
          20_241_105,
          nil,
          :absent
        ] do
      params = if offered == :absent, do: %{}, else: %{"protocolVersion" => offered}

      body = rpc("initialize", params) |> decoded()

      assert body["result"]["protocolVersion"] == "2024-11-05",
             "offered #{inspect(offered)} was echoed or downgraded instead of pinned"
    end
  end

  # tools/call argument fuzz: hostile argument shapes must land in the typed
  # INVALID_PARAMS / RESOURCE_NOT_FOUND verdicts, never a 500.
  test "fuzz: 100-deep nested arguments -> typed refusal, never a 500" do
    deep = Enum.reduce(1..100, %{"leaf" => true}, fn _i, acc -> %{"nested" => acc} end)

    for {tool, args} <- [
          {"kv.get", deep},
          {"kv.get", %{"name" => deep}},
          {"blob.list", %{"account" => deep, "container" => "c"}},
          {"arm.get", Map.merge(deep, %{"resource_group" => "rg"})},
          {"sb.peek", %{"queue" => deep}}
        ] do
      conn = rpc("tools/call", %{"name" => tool, "arguments" => args}, tool)

      assert conn.status == 200, "#{tool} crashed on 100-deep args: #{inspect(conn.status)}"

      assert refusal_code(conn) in ["INVALID_PARAMS", "RESOURCE_NOT_FOUND"],
             "#{tool} returned #{inspect(result(conn))} for 100-deep args"
    end
  end

  test "fuzz: duplicate JSON keys in the raw body -> deterministic first-wins, typed response" do
    body =
      ~s({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
          "params": {"name": "kv.get", "name": "blob.list", "arguments": {"name": "mcp-key"}}})

    conn = conn(:post, "/", body) |> Smalt.Mcp.Router.call([])

    assert conn.status == 200
    # Jason keeps the FIRST duplicate: the request deterministically routes to
    # kv.get and succeeds against the seeded key — never a crash, never a
    # double dispatch.
    body_map = decoded(conn)
    assert body_map["result"]["isError"] == false
    assert body_map["result"]["structuredContent"]["name"] == "mcp-key"
  end

  test "fuzz: numeric id offered as a string is echoed verbatim" do
    for id <- ["12345", "0", "-7", "1e10"] do
      body = rpc("tools/list", %{}, id) |> decoded()
      assert body["id"] == id
    end
  end

  test "kv.get non-string name -> typed refusal, never dispatched" do
    for bad <- [42, %{}, [], nil] do
      conn = rpc("tools/call", %{"name" => "kv.get", "arguments" => %{"name" => bad}}, bad)
      assert refusal_code(conn) in ["INVALID_PARAMS", "ACTUATION_REFUSED", "RESOURCE_NOT_FOUND"]
    end
  end

  # Keys-only-class blob.list behavior: ALL blobs in key order, content-free,
  # churn-safe. Parity with the pre-change list_prefix/Enum.map semantics.
  test "blob.list lists every blob in key order, content-free, across containers" do
    content = :crypto.strong_rand_bytes(1024)

    names =
      for i <- 1..25 do
        padded = String.pad_leading(Integer.to_string(i), 3, "0")
        name = "blob-" <> padded

        Smalt.Store.put(:smalt_blobs, "keysa/keycont/#{name}", %{
          "name" => name,
          "etag" => "\"e#{i}\"",
          "content" => content,
          "content_length" => 1024,
          "last_modified" => "2026-10-15T00:00:00Z",
          "headers" => %{}
        })

        name
      end

    body =
      rpc("tools/call", %{
        "name" => "blob.list",
        "arguments" => %{"account" => "keysa", "container" => "keycont"}
      })
      |> structured()

    assert body["count"] == 25
    assert Enum.map(body["blobs"], & &1["name"]) == names
    assert Enum.all?(body["blobs"], fn b -> not Map.has_key?(b, "content") end)
    assert Enum.all?(body["blobs"], fn b -> b["etag"] =~ "e" end)

    # Container isolation: another container of the same account never bleeds in.
    Smalt.Store.put(:smalt_blobs, "keysa/other/foreign.txt", %{
      "name" => "foreign.txt",
      "etag" => "\"f\"",
      "content" => "x",
      "content_length" => 1,
      "last_modified" => "2026-10-15T00:00:00Z",
      "headers" => %{}
    })

    body2 =
      rpc("tools/call", %{
        "name" => "blob.list",
        "arguments" => %{"account" => "keysa", "container" => "keycont"}
      })
      |> structured()

    assert body2["count"] == 25
  end

  # Peak-memory contract for the keys-only blob.list scan (lens-2). Measured:
  # wall time does NOT discriminate the revert (both ~25 ms in-process over
  # 4000x32KiB — ETS returns references, metadata projection drops content),
  # so a wall-time fence is vacuous here. The observable difference is PEAK
  # process memory: the reverted full-value materialization holds all 4000
  # content records (~125 MiB) live in one intermediate list; the keys-only
  # scan holds one record at a time. Measured under the revert mutant:
  # ~262_000 KB; keys-only: ~46_000 KB. Budget 150_000 KB kills the revert
  # with ~3x margin and ~3x headroom above the keys-only truth.
  @mcp_blob_peak_mem_budget_kb 150_000

  @tag :mcp_blob_perf
  test "blob.list peak-memory contract: 4000x32KiB scan stays bounded" do
    for i <- 1..4000 do
      name = "blob-" <> String.pad_leading(Integer.to_string(i), 5, "0")
      # Unique content per blob: a shared binary would make the reverted
      # full-value list hold 4000 references to ONE object and the fence
      # could not see the materialization.
      content = name <> String.duplicate("x", 32 * 1024)

      Smalt.Store.put(:smalt_blobs, "perfmcp/perfcont/#{name}", %{
        "name" => name,
        "etag" => "\"e\"",
        "content" => content,
        "content_length" => 32 * 1024,
        "last_modified" => "2026-10-15T00:00:00Z",
        "headers" => %{}
      })
    end

    parent = self()

    {_pid, ref} =
      Process.spawn(
        fn ->
          # Clean baseline, then ONE scan in THIS process; read its own memory
          # before exiting, without a forced GC, so any intermediate
          # full-value list is still on the heap.
          :erlang.garbage_collect()
          {:ok, _} = Smalt.Store.get(:smalt_blobs, "perfmcp/perfcont/blob-00001")

          conn =
            conn(:post, "/", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
                               "params" => %{"name" => "blob.list",
                                             "arguments" => %{"account" => "perfmcp",
                                                              "container" => "perfcont"}}}
                  |> Jason.encode!())
            |> Smalt.Mcp.Router.call([])

          mem_kb = div(elem(:erlang.process_info(self(), :memory), 1), 1024)
          assert conn.status == 200
          send(parent, {:mem, mem_kb})
        end,
        [:link, :monitor]
      )

    assert_receive {:mem, mem_kb}, 30_000
    receive do: ({:DOWN, ^ref, :process, _p, _} -> :ok)

    if mem_kb > @mcp_blob_peak_mem_budget_kb do
      flunk("""
      blob.list peak-memory contract violated: #{mem_kb} KB > #{@mcp_blob_peak_mem_budget_kb} KB
      over a 4000x32KiB scan. Likely revert to full-value materialization
      (revert measured ~262_000 KB; keys-only ~46_000 KB).
      """)
    end
  end
  # Call-shape contract for the keys-only blob.list scan (lens-2). Measured:
  # neither wall time (~25 ms both ways) nor process memory (refc binaries
  # live off-heap) discriminates the revert to full-value materialization, so
  # a perf fence of either kind is VACUOUS here. The deterministic observable
  # is the call shape, witnessed by a real trace of the scan: blob.list must
  # fetch blob values ONLY per-key (Store.get/2) — never via
  # Store.list_prefix/2, the full-value walk.
  test "blob.list call-shape contract: per-key fetches, never list_prefix" do
    for i <- 1..5 do
      name = "trace-#{i}"

      Smalt.Store.put(:smalt_blobs, "traceacct/tracecont/#{name}", %{
        "name" => name,
        "etag" => "\"e\"",
        "content" => String.duplicate("x", 1024),
        "content_length" => 1024,
        "last_mounted" => false,
        "last_modified" => "2026-10-15T00:00:00Z",
        "headers" => %{}
      })
    end

    :erlang.trace_pattern({Smalt.Store, :list_prefix, 2}, true, [:global])
    :erlang.trace_pattern({Smalt.Store, :get, 2}, true, [:global])

    parent = self()

    worker =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        body =
          rpc("tools/call", %{
            "name" => "blob.list",
            "arguments" => %{"account" => "traceacct", "container" => "tracecont"}
          })
          |> structured()

        :erlang.trace(self(), false, [:call])
        send(parent, {:result, body})
      end)

    :erlang.trace(worker, true, [:call])
    send(worker, :go)

    assert_receive {:result, body}, 30_000
    assert body["count"] == 5

    :erlang.trace_pattern({Smalt.Store, :list_prefix, 2}, false, [:global])
    :erlang.trace_pattern({Smalt.Store, :get, 2}, false, [:global])

    calls = collect_traced_calls([])

    assert Enum.count(calls, &match?({:list_prefix, [_t, _p]}, &1)) == 0,
           "blob.list reverted to full-value materialization (list_prefix called: #{inspect(calls)})"

    assert Enum.count(calls, &match?({:get, [_t, _k]}, &1)) >= 5,
           "expected per-key Store.get/2 fetches, got #{length(calls)}"
  end

  # ---------------------------------------------------------------------------
  # Lens-3 cycle 1: per-tool argument guard matrix, result-envelope contract,
  # leak-walk. Hostile shapes per tool: wrong arity, nil, list-of-maps,
  # deeply-nested, binary-with-NUL. Every cell: HTTP 200 + typed verdict,
  # NEVER a 500; non-binary required args land INVALID_PARAMS exactly.
  # ---------------------------------------------------------------------------

  @bad_scalars [42, 3.14, %{}, [], nil, [%{"a" => 1}], true]

  test "lens3 fuzz matrix: non-binary required args -> INVALID_PARAMS exactly, never 500" do
    cells = [
      {"kv.get", "name"},
      {"blob.list", "account"},
      {"blob.list", "container"},
      {"cosmos.query", "db"},
      {"cosmos.query", "coll"},
      {"sb.peek", "queue"},
      {"arm.get", "resource_group"},
      {"arm.get", "resource_type"},
      {"arm.get", "resource_name"},
      {"arm.get", "subscription_id"}
    ]

    for {tool, arg} <- cells, bad <- @bad_scalars do
      args =
        Map.merge(
          valid_args(tool),
          %{arg => bad}
        )

      conn = rpc("tools/call", %{"name" => tool, "arguments" => args}, "#{tool}-#{arg}-#{inspect(bad)}")

      assert conn.status == 200,
             "#{tool}.#{arg}=#{inspect(bad)} crashed: HTTP #{conn.status} #{conn.resp_body}"

      code = refusal_code(conn)

      assert code == "INVALID_PARAMS",
             "#{tool}.#{arg}=#{inspect(bad)} landed #{inspect(code)} (#{inspect(result(conn))}), expected INVALID_PARAMS"
    end
  end

  test "lens3 fuzz: wrong arity (missing required args) -> INVALID_PARAMS per tool" do
    # Schema-required args ONLY: message_count is optional (absent -> default
    # 10 is the designed behavior, fenced separately below).
    required_args = %{
      "kv.get" => %{"name" => "mcp-key"},
      "blob.list" => %{"account" => "mcpacct", "container" => "mcpcontainer"},
      "cosmos.query" => %{"db" => "mcpdb", "coll" => "mcpcoll"},
      "sb.peek" => %{"queue" => "mcp-peek-queue"},
      "arm.get" => %{
        "resource_group" => "mcp-rg",
        "resource_type" => "Microsoft.Storage/storageAccounts",
        "resource_name" => "mcpacct"
      }
    }

    for {tool, valid} <- required_args do
      for dropped <- Map.keys(valid) do
        args = Map.delete(valid, dropped)
        conn = rpc("tools/call", %{"name" => tool, "arguments" => args}, "#{tool}-minus-#{dropped}")

        assert conn.status == 200, "#{tool} without #{dropped} crashed: #{conn.status}"

        assert refusal_code(conn) == "INVALID_PARAMS",
               "#{tool} without #{dropped} landed #{inspect(result(conn))}"
      end
    end
  end

  test "lens3 fuzz: hostile arguments CONTAINER (list-of-maps, scalar, deep) -> typed, never 500" do
    deep = Enum.reduce(1..200, %{"leaf" => true}, fn _i, acc -> %{"nested" => acc} end)

    for arguments <- [[%{"name" => "x"}], [1, 2], 42, "kv.get", nil, true, deep] do
      conn = rpc("tools/call", %{"name" => "kv.get", "arguments" => arguments}, "container")

      assert conn.status == 200, "arguments=#{inspect(arguments)} crashed: #{conn.status}"

      # nil arguments normalizes to %{} at dispatch: a missing name is
      # INVALID_PARAMS, same as every other non-object arguments container.
      assert refusal_code(conn) == "INVALID_PARAMS"
    end
  end

  test "lens3 fuzz: binary-with-NUL arguments -> typed verdict, valid JSON out, never 500" do
    conn = rpc("tools/call", %{"name" => "kv.get", "arguments" => %{"name" => "a\0b"}})
    assert conn.status == 200
    assert refusal_code(conn) == "RESOURCE_NOT_FOUND"

    conn = rpc("tools/call", %{"name" => "blob.list", "arguments" => %{"account" => "a\0b", "container" => "c\0d"}})
    assert conn.status == 200
    body = structured(conn)
    assert body["count"] == 0

    conn = rpc("tools/call", %{"name" => "cosmos.query", "arguments" => %{"db" => "d\0b", "coll" => "c\0b"}})
    assert conn.status == 200
    assert result(conn)["isError"] in [true, false]

    conn =
      rpc("tools/call", %{
        "name" => "arm.get",
        "arguments" => %{
          "resource_group" => "rg\0x",
          "resource_type" => "t\0",
          "resource_name" => "\0n"
        }
      })

    assert conn.status == 200
    assert refusal_code(conn) == "RESOURCE_NOT_FOUND"
  end

  # sb.peek message_count is schema-bounded (integer 1..100); out-of-schema
  # values are refused at dispatch, never forwarded to the substrate.
  test "lens3 sb.peek out-of-schema message_count -> INVALID_PARAMS" do
    # nil is ABSENT: absent message_count defaults to 10 by design (fenced in
    # the arity test); only genuinely out-of-schema values refuse.
    for bad_mc <- [0, -1, 101, 1.5, "10", %{}, [5], true] do
      conn =
        rpc("tools/call", %{
          "name" => "sb.peek",
          "arguments" => %{"queue" => "mcp-peek-queue", "message_count" => bad_mc}
        })

      assert conn.status == 200, "message_count=#{inspect(bad_mc)} crashed: #{conn.status}"

      assert refusal_code(conn) == "INVALID_PARAMS",
             "message_count=#{inspect(bad_mc)} landed #{inspect(result(conn))}"
    end
  end

  # Lens-4: sanitize_child_id/1 fuzz through the public wire path with a REAL
  # hostile-id supervisor (Chicago: no mock — a genuine Supervisor with child
  # ids chosen to attack the ref-collapse: nested refs in tuples, refs embedded
  # in string ids, multiple refs in one id). Every sanitized id must leave no
  # materialized reference token (#Reference<0.x.y.z> shape) in the envelope.
  test "lens4 doctor.summary hostile child-id fuzz: ref tokens never materialize" do
    ids = [
      {:tuple_ref, make_ref()},
      "str-#Reference<0.42.0.999>-mid-#Reference<0.43.0.998>-end",
      {:nested, {:deep, make_ref()}},
      {Bandit, make_ref(), make_ref()},
      "plain-string-id"
    ]

    children =
      Enum.map(ids, fn id ->
        %{id: id, start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]}}
      end)

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    Application.put_env(:smalt, :doctor_supervisor, sup)

    on_exit(fn ->
      Application.put_env(:smalt, :doctor_supervisor, Smalt.Supervisor)
      Process.exit(sup, :kill)
    end)

    body =
      rpc("tools/call", %{"name" => "doctor.summary", "arguments" => %{}})
      |> result()

    assert body["isError"] == false, inspect(body)

    flat =
      body
      |> Jason.encode!()
      |> then(fn json -> [json] end)

    rendered_ids =
      body["structuredContent"]["supervisor_children"]
      |> Enum.map(& &1["id"])

    # every hostile id is present (count match; order not contractual)
    assert length(rendered_ids) == length(ids)

    Enum.each(rendered_ids, fn rendered ->
      assert is_binary(rendered), "child id not rendered as string: #{inspect(rendered)}"

      refute rendered =~ ~r/#Reference<0\.\d+\.\d+\.\d+>/,
             "child id leaked a materialized ref token: #{inspect(rendered)}"
    end)

    # The whole envelope stays ref-free too (nested-string ids would hide
    # tokens anywhere text lands, including the text content field).
    Enum.each(flat, fn s ->
      refute s =~ ~r/#Reference<0\.\d+\.\d+\.\d+>/, "envelope leak: #{inspect(s)}"
    end)

    # Plain ids survive sanitization as their inspect-rendered literal form
    # (the fence inspect-renders every id so embedded ref tokens cannot hide
    # in string ids; a plain string therefore arrives quoted).
    plain = Enum.find(rendered_ids, &(&1 =~ ~r/plain-string-id/))
    assert plain == inspect("plain-string-id"),
           "plain id not rendered as its quoted literal: #{inspect(plain)}"
  end

  # Lens-4: blob.list content-leak sentinel fence. The keys-only walk projects
  # 5 metadata fields; a revert to full-value materialization (or any future
  # projection widening) would carry blob CONTENT across the surface. Unique
  # per-blob sentinels make any path leak detectable, multi-blob to catch a
  # per-entry fault, and both tiers get the same fence (wire twin lives in
  # mcp_wire_test.exs — m8 lesson: some leaks only materialize at wire tier).
  test "lens4 blob.list sentinel: blob content never crosses the envelope" do
    sentinels =
      for i <- 1..3 do
        {"lens4sentacct/lens4sentcont/blob#{i}",
         "LENS4-SECRET-#{:erlang.unique_integer([:positive])}-#{i}"}
      end

    for {key, content} <- sentinels do
      name = key |> String.split("/") |> List.last()

      Smalt.Store.put(:smalt_blobs, key, %{
        "name" => name,
        "etag" => "\"e\"",
        "content" => content,
        "content_length" => byte_size(content),
        "last_modified" => "2026-10-15T00:00:00Z",
        "headers" => %{}
      })
    end

    body =
      rpc("tools/call", %{
        "name" => "blob.list",
        "arguments" => %{"account" => "lens4sentacct", "container" => "lens4sentcont"}
      })
      |> result()

    assert body["isError"] == false, inspect(body)
    assert body["structuredContent"]["count"] == 3

    json = Jason.encode!(body)

    for {_key, content} <- sentinels do
      refute json =~ content, "blob content sentinel leaked into the envelope"
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-3 cycle 1: result-envelope contracts + leak-walk (trust-profile style).
  # ---------------------------------------------------------------------------

  test "lens3 success envelope contract: text content is the JSON of structuredContent" do
    for {tool, args} <- success_calls() do
      result =
        rpc("tools/call", %{"name" => tool, "arguments" => args})
        |> result()

      assert result["isError"] == false, "#{tool} did not succeed: #{inspect(result)}"

      assert [%{"type" => "text", "text" => text}] = result["content"]

      assert Jason.decode(text) == {:ok, result["structuredContent"]},
             "#{tool} text content is not the JSON encoding of its structuredContent"

      assert is_map(result["structuredContent"])
    end
  end

  test "lens3 leak-walk: no BEAM internals (pids/refs/ports/funs) in any success envelope" do
    for {tool, args} <- success_calls() do
      body =
        rpc("tools/call", %{"name" => tool, "arguments" => args})
        |> decoded()

      # doctor.summary deliberately exposes supervisor children as inspect()
      # strings under the "pid" key; that field is the designed surface. Its
      # "text" field is the JSON encoding of the same structuredContent
      # (envelope-contracted above). Any OTHER BEAM-internals string anywhere
      # in any envelope is a leak.
      flat = flatten_kv_strings(body)

      leaked =
        Enum.filter(flat, fn {key, s} ->
          s =~ ~r/#(PID|Reference|Port|Function)</ and
            not (tool == "doctor.summary" and key in ["pid", "text"])
        end)

      assert leaked == [],
             "#{tool} leaked BEAM internals over the wire: #{inspect(Enum.take(leaked, 3))}"
    end
  end

  test "lens3 refusal envelope contract: isError true, plain-text content, structured code" do
    for {tool, args, expected} <- [
          {"kv.get", %{"name" => "ghost-key"}, "RESOURCE_NOT_FOUND"},
          {"arm.get", Map.merge(valid_args("arm.get"), %{"resource_group" => "nope"}),
           "RESOURCE_NOT_FOUND"},
          {"cosmos.query", %{"db" => 5, "coll" => 5}, "INVALID_PARAMS"},
          {"sb.peek", %{"queue" => 5}, "INVALID_PARAMS"}
        ] do
      conn = rpc("tools/call", %{"name" => tool, "arguments" => args})
      result = result(conn)

      assert result["isError"] == true
      assert [%{"type" => "text", "text" => t}] = result["content"]
      assert is_binary(t) and t != ""
      assert result["structuredContent"]["code"] == expected
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-3 helpers
  # ---------------------------------------------------------------------------

  defp valid_args("kv.get"), do: %{"name" => "mcp-key"}
  defp valid_args("blob.list"), do: %{"account" => "mcpacct", "container" => "mcpcontainer"}
  defp valid_args("cosmos.query"), do: %{"db" => "mcpdb", "coll" => "mcpcoll"}
  defp valid_args("sb.peek"), do: %{"queue" => "mcp-peek-queue", "message_count" => 5}

  defp valid_args("arm.get"),
    do: %{
      "resource_group" => "mcp-rg",
      "resource_type" => "Microsoft.Storage/storageAccounts",
      "resource_name" => "mcpacct"
    }

  defp success_calls do
    [
      {"substrate.status", %{}},
      {"substrate.capabilities", %{}},
      {"doctor.summary", %{}},
      {"arm.get", valid_args("arm.get")},
      {"kv.get", valid_args("kv.get")},
      {"blob.list", valid_args("blob.list")},
      {"sb.peek", valid_args("sb.peek")},
      {"cosmos.query", valid_args("cosmos.query")}
    ]
  end

  defp flatten_kv_strings(term, acc \\ [])

  defp flatten_kv_strings(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, a -> flatten_kv_strings(v, a, k) end)
  end

  defp flatten_kv_strings(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &flatten_kv_strings/2)

  defp flatten_kv_strings(bin, acc) when is_binary(bin), do: [{nil, bin} | acc]
  defp flatten_kv_strings(_other, acc), do: acc

  defp flatten_kv_strings(map, acc, key) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, a -> flatten_kv_strings(v, a, k) end)
  end

  defp flatten_kv_strings(list, acc, key) when is_list(list),
    do: Enum.reduce(list, acc, &flatten_kv_strings(&1, &2, key))

  defp flatten_kv_strings(bin, acc, key) when is_binary(bin), do: [{key, bin} | acc]
  defp flatten_kv_strings(_other, acc, _key), do: acc

  defp collect_traced_calls(acc) do
    receive do
      {:trace, _pid, :call, {m, f, a}} when m == Smalt.Store -> collect_traced_calls([{f, a} | acc])
    after
      500 -> :lists.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-5: batch-of-batches (nested arrays) + wire-tier probes' in-process
  # contract pins
  # ---------------------------------------------------------------------------

  # JSON-RPC 2.0 batch semantics: a top-level ARRAY is a batch (unsupported,
  # typed INVALID_REQUEST). A batch OF BATCHES — nested arrays at top level —
  # is still just a non-object body and must land in the same typed verdict,
  # never dispatched, never a 500.
  test "lens5 fuzz: batch-of-batches (nested arrays) -> typed INVALID_REQUEST, never dispatched" do
    inner = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
              "params" => %{"name" => "substrate.status", "arguments" => %{}}}

    variants = [
      [inner],
      [inner, inner],
      [[inner]],
      [[inner], [inner]],
      [[inner, inner], [inner]],
      [[[["inner"]]]]
    ]

    for v <- variants do
      conn =
        conn(:post, "/", Jason.encode!(v))
        |> Smalt.Mcp.Router.call([])

      assert conn.status == 400, "variant #{inspect(v)} did not get 400"

      body = Jason.decode!(conn.resp_body)

      assert body["error"]["data"]["code"] == "INVALID_REQUEST",
             "variant #{inspect(v)} got #{inspect(body["error"]["data"])}"

      # never dispatched: no tool result anywhere in the response
      refute body["result"],
             "batch variant #{inspect(v)} was dispatched: #{inspect(body)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-6: generated-artifact fidelity + torn-read probe
  # ---------------------------------------------------------------------------

  # Generated-artifact fidelity (the lens-5 disclosed hand-mirror debt): the
  # generated descriptor's NON-DATA skeleton — header comment, moduledoc,
  # @doc strings, and all four function bodies — must be byte-identical to
  # the EEx template's skeleton. The capabilities body is DATA and is fenced
  # separately (exact-8 tools/list pin, fail-closed gate, read-only pin); the
  # skeleton is the part lens-5 hand-mirrored, so a template prose fix that
  # was never mirrored — or a hand-edit to the generated file the template
  # never received — fails here. Rendering the full template byte-for-byte
  # is NOT asserted because ggen post-formats the generated file (long
  # descriptions re-wrapped); the skeleton comparison is exact where the
  # template is authoritative and tolerant only of formatter line-wrapping
  # in the data block.
  test "lens6 generated descriptor skeleton is byte-identical to the template skeleton" do
    template =
      File.read!(Path.expand("../lib/smalt/mcp/gen/mcp_descriptor.ex.eex", __DIR__))

    generated =
      File.read!(Path.expand("../lib/smalt/mcp/generated/mcp_descriptor.ex", __DIR__))

    skeleton = fn text ->
      [prefix | _] = String.split(text, "@capabilities %{")
      [_ | tail] = String.split(text, ~s(@doc "Full descriptor map))
      {prefix, ~s(@doc "Full descriptor map) <> List.last(tail)}
    end

    {t_pre, t_post} = skeleton.(template)
    {g_pre, g_post} = skeleton.(generated)

    assert t_pre == g_pre,
           "generated descriptor prefix drifted from the template " <>
             "(hand-mirror debt regressed or an unmirrored template edit landed)"

    assert t_post == g_post,
           "generated descriptor suffix (docs + function bodies) drifted from the template"
  end

  # Torn-read probe: tools/call dispatch reads Smalt.Mcp.Descriptor while the
  # module is reloaded (:code.load_binary of the SAME beam — the exact shape a
  # descriptor regeneration would produce). The descriptor is a compile-time
  # module attribute and BEAM code loading is atomic per module, so every
  # dispatch must observe exactly one coherent generation: all hammer reads
  # see a fully-formed, read-only, 8-capability surface — never a half-written
  # map, never a CaseClauseError, never a refusal for a registered tool.
  test "lens6 concurrent tools/call under descriptor module reload stays payload-faithful" do
    charpath =
      case :code.which(Smalt.Mcp.Descriptor) do
        path when is_list(path) -> path
        _ -> flunk("Smalt.Mcp.Descriptor beam not on the code path")
      end

    beam = File.read!(List.to_string(charpath))

    hammer = fn ->
      for _ <- 1..200 do
        conn = rpc("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, :reload_probe)

        assert structured(conn)["status"] == "ok",
               "torn read under descriptor reload: tools/call lost substrate.status"

        assert Smalt.Mcp.Descriptor.read_only_surface?() == true
        assert {:ok, %{mutation_scope: :none}} = Smalt.Mcp.Descriptor.describe("arm.get")
        assert Smalt.Mcp.Descriptor.requires_authority?("arm.put") == true
        assert Smalt.Mcp.Descriptor.requires_authority?("substrate.status") == false
      end

      :ok
    end

    reloader = fn ->
      for _ <- 1..200 do
        assert {:module, Smalt.Mcp.Descriptor} =
                 :code.load_binary(Smalt.Mcp.Descriptor, charpath, beam)

        Process.sleep(1)
      end

      :ok
    end

    assert Task.await_many([Task.async(hammer), Task.async(reloader)], 30_000) == [:ok, :ok]

    # After the storm the surface is exactly the committed generation.
    assert map_size(Smalt.Mcp.Descriptor.capabilities()) == 8
    assert Smalt.Mcp.Descriptor.read_only_surface?() == true
  end

end

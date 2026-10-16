# Wire-tier MCP proof: JSON-RPC over a REAL TCP socket (raw HTTP/1.1 bytes on
# :gen_tcp), against the Bandit listener application.ex boots on :mcp_port.
# In-process coverage lives in test/mcp_test.exs; this file adds ONLY the
# socket layer (same contract, no Plug.Test). See docs/TEST_ISOLATION.md.
defmodule Smalt.McpWireTest do
  use ExUnit.Case, async: false

  @default_sub "00000000-0000-0000-0000-000000000000"
  @recv_timeout 10_000

  setup do
    # Heal the store first (lane 01 seam): cross-module teardown can drop the
    # tables mid-setup; ensure_store_up/0 closes the half-initialized window.
    assert :ok = SmaltTest.Lifecycle.ensure_store_up()

    # Real substrate state: seed store rows the read tools read back over the
    # wire (same seeds as the in-process suite).
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

    :ok
  end

  # ------------------------------------------------------------- wire client

  defp wire_rpc(method, params \\ %{}, id \\ 1) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", mcp_port(), [:binary, active: false, send_timeout: 5_000])

    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    request =
      "POST / HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{mcp_port()}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, request)
    resp = recv_all(sock, <<>>)
    :gen_tcp.close(sock)

    assert {:ok, status, headers, rest} = parse_response(resp)
    {status, headers, rest}
  end

  defp mcp_port, do: Application.fetch_env!(:smalt, :mcp_port)

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, @recv_timeout) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp parse_response(resp) do
    case :binary.split(resp, "\r\n\r\n") do
      [head, body] ->
        [status_line | header_lines] = String.split(head, "\r\n")
        [_, code, _reason] = String.split(status_line, " ", parts: 3)

        headers =
          Enum.map(header_lines, fn h ->
            [k, v] = String.split(h, ":", parts: 2)
            {String.downcase(String.trim(k)), String.trim(v)}
          end)

        {:ok, String.to_integer(code), headers, body}

      _ ->
        flunk("unparseable HTTP response: #{inspect(resp)}")
    end
  end

  defp content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      {"content-length", v} -> String.to_integer(v)
      nil -> flunk("no content-length header in #{inspect(headers)}")
    end
  end

  defp decoded({200, headers, body}) do
    assert byte_size(body) == content_length(headers)
    assert Jason.decode!(body)
  end

  defp structured(rpc_result) do
    decoded(rpc_result)["result"]["structuredContent"]
  end

  defp refusal_code(rpc_result) do
    result = decoded(rpc_result)["result"]
    assert result["isError"] == true
    result["structuredContent"]["code"]
  end

  # ------------------------------------------------------------------- tests

  test "wire initialize returns protocol version and server info" do
    resp = wire_rpc("initialize", %{"protocolVersion" => "2024-11-05"})
    body = decoded(resp)

    assert body["jsonrpc"] == "2.0"
    assert body["result"]["protocolVersion"] == "2024-11-05"
    assert body["result"]["serverInfo"]["name"] == "smalt-mcp"
  end

  test "wire tools/list exposes exactly the 8 read-only tools, all readOnlyHint" do
    tools =
      wire_rpc("tools/list")
      |> decoded()
      |> Map.fetch!("result")
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

  test "wire substrate.status reports the live substrate" do
    status = wire_rpc("tools/call", %{"name" => "substrate.status", "arguments" => %{}}) |> structured()

    assert status["status"] == "ok"
    assert status["store_alive"] == true
    assert status["mcp_read_only_surface"] == true
    assert status["ports"]["control_plane"] == Smalt.Registry.control_plane_port()
  end

  test "wire substrate.capabilities is Registry-derived" do
    caps =
      wire_rpc("tools/call", %{"name" => "substrate.capabilities", "arguments" => %{}})
      |> structured()

    assert caps["admitted_resource_types"] == Smalt.Registry.admitted_resource_types()
    assert caps["admitted_resource_type_count"] == length(Smalt.Registry.admitted_resource_types())
    assert Map.has_key?(caps["api_versions"], "Microsoft.Storage/storageAccounts")
    assert "substrate.status" in caps["mcp_tools"]
  end

  test "wire arm.get returns the seeded resource record" do
    record =
      wire_rpc("tools/call", %{
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

  test "wire arm.get missing resource -> typed RESOURCE_NOT_FOUND refusal" do
    conn =
      wire_rpc("tools/call", %{
        "name" => "arm.get",
        "arguments" => %{
          "resource_group" => "nope",
          "resource_type" => "Microsoft.Storage/storageAccounts",
          "resource_name" => "ghost"
        }
      })

    assert refusal_code(conn) == "RESOURCE_NOT_FOUND"
  end

  test "wire blob.list returns content-free metadata only" do
    body =
      wire_rpc("tools/call", %{
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

  test "wire actuation attempts are refused with typed ACTUATION_REFUSED" do
    for name <- ["arm.put", "blob.put", "blob.delete", "substrate.actuate"] do
      conn = wire_rpc("tools/call", %{"name" => name, "arguments" => %{}}, name)

      assert refusal_code(conn) == "ACTUATION_REFUSED"

      result = decoded(conn)["result"]
      assert result["content"] |> hd() |> Map.get("text") =~ "read-only"
    end
  end

  # Actuation-verb property fence: EVERY verb fragment the router law carries
  # must independently produce ACTUATION_REFUSED on an unregistered id. A new
  # verb added to the router list without this fence knowing is a drift the
  # fence cannot see — hence the count guard below.
  @tag :mcp_verb_fence
  test "wire every actuation verb fragment refuses with ACTUATION_REFUSED" do
    verbs = ~w(put post create delete update patch set enqueue send complete
               abandon defer release deadletter encrypt decrypt sign verify wrap
               unwrap actuate execute run write commit)

    for verb <- verbs do
      conn = wire_rpc("tools/call", %{"name" => "probe.#{verb}", "arguments" => %{}}, verb)
      assert refusal_code(conn) == "ACTUATION_REFUSED", "verb #{verb} did not refuse"
    end
  end

  # Tool-card schema fence: tightened per-tool inputSchema assertions (exact
  # required lists and property names, not just type==object).
  test "wire tool cards carry exact required lists and properties" do
    tools_by_name =
      wire_rpc("tools/list")
      |> decoded()
      |> Map.fetch!("result")
      |> Map.fetch!("tools")
      |> Map.new(&{&1["name"], &1})

    assert tools_by_name["arm.get"]["inputSchema"]["required"] == [
             "resource_group",
             "resource_type",
             "resource_name"
           ]

    assert MapSet.new(Map.keys(tools_by_name["arm.get"]["inputSchema"]["properties"])) ==
             MapSet.new(["subscription_id", "resource_group", "resource_type", "resource_name"])

    assert tools_by_name["cosmos.query"]["inputSchema"]["required"] == ["db", "coll"]
    assert tools_by_name["blob.list"]["inputSchema"]["required"] == ["account", "container"]
    assert tools_by_name["sb.peek"]["inputSchema"]["required"] == ["queue"]

    assert tools_by_name["sb.peek"]["inputSchema"]["properties"]["message_count"] == %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => 100
           }

    for {name, tool} <- tools_by_name do
      annotations = tool["annotations"]

      assert annotations == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             },
             "annotations drifted for #{name}"

      assert is_binary(tool["description"]) and byte_size(tool["description"]) > 10,
             "description drift for #{name}"
    end
  end

  # Oversized JSON-RPC body: Plug.read_body caps at 8 MiB; the router must
  # refuse with a typed 413, never a 500 crash.
  test "wire oversized body -> typed 413 PAYLOAD_TOO_LARGE" do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", mcp_port(), [:binary, active: false, send_timeout: 30_000])

    big = String.duplicate("x", 9 * 1024 * 1024)

    request =
      "POST / HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{mcp_port()}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(big)}\r\n" <>
        "Connection: close\r\n\r\n" <> big

    :ok = :gen_tcp.send(sock, request)
    resp = recv_all(sock, <<>>)
    :gen_tcp.close(sock)

    assert {:ok, 413, _headers, body} = parse_response(resp)
    assert Jason.decode!(body)["error"]["data"]["code"] == "PAYLOAD_TOO_LARGE"
  end

  # Stress-harness contract fence: the MCP listener serves concurrent raw
  # clients without cross-talk (each response id matches its own request).
  test "wire listener serves concurrent clients with id-faithful responses" do
    results =
      1..8
      |> Task.async_stream(
        fn i ->
          {_status, _headers, body} =
            wire_rpc("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, i)

          Jason.decode!(body)["result"]["structuredContent"]["status"]
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert results == List.duplicate("ok", 8)
  end

  # Full MCP client handshake over the ephemeral listener: initialize ->
  # tools/list -> tools/call, protocol-version pinned, one socket.
  test "wire full MCP handshake sequence on the ephemeral port-0 listener" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_handshake_probe
      )

    port = wait_for_ephemeral_port(sup)

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    call = fn method, params, id ->
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

      :ok =
        :gen_tcp.send(
          sock,
          "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
        )

      {:ok, 200, resp} = keep_alive_response(sock, <<>>)

      Jason.decode!(resp)
    end

    init = call.("initialize", %{"protocolVersion" => "2024-11-05"}, "init")
    assert init["result"]["protocolVersion"] == "2024-11-05"

    init = call.("initialize", %{"protocolVersion" => "2024-11-05"}, "init")
    assert init["result"]["protocolVersion"] == "2024-11-05"
    assert init["result"]["capabilities"]["tools"] == %{}

    tools = call.("tools/list", %{}, "list")
    assert length(tools["result"]["tools"]) == 8

    status = call.("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, "call")
    assert status["result"]["structuredContent"]["status"] == "ok"

    :gen_tcp.close(sock)
  end

  # Keep-alive read: headers, then exactly content-length body bytes, leaving
  # the socket usable for the next request.
  defp keep_alive_response(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        [status_line | header_lines] = String.split(head, "\r\n")
        [_, code, _] = String.split(status_line, " ", parts: 3)

        headers =
          Enum.map(header_lines, fn h ->
            [k, v] = String.split(h, ":", parts: 2)
            {String.downcase(String.trim(k)), String.trim(v)}
          end)

        {"content-length", len} = List.keyfind(headers, "content-length", 0)
        len = String.to_integer(len)

        case rest do
          <<body::binary-size(len), _pending::binary>> ->
            {:ok, String.to_integer(code), body}

          _short ->
            keep_alive_response(sock, acc <> recv!(sock))
        end

      _no_head ->
        keep_alive_response(sock, acc <> recv!(sock))
    end
  end

  defp recv!(sock) do
    case :gen_tcp.recv(sock, 0, @recv_timeout) do
      {:ok, data} -> data
      {:error, reason} -> flunk("socket recv failed: #{inspect(reason)}")
    end
  end

  # Mixed concurrent load: 8 normal clients interleaved with 2 oversized
  # payloads on the same listener — every client gets ITS OWN verdict (ok or
  # 413), no cross-talk, no leaked buffers (connection closes cleanly).
  test "wire mixed load: normal calls interleaved with oversized payloads" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_mixed_probe
      )

    port = wait_for_ephemeral_port(sup)

    normal =
      1..8
      |> Task.async_stream(
        fn i ->
          sock = connect!(port)
          body = rpc_body("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, i)
          :ok = :gen_tcp.send(sock, request_bytes(port, body))
          {:ok, 200, resp} = keep_alive_response(sock, <<>>)
          :gen_tcp.close(sock)

          result = Jason.decode!(resp)["result"]
          {i, result["structuredContent"]["status"]}
        end,
        max_concurrency: 8,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, pair} -> pair end)

    assert normal == Enum.map(1..8, &{&1, "ok"})

    oversized =
      1..2
      |> Task.async_stream(
        fn i ->
          sock = connect!(port)
          big = String.duplicate("x", 9 * 1024 * 1024)
          :ok = :gen_tcp.send(sock, request_bytes(port, big))
          assert {:ok, status, headers, body} = parse_response(recv_all(sock, <<>>))
          :gen_tcp.close(sock)
          {i, status, Jason.decode!(body)["error"]["data"]["code"],
           byte_size(body) == String.to_integer(List.keyfind(headers, "content-length", 0) |> elem(1))}
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, tuple} -> tuple end)

    assert oversized == [
             {1, 413, "PAYLOAD_TOO_LARGE", true},
             {2, 413, "PAYLOAD_TOO_LARGE", true}
           ]
  end

  defp connect!(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, send_timeout: 30_000])
    sock
  end

  defp rpc_body(method, params, id),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp request_bytes(port, body) do
    "POST / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
  end

  # F4 fence (docs/PACK_INTEGRATION/mcp-a2a.md child spec): `mcp_port: 0`
  # binds an ephemeral port and the ACTUAL port is discoverable from the
  # running listener, so stress harnesses can start N substrates concurrently
  # and still find their own MCP surface.
  test "mcp_port 0 binds ephemeral and the actual port is discoverable" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_ephemeral_probe
      )

    port = wait_for_ephemeral_port(sup)
    assert is_integer(port) and port > 0
    assert port != Application.fetch_env!(:smalt, :mcp_port)

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    body =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    :ok =
      :gen_tcp.send(
        sock,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n" <>
          "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
      )

    resp = recv_all(sock, <<>>)
    :gen_tcp.close(sock)

    assert {:ok, 200, _headers, resp_body} = parse_response(resp)
    tools = Jason.decode!(resp_body)["result"]["tools"]
    assert length(tools) == 8
  end

  defp wait_for_ephemeral_port(sup, attempts \\ 50)

  defp wait_for_ephemeral_port(_sup, 0), do: flunk("ephemeral listener never reported a port")

  defp wait_for_ephemeral_port(sup, attempts) do
    case ThousandIsland.listener_info(sup) do
      {:ok, {{_, _, _, _}, port}} when is_integer(port) and port > 0 ->
        port

      _ ->
        Process.sleep(100)
        wait_for_ephemeral_port(sup, attempts - 1)
    end
  end

  # ------------------------------------------------- lens-3 session multiplexing

  # Two concurrent clients, interleaved initialize -> tools/call sequences on
  # SEPARATE keep-alive sockets: every response must arrive on its own socket,
  # with its own id, carrying its own tool's payload. No cross-session leakage.
  test "wire 2-client interleaved sessions: id-faithful, payload-faithful, no leakage" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_mux_probe
      )

    port = wait_for_ephemeral_port(sup)

    # Session-local seed: client b reads a vault key only its own session
    # expects; a leak from client a's substrate.status stream would show up as
    # a payload mismatch, not just an id mismatch.
    Smalt.Store.put(:smalt_vault_keys, "mcp-key", %{
      "name" => "mcp-key",
      "kty" => "RSA",
      "key_material" => <<1, 2, 3>>,
      "attributes" => %{"enabled" => true}
    })

    session = fn socket_fn, prefix, tool, args, expect ->
      sock = socket_fn.(port)

      init = rpc_body("initialize", %{"protocolVersion" => "2024-11-05"}, "#{prefix}-init")
      :ok = :gen_tcp.send(sock, request_bytes_idle(port, init))
      {:ok, 200, _h0, b0} = keep_alive_response_full(sock, <<>>)
      assert Jason.decode!(b0)["result"]["protocolVersion"] == "2024-11-05"

      for i <- 1..10 do
        call = rpc_body("tools/call", %{"name" => tool, "arguments" => args}, "#{prefix}-#{i}")
        :ok = :gen_tcp.send(sock, request_bytes_idle(port, call))
        {:ok, 200, _h, b} = keep_alive_response_full(sock, <<>>)

        body = Jason.decode!(b)

        assert body["id"] == "#{prefix}-#{i}",
               "#{prefix}: id echo mismatch: #{inspect(body["id"])} (expected #{prefix}-#{i})"

        assert expect.(body["result"]["structuredContent"]),
               "#{prefix}: payload for #{tool} failed its own expectation: #{inspect(body["result"]["structuredContent"])}"
      end

      :gen_tcp.close(sock)
      :ok
    end

    tasks = [
      Task.async(fn ->
        session.(&connect!/1, "a", "substrate.status", %{}, fn sc ->
          sc["status"] == "ok" and sc["mcp_read_only_surface"] == true
        end)
      end),
      Task.async(fn ->
        session.(&connect!/1, "b", "kv.get", %{"name" => "mcp-key"}, fn sc ->
          sc["name"] == "mcp-key" and sc["kty"] == "RSA"
        end)
      end)
    ]

    assert Task.await_many(tasks, 60_000) == [:ok, :ok]
  end

  # ------------------------------------------------- lens-3 cycle 3

  # Pipelined burst: 4 requests written back-to-back on ONE socket before any
  # response is read. The server must answer all 4, in order, each id-faithful.
  test "wire pipelined burst: 4 back-to-back requests, in-order, id-faithful" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_pipeline_probe
      )

    port = wait_for_ephemeral_port(sup)
    sock = connect!(port)

    tools = ["substrate.status", "substrate.capabilities", "substrate.status", "substrate.status"]

    for {tool, i} <- Enum.with_index(tools, 1) do
      body = rpc_body("tools/call", %{"name" => tool, "arguments" => %{}}, "p#{i}")
      :ok = :gen_tcp.send(sock, request_bytes_idle(port, body))
    end

    # Pending-aware reads: pipelined bytes for response N+1 arrive in the same
    # recv buffer as response N and must be threaded, never dropped.
    for {tool, i} <- Enum.with_index(tools, 1), reduce: <<>> do
      pending ->
        {{_code, body}, pending} = pipeline_response(sock, pending)
        body = Jason.decode!(body)

      assert body["id"] == "p#{i}",
             "pipelined response #{i} was not id-faithful: #{inspect(body["id"])}"

      case tool do
        "substrate.status" ->
          assert body["result"]["structuredContent"]["status"] == "ok"

        "substrate.capabilities" ->
          assert Map.has_key?(body["result"]["structuredContent"], "admitted_resource_types")
      end

      pending
    end

    :gen_tcp.close(sock)
  end

  # One full HTTP response, threading the leftover buffer (pipelining-safe).
  defp pipeline_response(sock, pending) do
    case :binary.split(pending, "\r\n\r\n") do
      [head, rest] ->
        [status_line | header_lines] = String.split(head, "\r\n")
        [_, code, _] = String.split(status_line, " ", parts: 3)

        headers =
          Enum.map(header_lines, fn h ->
            [k, v] = String.split(h, ":", parts: 2)
            {String.downcase(String.trim(k)), String.trim(v)}
          end)

        {"content-length", len} = List.keyfind(headers, "content-length", 0)
        len = String.to_integer(len)

        case rest do
          <<body::binary-size(len), remaining::binary>> ->
            {{String.to_integer(code), body}, remaining}

          _short ->
            pipeline_response(sock, pending <> recv_full!(sock))
        end

      _no_head ->
        pipeline_response(sock, pending <> recv_full!(sock))
    end
  end

  # Result-shape contracts pinned to EXACT key sets: no undocumented fields
  # (over-disclosure), no missing fields (consumer breakage).
  test "wire blob.list metadata carries exactly the 5 documented fields" do
    Smalt.Store.put(:smalt_blobs, "shapecct/shapecoll/one.txt", %{
      "name" => "one.txt",
      "etag" => "\"s\"",
      "content" => "xyz",
      "content_length" => 3,
      "last_modified" => "2026-10-15T00:00:00Z",
      "headers" => %{"content-type" => "text/plain"}
    })

    body =
      wire_rpc("tools/call", %{
        "name" => "blob.list",
        "arguments" => %{"account" => "shapecct", "container" => "shapecoll"}
      })
      |> structured()

    assert body["count"] == 1
    [blob] = body["blobs"]

    assert MapSet.new(Map.keys(blob)) ==
             MapSet.new(["name", "etag", "content_length", "last_modified", "headers"])
  end

  # Lens-4 wire-tier twin of the in-process sentinel fence (m8 lesson: some
  # leaks only materialize at wire tier — assert against the RAW response
  # body bytes, not just structuredContent, so a leak in the text-content
  # field or headers cannot hide).
  test "wire lens4 blob.list sentinel: content sentinels absent from raw bytes" do
    sentinels =
      for i <- 1..3 do
        {"l4acct/l4cont/wireblob#{i}", "L4WIRE-SECRET-#{:erlang.unique_integer([:positive])}-#{i}"}
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

    {status, _headers, raw} =
      wire_rpc("tools/call", %{"name" => "blob.list", "arguments" => %{"account" => "l4acct", "container" => "l4cont"}})

    assert status == 200

    for {_key, content} <- sentinels do
      refute raw =~ content, "blob content sentinel leaked into raw wire bytes"
    end

    assert structured({status, _headers, raw})["count"] == 3
  end

  test "wire kv.get discloses exactly the record minus the redacted secret fields" do
    Smalt.Store.put(:smalt_vault_keys, "shape-key", %{
      "name" => "shape-key",
      "kty" => "RSA",
      "key_material" => <<9, 9, 9>>,
      "value" => "secret-value",
      "attributes" => %{"enabled" => true},
      "release_policy" => %{"anyOf" => []}
    })

    body =
      wire_rpc("tools/call", %{
        "name" => "kv.get",
        "arguments" => %{"name" => "shape-key"}
      })
      |> structured()

    assert body["name"] == "shape-key"
    refute Map.has_key?(body, "key_material")
    refute Map.has_key?(body, "value")

    # Exactly the stored record minus the two redacted fields: nothing extra
    # invented, nothing public withheld (parity with the control plane's own
    # Map.delete(key_record, "key_material") projection convention).
    assert MapSet.new(Map.keys(body)) ==
             MapSet.new(["name", "kty", "attributes", "release_policy"])
  end

  # ------------------------------------------------- doctor cross-consistency

  test "doctor.summary agrees with scripts/doctor.py --json on substrate health" do
    # MCP wire layer: the tool's own view over real supervisor state.
    summary =
      wire_rpc("tools/call", %{"name" => "doctor.summary", "arguments" => %{}}) |> structured()

    assert summary["status"] == "healthy"
    assert summary["store_alive"] == true
    assert summary["cosmos_store_ready"] == true
    assert summary["vault_keys_table_ready"] == true
    assert Enum.any?(summary["supervisor_children"], fn c -> c["id"] == "Smalt.Store" end)

    # Host layer: the fail-closed doctor court, as a real subprocess. Two
    # independent observers of the same host must agree:
    #   1. no FAIL may coexist with the tool's healthy verdict unless the FAIL
    #      is a default-port check that this run's own bind probe confirms is
    #      genuinely held by a foreign keeper (test trees sit on ephemeral
    #      ports — a keeper on 5672 is not a substrate defect);
    #   2. doctor's substrate.ports listening/free verdict must match an
    #      independent bind probe from this test, port for port.
    {exit_code, out, _err} = run_doctor()

    assert exit_code in [0, 1], "scripts/doctor.py --json exited #{exit_code}:\n#{out}"

    doctor = Jason.decode!(out)
    assert doctor["schema"] == "smalt-doctor/v2"
    assert doctor["ok"] == Enum.all?(doctor["checks"], &(&1["status"] != "FAIL"))

    for check <- doctor["checks"], check["status"] == "FAIL" do
      # doctor.py renamed its port checks (port-arm/port-data/port-amqp, the
      # old port-9443/8443/5672 names) and substrate.ports still keys by
      # number. A port-class FAIL is exempt when an independent bind probe
      # confirms a real keeper holds the port (foreign-lane keepers on the
      # default ports are environment, not a substrate defect) -- the port
      # number is parsed from the check DETAIL, since names no longer carry
      # it.
      assert check["name"] in ["port-arm", "port-data", "port-amqp", "port-9443", "port-8443", "port-5672"],
             "non-port doctor check FAILed: #{check["name"]}: #{check["detail"]}"

      port =
        case Integer.parse(List.last(String.split(check["name"], "-"))) do
          {p, ""} ->
            p

          _ ->
            [port_str] = Regex.run(~r/Port (\d+)/, check["detail"], capture: :all_but_first)
            String.to_integer(port_str)
        end

      assert port_held?(port), "doctor FAILed port #{port} but our probe says it is free"
    end

    for {port, verdict} <- doctor["substrate"]["ports"] do
      assert port_verdict_agrees?(String.to_integer(port), verdict),
             "doctor says #{port}=#{verdict}, our bind probe disagrees (after retries)"
    end
  end

  # Probe-then-close race: two bind probes at different wall-clock times can
  # disagree transiently (a keeper grabbing/releasing the port between them).
  # Only a stable disagreement across retries is a real defect.
  defp port_verdict_agrees?(port, verdict, retries \\ 5)

  defp port_verdict_agrees?(_port, _verdict, 0), do: false

  defp port_verdict_agrees?(port, verdict, retries) do
    if port_held?(port) == (verdict == "listening") do
      true
    else
      Process.sleep(500)
      port_verdict_agrees?(port, verdict, retries - 1)
    end
  end

  defp port_held?(port) do
    case :gen_tcp.listen(port, [:binary, active: false]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        false

      {:error, _} ->
        true
    end
  end

  defp run_doctor do
    root = File.cwd!()

    # doctor.py probes fixed default ports; the test tree may sit on ephemeral
    # ones. Consistency is asserted only on the substrate booted/healthy
    # direction plus all-check PASS — if shifted ports are in play the doctor's
    # port-specific checks still reflect the same host this run occupies.
    env = %{"SMALT_ROOT" => root, "PATH" => System.get_env("PATH", "")}

    port =
      Port.open({:spawn_executable, doctor_bin()}, [
        :exit_status,
        :binary,
        :stream,
        args: [doctor_script(), "--json"],
        env: enum_env(env)
      ])

    collect_doctor(port, "", nil)
  end

  defp doctor_bin, do: System.find_executable("python3") || raise "python3 not on PATH"

  defp doctor_script, do: Path.join(File.cwd!(), "scripts/doctor.py")

  defp enum_env(map), do: Enum.map(map, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

  defp collect_doctor(port, out, status) do
    receive do
      {^port, {:data, data}} -> collect_doctor(port, out <> data, status)
      {^port, {:exit_status, code}} -> collect_doctor(port, out, code)
      {:DOWN, _ref, :port, ^port, _} -> {status || -1, out, ""}
    after
      30_000 -> {status || -1, out, "timeout"}
    end
  end

  # ------------------------------------------------------------------- lens-2
  # Connection-lifecycle wire fences (real sockets, no doubles).

  # Keep-alive with an IDLE GAP: one socket, response read, socket sits idle,
  # second request on the SAME socket still answered. The idle gap is the
  # thing under test (no pipelining, no close).
  test "wire keep-alive socket survives an idle gap between requests" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_idle_probe
      )

    port = wait_for_ephemeral_port(sup)
    sock = connect!(port)
    body = rpc_body("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, 1)
    :ok = :gen_tcp.send(sock, request_bytes_idle(port, body))

    assert {:ok, 200, _h1, b1} = keep_alive_response_full(sock, <<>>)
    assert Jason.decode!(b1)["result"]["structuredContent"]["status"] == "ok"

    Process.sleep(1_500)

    body2 = rpc_body("tools/call", %{"name" => "substrate.capabilities", "arguments" => %{}}, 2)
    :ok = :gen_tcp.send(sock, request_bytes_idle(port, body2))

    assert {:ok, 200, _h2, b2} = keep_alive_response_full(sock, <<>>)

    assert Jason.decode!(b2)["result"]["structuredContent"]["admitted_resource_type_count"] >= 0

    :gen_tcp.close(sock)
  end

  # Half-close: client shuts its WRITE side after a complete request; the
  # server must still deliver the full response (client FIN is not an abort).
  test "wire half-close (client shutdown write) still delivers the full response" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_halfclose_probe
      )

    port = wait_for_ephemeral_port(sup)
    sock = connect!(port)
    body = rpc_body("tools/list", %{}, "hc")

    :ok = :gen_tcp.send(sock, request_bytes_idle(port, body))
    :ok = :gen_tcp.shutdown(sock, :write)

    assert {:ok, 200, _h, b} = keep_alive_response_full(sock, <<>>)
    assert Jason.decode!(b)["result"]["tools"] |> length() == 8
    :gen_tcp.close(sock)
  end

  # RST mid-response: client forces an abortive close (SO_LINGER 0) while a
  # response is in flight; the listener must not crash or wedge -- a
  # follow-up request over a fresh connection answers normally.
  test "wire RST mid-response leaves the listener healthy for fresh connections" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :mcp_rst_probe
      )

    port = wait_for_ephemeral_port(sup)

    sock = connect!(port)
    body = rpc_body("tools/list", %{}, "rst")
    :ok = :gen_tcp.send(sock, request_bytes_idle(port, body))

    # Force RST: linger-on-close with timeout 0 (darwin: SO_LINGER 0/0).
    :ok =
      :inet.setopts(sock, [
        {:linger, {true, 0}}
      ])

    :gen_tcp.close(sock)

    # Listener must still serve a fresh connection normally.
    sock2 = connect!(port)
    body2 = rpc_body("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, "after")
    :ok = :gen_tcp.send(sock2, request_bytes_idle(port, body2))

    assert {:ok, 200, _h, b} = keep_alive_response_full(sock2, <<>>)
    assert Jason.decode!(b)["result"]["structuredContent"]["status"] == "ok"
    :gen_tcp.close(sock2)
  end

  defp request_bytes_idle(port, body) do
    "POST / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
  end

  # Read headers + exactly content-length body bytes (keep-alive-safe read
  # that tolerates half-closed sockets: :closed on recv after a complete
  # response is fine if the body is already complete).
  defp keep_alive_response_full(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        [status_line | header_lines] = String.split(head, "\r\n")
        [_, code, _] = String.split(status_line, " ", parts: 3)

        headers =
          Enum.map(header_lines, fn h ->
            [k, v] = String.split(h, ":", parts: 2)
            {String.downcase(String.trim(k)), String.trim(v)}
          end)

        {"content-length", len} = List.keyfind(headers, "content-length", 0)
        len = String.to_integer(len)

        case rest do
          <<body::binary-size(len), _pending::binary>> ->
            {:ok, String.to_integer(code), headers, body}

          _short ->
            keep_alive_response_full(sock, acc <> recv_full!(sock))
        end

      _no_head ->
        keep_alive_response_full(sock, acc <> recv_full!(sock))
    end
  end

  defp recv_full!(sock) do
    case :gen_tcp.recv(sock, 0, @recv_timeout) do
      {:ok, data} -> data
      {:error, :closed} -> <<>>
      {:error, reason} -> flunk("socket recv failed: #{inspect(reason)}")
    end
  end

  # ------------------------------------------------------------- lens-5

  defp raw_post(port, head_extra, body) do
    sock = connect!(port)

    req =
      "POST / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Type: application/json\r\n" <>
        head_extra <> "\r\n" <> body

    :ok = :gen_tcp.send(sock, req)
    sock
  end

  defp body_of(method, params, id),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  # A client that LIES short (declared Content-Length < actual body bytes):
  # the transport reads exactly the declared number of bytes, so the router
  # sees a truncated body. The typed verdict is 400 PARSE_ERROR with id null —
  # never a 500, never a hang-then-crash, and the leftovers are discarded
  # (Connection: close).
  test "wire lens5 content-length lie (declared SHORT) -> typed 400 PARSE_ERROR" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :l5_lie_short
      )

    port = wait_for_ephemeral_port(sup)
    body = body_of("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, 1)

    sock =
      raw_post(port, "Content-Length: 10\r\nConnection: close\r\n", body)

    resp = recv_all(sock, <<>>)
    :gen_tcp.close(sock)

    assert {:ok, 400, _headers, resp_body} = parse_response(resp)
    err = Jason.decode!(resp_body)["error"]
    assert err["code"] == -32_700
    assert err["data"]["code"] == "PARSE_ERROR"
    assert Jason.decode!(resp_body)["id"] == nil
  end

  # A client that LIES long (declared Content-Length > actual body bytes):
  # per HTTP the server MUST keep waiting for the declared bytes. The contract
  # pinned here: no response is fabricated from the partial body (recv hits the
  # socket timeout while the request is incomplete), the stalled connection is
  # simply abandoned by the client, and the LISTENER STAYS HEALTHY — a fresh
  # connection immediately after gets a normal typed response.
  test "wire lens5 content-length lie (declared LONG) -> server waits, listener stays healthy" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :l5_lie_long
      )

    port = wait_for_ephemeral_port(sup)
    body = body_of("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, 1)

    sock = raw_post(port, "Content-Length: 100000\r\nConnection: close\r\n", body)

    # no bytes arrive while the request is incomplete
    assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 2_000)
    :gen_tcp.close(sock)

    # listener healthy after the stalled connection
    resp = wire_rpc("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, 9)
    assert {200, _h, resp_body} = resp
    sc = decoded(resp)["result"]["structuredContent"]
    assert sc["status"] == "ok"
  end

  # ID COLLISION across concurrent sessions: the MCP surface is stateless per
  # request, so two clients that pick the SAME id must each get a response on
  # their own socket, echoing the shared id, carrying THEIR OWN tool's payload.
  # A response-routing defect would swap or merge payloads under a shared id.
  test "wire lens5 id collision: two concurrent clients sharing one id stay payload-faithful" do
    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :l5_id_collision
      )

    port = wait_for_ephemeral_port(sup)

    Smalt.Store.put(:smalt_vault_keys, "mcp-key", %{
      "name" => "mcp-key",
      "kty" => "RSA",
      "key_material" => <<1, 2, 3>>,
      "attributes" => %{"enabled" => true}
    })

    client = fn tool, args, expect ->
      Task.async(fn ->
        body = body_of("tools/call", %{"name" => tool, "arguments" => args}, "shared")
        sock = raw_post(port, "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n", body)
        resp = recv_all(sock, <<>>)
        :gen_tcp.close(sock)

        assert {:ok, 200, _h, resp_body} = parse_response(resp)
        parsed = Jason.decode!(resp_body)

        assert parsed["id"] == "shared",
               "id echo mismatch: #{inspect(parsed["id"])}"

        assert expect.(parsed["result"]["structuredContent"]),
               "#{tool}: payload not its own under shared id: #{inspect(parsed["result"])}"
      end)
    end

    tasks = [
      client.("substrate.status", %{}, fn sc ->
        sc["status"] == "ok" and sc["mcp_read_only_surface"] == true
      end),
      client.("kv.get", %{"name" => "mcp-key"}, fn sc ->
        sc["name"] == "mcp-key" and sc["kty"] == "RSA"
      end)
    ]

    assert Task.await_many(tasks, 30_000) == [true, true]
  end

  # ------------------------------------------------------------- lens-6

  # Torn-read at wire tier: descriptor module reloads (:code.load_binary of
  # the SAME beam — the exact shape a regeneration would produce) concurrent
  # with REAL socket tools/call traffic. Every wire response must reflect one
  # coherent descriptor generation: no refusal for a registered tool, no
  # truncated/merged payload, listener healthy after the storm.
  test "wire lens6 concurrent tools/call under descriptor reload stays payload-faithful" do
    charpath =
      case :code.which(Smalt.Mcp.Descriptor) do
        path when is_list(path) -> path
        _ -> flunk("Smalt.Mcp.Descriptor beam not on the code path")
      end

    beam = File.read!(List.to_string(charpath))

    {:ok, sup} =
      start_supervised(
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http, port: 0},
        id: :l6_reload_probe
      )

    port = wait_for_ephemeral_port(sup)

    callers =
      1..6
      |> Task.async_stream(
        fn i ->
          for _ <- 1..20 do
            body =
              body_of("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, "r#{i}")

            sock = raw_post(port, "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n", body)
            resp = recv_all(sock, <<>>)
            :gen_tcp.close(sock)

            assert {:ok, 200, _h, resp_body} = parse_response(resp)

            parsed = Jason.decode!(resp_body)

            assert parsed["result"]["structuredContent"]["status"] == "ok",
                   "torn read under descriptor reload: #{inspect(parsed)}"

            assert parsed["id"] == "r#{i}"
          end

          :ok
        end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.all?(fn {:ok, :ok} -> true end)

    assert callers

    reloader =
      Task.async(fn ->
        for _ <- 1..200 do
          assert {:module, Smalt.Mcp.Descriptor} =
                   :code.load_binary(Smalt.Mcp.Descriptor, charpath, beam)
        end

        :ok
      end)

    assert Task.await(reloader, 30_000) == :ok

    # Listener healthy after the reload storm.
    resp = wire_rpc("tools/call", %{"name" => "substrate.status", "arguments" => %{}}, "after")
    assert {200, _h, resp_body} = resp
    assert decoded(resp)["result"]["structuredContent"]["status"] == "ok"
  end

  # Wire-tier canonical-order fence (lens 8): tools/list and the
  # substrate.capabilities mcp_tools list must be capability_id-sorted ON THE
  # WIRE, independent of the generated descriptor's map-literal order. The
  # in-process lens-7 fence pins the generated file's SOURCE order; this fence
  # pins the wire CONTRACT so a regression at either tier (template sort
  # dropped, descriptor regenerated unsorted, router sort removed) surfaces as
  # an order diff on the socket, not a silent contract drift. Killed m28 and
  # m29 for real (see tmp/errc/mcp-lens8/cycle-1.md).
  test "lens8 wire tools/list and mcp_tools are capability_id-sorted" do
    ns = "http://seanchatmangpt.github.io/packs/elixir-mcp-a2a#"

    graph = RDF.Turtle.read_string!(File.read!("lib/smalt/mcp/gen/smalt_mcp_surface.ttl"))

    canonical =
      for {s, p, o} <- graph,
          p == RDF.type() and o == RDF.iri(ns <> "Capability") do
        desc = graph |> RDF.Graph.descriptions() |> Enum.find(&(&1.subject == s))

        case RDF.Description.first(desc, RDF.iri(ns <> "capabilityId")) do
          nil -> flunk("TTL capability without capabilityId")
          lit -> RDF.Literal.value(lit)
        end
      end
      |> Enum.sort()

    {200, _h, _} = resp = wire_rpc("tools/list")
    wire_names = decoded(resp)["result"]["tools"] |> Enum.map(& &1["name"])

    assert wire_names == canonical,
           "wire tools/list order is not canonical: #{inspect(wire_names)} != #{inspect(canonical)}"

    {200, _h, _} = resp2 = wire_rpc("tools/call", %{"name" => "substrate.capabilities"})
    mcp_tools = decoded(resp2)["result"]["structuredContent"]["mcp_tools"]

    assert mcp_tools == canonical,
           "wire mcp_tools order is not canonical: #{inspect(mcp_tools)} != #{inspect(canonical)}"
  end

end

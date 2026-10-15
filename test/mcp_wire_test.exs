# Wire-tier MCP proof: JSON-RPC over a REAL TCP socket (raw HTTP/1.1 bytes on
# :gen_tcp), against the Bandit listener application.ex boots on :mcp_port.
# In-process coverage lives in test/mcp_test.exs; this file adds ONLY the
# socket layer (same contract, no Plug.Test). See docs/TEST_ISOLATION.md.
defmodule Smalt.McpWireTest do
  use ExUnit.Case, async: false

  @default_sub "00000000-0000-0000-0000-000000000000"
  @recv_timeout 10_000

  setup do
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
      assert check["name"] in ["port-9443", "port-8443", "port-5672"],
             "non-port doctor check FAILed: #{check["name"]}: #{check["detail"]}"

      {port, _} = Integer.parse(List.last(String.split(check["name"], "-")))
      assert port_held?(port), "doctor FAILed port #{port} but our probe says it is free"
    end

    for {port, verdict} <- doctor["substrate"]["ports"] do
      assert verdict == if(port_held?(String.to_integer(port)), do: "listening", else: "free"),
             "doctor says #{port}=#{verdict}, our bind probe disagrees"
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
end

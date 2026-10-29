defmodule PopcornDemo.LiveMcpTest do
  @moduledoc """
  Chicago tests for the MCP tool-surface walk (lane W3-5). Real
  collaborators only: the live substrate MCP plane on 9545 over the real
  `PopcornDemo.Transport.Httpc` wire transport. No mocks, no stubs.

  Covers:
  - real 200 tools/list shape, count >= 1, deterministic sort order
  - tokenless success asserting the documented auth-EXEMPT posture
    (no auth plug in `lib/smalt/micro` plug chain; the negative probe is
    the tokenless 200, not a 401)
  - real read-only `tools/call` (`cluster.status`) 200 shape
  - the router's read-only-by-law fence: an actuation-verb tool id is
    refused by name, never executed
  """

  use ExUnit.Case, async: false

  @base "http://127.0.0.1:9545"

  defp rpc(id, method, params) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  defp post(body) do
    PopcornDemo.Transport.Httpc.request(%{
      method: "POST",
      url: @base <> "/",
      headers: [{"content-type", "application/json"}],
      body: body
    })
  end

  defp decode(%{status: st, body: b}), do: {st, Jason.decode!(b)}

  test "walk reports OK with the real tool count" do
    assert {:ok, "mcp=OK(" <> rest} = PopcornDemo.LiveMcp.run()
    assert rest =~ ~r/^\d+-tools\)$/
  end

  test "tokenless tools/list: 200 with sorted non-empty tools" do
    # No Authorization header anywhere in the request — the plane is
    # auth-exempt by design (read off the router plug chain).
    assert {:ok, %{status: 200, body: body}} = post(rpc(1, "tools/list", %{}))
    assert {200, %{"result" => %{"tools" => tools}}} = decode(%{status: 200, body: body})
    assert is_list(tools) and length(tools) >= 1
    names = Enum.map(tools, & &1["name"])
    assert names == Enum.sort(names)
  end

  test "tools/call cluster.status: real 200 read shape" do
    assert {:ok, %{status: 200, body: body}} =
             post(rpc(2, "tools/call", %{"name" => "cluster.status", "arguments" => %{}}))

    assert {200,
            %{
              "result" => %{
                "content" => [%{"type" => "text"} | _],
                "structuredContent" => %{"enabled" => _},
                "isError" => false
              }
            }} = decode(%{status: 200, body: body})
  end

  test "actuation tool id is refused by name, never executed" do
    assert {:ok, %{status: 200, body: body}} =
             post(rpc(3, "tools/call", %{"name" => "blob.put", "arguments" => %{}}))

    assert {200,
            %{"result" => %{"isError" => true, "structuredContent" => %{"code" => code}}}} =
             decode(%{status: 200, body: body})

    assert is_binary(code)
  end
end

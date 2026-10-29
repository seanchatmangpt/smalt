defmodule PopcornDemo.LiveMcp do
  @moduledoc """
  WASM-BEAM MCP tool-surface walk (lane W3-5): prove the live smalt MCP
  plane (port 9545, plain HTTP, JSON-RPC/2.0) serves the real generated
  tool surface over the wire. Read-only lane law.

  Chicago school: the only collaborators are the live substrate and the
  wire — the walk asserts on real response shapes, never call counts.

  Wire shape (verified with curl against the live substrate BEFORE this
  module existed):

  - `GET /` -> 200 `{"service":"smalt-mcp","protocol":"JSON-RPC/2.0"}`
  - `POST /` `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` -> 200 with
    `result.tools`, capability_id-sorted deterministic order per
    `Smalt.Mcp.Router.tools/0`.
  - `POST /` `tools/call` `cluster.status` (read-only) -> 200 with
    `content[0].type=="text"`, `structuredContent` map, `isError:false`.

  Auth posture (read off `lib/smalt/mcp/router.ex` plug chain — RequestId,
  HealthPlug, Logger, match/dispatch; NO auth plug): the MCP plane is
  auth-EXEMPT by design. Tokenless requests succeed; the negative probe is
  the tokenless 200 itself, not a 401.

  Count reconciliation: `docs/capabilities.json` is the ARM resource-type
  capability projection — it carries NO MCP tool count, so there is nothing
  to reconcile against it (verified by reading the file: top-level keys are
  capabilities/endpoints/identity/name/schemaVersion/third_party;
  `capabilities` is a list of ARM resource-type maps, no mcp entry). The
  assertion is `tools >= 1` plus shape and sort-order invariants.

  This surface exposes NO actuation tools (router law): any tool id
  carrying an actuation verb fragment is refused by name per
  `lib/smalt/mcp/router.ex` `@actuation_fragments`. The walk calls only
  `cluster.status`, a pure read (observed on the probed substrate:
  `"enabled":false,"joined":0` — no side effects).

  Returns:

  - `{:ok, "mcp=OK(<n>-tools)"}`
  - `{:skip, "mcp=SKIP(<loud reason>)"}`
  - `{:error, "mcp=FAIL(<step>:<reason>)"}`
  """

  @base "http://127.0.0.1:9545"

  @doc """
  Runs the walk against the live substrate. Never boots, never restarts,
  never writes — read-only over the wire.
  """
  def run do
    with :ok <- up(),
         {:ok, n} <- tools_list(),
         :ok <- tools_call_read_only() do
      {:ok, "mcp=OK(#{n}-tools)"}
    else
      {:skip, reason} -> {:skip, "mcp=SKIP(#{reason})"}
      {:error, {step, reason}} -> {:error, "mcp=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  # -- walk steps ----------------------------------------------------------

  defp up do
    req = %{method: "GET", url: @base <> "/"}

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"service" => "smalt-mcp", "protocol" => "JSON-RPC/2.0"}} -> :ok
          {:ok, other} -> err("root", "unexpected-shape: " <> inspect(other))
          {:error, e} -> err("root", "json: " <> inspect(e))
        end

      {:ok, %{status: st}} ->
        err("root", "http-" <> Integer.to_string(st))

      {:error, e} ->
        {:skip, "mcp-down: " <> inspect(e)}
    end
  end

  defp tools_list do
    req = %{
      method: "POST",
      url: @base <> "/",
      headers: [{"content-type", "application/json"}],
      body: ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"})
    }

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"result" => %{"tools" => tools}}} when is_list(tools) ->
            n = length(tools)

            cond do
              n < 1 -> err("tools/list", "empty-tool-list")
              not sorted?(tools) -> err("tools/list", "tools-not-id-sorted")
              true -> {:ok, n}
            end

          {:ok, other} ->
            err("tools/list", "unexpected-shape: " <> inspect(other))

          {:error, e} ->
            err("tools/list", "json: " <> inspect(e))
        end

      {:ok, %{status: st}} ->
        err("tools/list", "http-" <> Integer.to_string(st))

      {:error, e} ->
        err("tools/list", "transport: " <> inspect(e))
    end
  end

  defp tools_call_read_only do
    req = %{
      method: "POST",
      url: @base <> "/",
      headers: [{"content-type", "application/json"}],
      body:
        ~s({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"cluster.status","arguments":{}}})
    }

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok,
           %{
             "result" => %{
               "content" => [%{"type" => "text"} | _],
               "structuredContent" => %{"enabled" => _},
               "isError" => false
             }
           }} ->
            :ok

          {:ok, %{"result" => %{"isError" => true} = r}} ->
            err(
              "tools/call",
              "cluster.status-is-error: " <>
                inspect(r["structuredContent"])
            )

          {:ok, other} ->
            err("tools/call", "unexpected-shape: " <> inspect(other))

          {:error, e} ->
            err("tools/call", "json: " <> inspect(e))
        end

      {:ok, %{status: st}} ->
        err("tools/call", "http-" <> Integer.to_string(st))

      {:error, e} ->
        err("tools/call", "transport: " <> inspect(e))
    end
  end

  # -- helpers -------------------------------------------------------------

  # BK-15 Fetch port (2026-10-21): former hardcoded Httpc dispatch crashed in
  # the wasm BEAM (:httpc unavailable) and surfaced as mcp=SKIP(wasm-transport...).
  # Dispatch is the kv=OK precedent: Transport.Fetch when the Popcorn JS bridge
  # is up, Transport.Httpc on the host. Req maps normalized (default :headers).
  defp request(req) do
    req = Map.put_new(req, :headers, [])

    if browser?() do
      PopcornDemo.Transport.Fetch.request(req)
    else
      PopcornDemo.Transport.Httpc.request(req)
    end
  end

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp sorted?(tools) do
    ids = Enum.map(tools, & &1["name"])
    ids == Enum.sort(ids)
  end

  defp err(step, reason), do: {:error, {step, reason}}

  defp fmt(term), do: if(is_binary(term), do: term, else: inspect(term))
end

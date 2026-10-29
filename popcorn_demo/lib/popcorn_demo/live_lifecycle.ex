defmodule PopcornDemo.LiveLifecycle do
  @moduledoc """
  W5-K — container-app lifecycle leg (Fortune-5 80/20: create → start →
  stop → delete is the daily operator loop) over the REAL ARM control plane
  (`http://127.0.0.1:9443`). Chicago: real collaborators, no mocks.

  Router audit (2026-10-20, router.ex): NO start/stop/restart POST action
  routes exist on containerApps — the surface is create/read/list/delete
  only. Typed report stands; this lane exercises the full AVAILABLE
  lifecycle:

    1. mint an STS bearer at `POST /{tenant}/oauth2/v2.0/token`
    2. ensure RG `popcorn-rg` (ARM PUT)
    3. PUT a run-unique containerApp via the generic provider resource PUT
       (router.ex:5997; Registry admits "Microsoft.App/containerApps",
       api-version pin "2023-05-01")
    4. GET the app back (200) + echo-check id/name/type
    5. DELETE the app (200) → GET again → 404 (real-gone assertion)

  Run-unique app names (live_blob pattern) so concurrent lanes never
  collide on the shared `popcorn-rg`.

  Receipt (run/0 return), house style:
    {:ok,    "lifecycle=OK(<stages>)"}
    {:skip,  "lifecycle=SKIP(transport:<reason>)"}   -- substrate down
    {:error, "lifecycle=FAIL(<step>:<reason>)"}      -- any other failure

  Transport (ERRC-E2 dedupe, CLOSED): all HTTP rides
  `PopcornDemo.Transport` (browser: `Transport.Fetch`, host:
  `Transport.Httpc`) — the former private `:httpc` client +
  `repair_code_path` copy is deleted; single transport, one calculus.
  `Transport.Httpc` returns RAW binary bodies and does not JSON-decode, so
  `decode_body/1` stays at THIS module's edge (walk steps pattern-match on
  decoded JSON).

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2023-05-01"

  @sub_id "popcorn-rg-sub"
  @rg "popcorn-rg"
  @ca_type "Microsoft.App/containerApps"

  @rg_base "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  @ca_base "#{@rg_base}/providers/Microsoft.App/containerApps"

  @doc "Full available lifecycle: create → GET → delete → GET-404."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    app = unique_app_name()

    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- put_container_app(app),
         {:ok, record} <- get_container_app(app),
         :ok <- echo_check(record, app),
         :ok <- delete_container_app(app),
         :ok <- get_missing(app) do
      {:ok, "lifecycle=OK(create:get:delete:get404:#{app})"}
    end
  end

  # -- Steps ---------------------------------------------------------------

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp unique_app_name do
    "l5k" <>
      Integer.to_string(System.system_time(:millisecond)) <>
      "-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=#{@scope}"

    case req(:post, "#{@base}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]
          ) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "lifecycle=FAIL(mint:STS-status-#{s}-body=#{slice(b)})"}

      {:error, reason} ->
        {:skip, "lifecycle=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_rg do
    case arm_req(:put, @rg_base, %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "lifecycle=FAIL(ensure_rg:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "lifecycle=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp put_container_app(app) do
    body = %{
      "location" => "eastus",
      "properties" => %{
        "environmentId" => "",
        "template" => %{"containers" => []},
        "configuration" => %{}
      }
    }

    case arm_req(:put, "#{@ca_base}/#{app}", body) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "lifecycle=FAIL(create:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "lifecycle=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp get_container_app(app) do
    case arm_req(:get, "#{@ca_base}/#{app}") do
      {:ok, %{status: 200, body: %{"name" => _} = record}} ->
        {:ok, record}

      {:ok, %{status: s, body: b}} ->
        {:error, "lifecycle=FAIL(get:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "lifecycle=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Echo-check the WIRE-returned record: id/name/type must round-trip.
  defp echo_check(record, app) do
    cond do
      record["id"] != "#{@ca_base}/#{app}" ->
        {:error, "lifecycle=FAIL(echo_check:id-mismatch-#{slice(record["id"])})"}

      record["name"] != app ->
        {:error, "lifecycle=FAIL(echo_check:name-mismatch-#{slice(record["name"])})"}

      record["type"] != @ca_type ->
        {:error, "lifecycle=FAIL(echo_check:type-mismatch)"}

      true ->
        :ok
    end
  end

  defp delete_container_app(app) do
    case arm_req(:delete, "#{@ca_base}/#{app}") do
      {:ok, %{status: s}} when s in [200, 202] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "lifecycle=FAIL(delete:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "lifecycle=SKIP(transport:#{slice(reason)})"}
    end
  end

  # A deleted app must genuinely answer 404 on the wire.
  defp get_missing(app) do
    case arm_req(:get, "#{@ca_base}/#{app}") do
      {:ok, %{status: 404}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "lifecycle=FAIL(get404:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "lifecycle=SKIP(transport:#{slice(reason)})"}
    end
  end

  # -- Wire seam + test seams (public for the Chicago test) -----------------

  @doc "ARM type under test (registry.ex pin)."
  def resource_type, do: @ca_type

  @doc "ARM path of a containerApp (test seam)."
  def ca_path(app), do: "#{@ca_base}/#{app}"

  defp arm_req(method, path, body_map \\ nil) do
    url = "#{@base}#{path}?#{@api}"

    if body_map do
      req(method, url,
        body: Jason.encode!(body_map),
        headers: [{"content-type", "application/json"}]
      )
    else
      req(method, url)
    end
  end

  # -- Transport (single calculus, mirrors LiveMatrix/LiveRules) --------------
  # Popcorn.Fetch when the JS bridge is up (browser WASM leg), else host
  # PopcornDemo.Transport.Httpc (real :httpc) — same request/response map
  # shape either way. The former private :httpc client + repair_code_path
  # copy is deleted.

  # Browser transport when the Popcorn JS bridge is up (mirrors live_blob's
  # signal: Popcorn.JS.available?/0); host requests ride Transport.Httpc.
  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(method, url, opts \\ []) do
    # Browsers reject GET/HEAD with a body (even ""); Popcorn.Fetch forwards
    # it verbatim — omit body on GET (witnessed in-browser, 2026-10-20).
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: headers_for(Keyword.get(opts, :headers, [])),
      body: body
    }

    if browser?() do
      request |> PopcornDemo.Transport.Fetch.request() |> decode_body()
    else
      request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
    end
  end

  # PopcornDemo.Transport returns raw binary bodies; the walk steps
  # pattern-match on decoded JSON. Decode best-effort at THIS edge (the
  # transport deliberately does not decode).
  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

  defp headers_for(extra) do
    bearer =
      case Process.get({__MODULE__, :token}) do
        nil -> []
        tok -> [{"authorization", "Bearer " <> tok}]
      end

    extra = List.wrap(extra)
    has_ct = Enum.any?(extra, fn {k, _} -> String.downcase(k) == "content-type" end)
    default = if has_ct, do: [], else: [{"content-type", "application/json"}]
    default ++ extra ++ bearer
  end
end

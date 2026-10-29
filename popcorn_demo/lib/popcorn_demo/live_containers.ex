defmodule PopcornDemo.LiveContainers do
  @moduledoc """
  W2-14 — ARM control-plane breadth leg: Microsoft.App/containerApps over
  REAL state (Chicago testbed: real collaborators, real substrate, no
  mocks).

  One `run/0` walks the ARM face of the containerApps surface on the live
  control plane (`http://127.0.0.1:9443`):

    1. mint an STS bearer at `POST /{tenant}/oauth2/v2.0/token`
       (audience https://management.azure.com/.default)
    2. ensure RG `popcorn-rg` via ARM PUT
    3. PUT containerApp `popcorn-ca` via the generic provider resource PUT
       (router.ex:5997 — Registry.admitted?/1 gates the type;
       registry.ex:19 admits "Microsoft.App/containerApps",
       api-version pin registry.ex:124 = "2023-05-01")
    4. GET the containerApp back (200) and echo-check id/name/type
    5. LIST per-RG containerApps (router.ex:6006 type-scoped LIST, the
       deny-by-default + type-filter path) and assert the ARM list shape
       `{"value": [...]}` — a fresh substrate returning `[]` is a real
       state assertion, not a skip.

  Wire seam (receipt): lib/smalt/arm_gateway/router.ex:5997 (generic PUT)
  / :6001 (generic GET) / :6006 (type-scoped LIST) ->
  handle_resource_put/handle_resource_get + Store.list_prefix on
  :smalt_resources.

  Receipts (run/0 return), house style:
    {:ok,    "containers=OK(<n>-listed)"}
    {:skip,  "containers=SKIP(transport:<reason>)"}   -- substrate down
    {:error, "containers=FAIL(<step>:<reason>)"}      -- any other failure

  Transport (ERRC-E2 dedupe, CLOSED): all HTTP rides
  `PopcornDemo.Transport` (browser: `Transport.Fetch`, host:
  `Transport.Httpc`) — the former private `:httpc` client +
  `repair_code_path` copy is deleted; single transport, one calculus.
  `Transport.Httpc` returns RAW binary bodies and does not JSON-decode, so
  `decode_body/1` stays at THIS module's edge (walk steps pattern-match on
  decoded JSON). Transport's resp contract carries `{status, body}` only —
  response headers are not surfaced, so the tokenless test seam
  (`fetch_tokenless/0`) witnesses the KD-15 refusal at status level (401).

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2023-05-01"

  @sub_id "popcorn-rg-sub"
  @rg "popcorn-rg"
  @ca "popcorn-ca"
  @ca_type "Microsoft.App/containerApps"

  @rg_base "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  @ca_base "#{@rg_base}/providers/Microsoft.App/containerApps"

  @doc "Full walk: ARM RG + containerApp PUT/GET echo + type-scoped LIST."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- put_container_app(),
         {:ok, record} <- get_container_app(),
         :ok <- echo_check(record),
         {:ok, n} <- list_container_apps() do
      {:ok, "containers=OK(#{n}-listed)"}
    end
  end

  # -- Steps ---------------------------------------------------------------

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

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
        {:error, "containers=FAIL(mint:STS-status-#{s}-body=#{slice(b)})"}

      {:error, reason} ->
        {:skip, "containers=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_rg do
    case arm_req(:put, @rg_base, %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "containers=FAIL(ensure_rg:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "containers=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp put_container_app do
    body = %{
      "location" => "eastus",
      "properties" => %{
        "environmentId" => "",
        "template" => %{"containers" => []},
        "configuration" => %{}
      }
    }

    case arm_req(:put, "#{@ca_base}/#{@ca}", body) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "containers=FAIL(put_container_app:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "containers=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp get_container_app do
    case arm_req(:get, "#{@ca_base}/#{@ca}") do
      {:ok, %{status: 200, body: %{"name" => _} = record}} ->
        {:ok, record}

      {:ok, %{status: s, body: b}} ->
        {:error, "containers=FAIL(get_container_app:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "containers=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Echo-check the WIRE-returned record (not the PUT body): id/name/type
  # must round-trip the ARM face.
  defp echo_check(record) do
    cond do
      record["id"] != expected_id() ->
        {:error, "containers=FAIL(echo_check:id-mismatch-#{slice(record["id"])})"}

      record["name"] != @ca ->
        {:error, "containers=FAIL(echo_check:name-mismatch-#{slice(record["name"])})"}

      record["type"] != @ca_type ->
        {:error, "containers=FAIL(echo_check:type-mismatch)"}

      true ->
        :ok
    end
  end

  # Type-scoped LIST: must answer 200 with the ARM list envelope, and the
  # just-PUT app must be present (real state, not a skip when empty).
  defp list_container_apps do
    case arm_req(:get, @ca_base) do
      {:ok, %{status: 200, body: %{"value" => items}}} when is_list(items) ->
        if Enum.any?(items, &(&1["name"] == @ca)),
          do: {:ok, length(items)},
          else:
            {:error,
             "containers=FAIL(list_container_apps:put-app-missing-among-#{length(items)})"}

      {:ok, %{status: s, body: b}} ->
        {:error, "containers=FAIL(list_container_apps:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "containers=SKIP(transport:#{slice(reason)})"}
    end
  end

  # -- Wire seam + pure-slice helpers (public for the Chicago test) ----------

  @doc "ARM path of the containerApp (test seam)."
  def ca_path, do: "#{@ca_base}/#{@ca}"

  @doc "ARM path of the per-RG type-scoped LIST (test seam)."
  def list_path, do: @ca_base

  @doc "Wire id the GET echo must carry."
  def expected_id, do: "#{@ca_base}/#{@ca}"

  @doc "Admitted ARM type under test (registry.ex pin)."
  def resource_type, do: @ca_type

  @doc """
  Real HTTP GET of the containerApp over the live substrate (test seam):
  returns {:ok, record} | {:error, _} | {:skip, _}. Requires run/0 (or the
  test's own mint) to have set the bearer.
  """
  def fetch_container_app do
    with :ok <- mint(),
         {:ok, %{status: 200, body: %{"name" => _}} = res} <- get_container_app() do
      {:ok, res.body}
    end
  end

  @doc """
  Tokenless negative (test seam): real GET with NO bearer. In enforce mode
  the control plane must answer 401 (KD-15 challenge handshake shape;
  Transport surfaces `{status, body}` only, so the refusal is witnessed at
  status level).
  """
  def fetch_tokenless do
    Process.delete({__MODULE__, :token})
    req(:get, "#{@base}#{ca_path()}?#{@api}")
  end

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

  # -- Transport ------------------------------------------------------------
  # Single transport calculus (ERRC-E2, CLOSED): Popcorn.Fetch when the JS
  # bridge is available (in-browser WASM leg), PopcornDemo.Transport.Httpc
  # (real :httpc) on the host — same request/response map shape either way.
  # The former private :httpc re-implementation (shim_httpc_json +
  # repair_code_path) is deleted; Httpc now honors caller content-type.

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

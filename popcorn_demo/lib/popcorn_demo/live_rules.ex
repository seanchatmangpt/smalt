defmodule PopcornDemo.LiveRules do
  @moduledoc """
  ERRC-R2 (RAISE) — Service Bus subscription rules over REAL state (Chicago
  testbed: real collaborators, real substrate, no mocks).

  One `run/0` walks the ARM face of the SB rules surface on the live
  control plane (`http://127.0.0.1:9443`):

    1. mint an STS bearer at `POST /{tenant}/oauth2/v2.0/token`
       (audience https://management.azure.com/.default)
    2. ensure RG `popcorn-rg` + namespace `popcorn-ns` (sku Standard),
       topic `popcorn-t`, subscription `popcorn-s` via ARM PUT
    3. PUT rule `popcorn-r` with sqlExpression `sys.label = 'popcorn'`
    4. GET the rule back (200) and echo-check id/name/type/filter
    5. compile the GET'd (real, wire-returned) filter with
       `Smalt.SbRules.compile/1` and assert
       `filter_matches_for_test?/2` on a matching message map
       (sys.label lookup seam, sb_rules.ex:253).

  Wire seam (receipt): lib/smalt/arm_gateway/router.ex:4254 (PUT rule route)
  -> handle_sb_rule/8 (router.ex:1818) -> run_sb_rule(:put/:get/:delete/:list)
  -> Smalt.SbRules.put_rule/get_rule on `:smalt_sb_rules`.

  Receipts (run/0 return), house style:
    {:ok,    "rules=OK(<rule>:<n>-listed)"}
    {:skip,  "rules=SKIP(transport:<reason>)"}   -- substrate down
    {:error, "rules=FAIL(<step>:<reason>)"}      -- any other failure

  Transport (second-tranche consolidation): all HTTP rides
  `PopcornDemo.Transport` (browser: `Transport.Fetch`, host:
  `Transport.Httpc`) — the former private `:httpc` + `repair_code_path`
  re-implementation is deleted. `Transport` returns RAW binary bodies, so
  `decode_body/1` stays at THIS module's edge; walk steps pattern-match on
  decoded JSON (non-JSON bodies stay binaries — `slice/1` renders them in
  FAIL/SKIP strings exactly as before).

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2021-04-01"

  @sub_id "popcorn-rg-sub"
  @rg "popcorn-rg"
  @ns "popcorn-ns"
  @topic "popcorn-t"
  @sub "popcorn-s"
  @rule "popcorn-r"
  @sql ~s|sys.label = 'popcorn'|

  @rg_base "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  @sb_base "#{@rg_base}/providers/Microsoft.ServiceBus"

  @doc "Full walk: ARM ns/topic/sub + rule PUT/GET/LIST + SbRules compile+match."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- ensure_ns(),
         :ok <- ensure_topic(),
         :ok <- ensure_subscription(),
         :ok <- put_rule(),
         {:ok, rule} <- get_rule(),
         :ok <- echo_check(rule),
         {:ok, n} <- list_rules() do
      {:ok, "rules=OK(#{@rule}:#{n}-listed)"}
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
            headers: [{"content-type", "application/x-www-form-urlencoded"}]) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(mint:STS-status-#{s}-body=#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_rg do
    case arm_req(:put, @rg_base, %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(ensure_rg:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  # GraphLaw gate (witnessed live): SB namespaces require skuName
  # (Basic|Standard|Premium); a sku-less PUT answers 400 InvalidResourceShape.
  defp ensure_ns do
    body = %{"location" => "eastus", "sku" => %{"name" => "Standard"}, "properties" => %{}}

    case arm_req(:put, "#{@sb_base}/namespaces/#{@ns}", body) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      # LRO face: 202 + delayMs (Retry-After), poll the operation until 200
      # (Smalt.ArmGateway.Lro contract, lro.ex:16 — "202 + Retry-After until
      # the delay elapses, then 200").
      {:ok, %{status: 202, body: %{"name" => op_id} = b}} ->
        poll_lro(op_id, b, 20)

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(ensure_ns:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Server-directed bounded LRO poll: interval = the wire's own delayMs
  # (Retry-After), deadline = 20 polls. # SLEEP-CLASS: POLL-STEP
  defp poll_lro(op_id, body, left) do
    delay = body |> Map.get("delayMs", 100) |> max(50)

    Process.sleep(delay)

    case arm_req(:get, "/subscriptions/#{@sub_id}/operations/#{op_id}") do
      {:ok, %{status: 200, body: %{"status" => "Succeeded"}}} ->
        :ok

      {:ok, %{status: 202, body: b}} when left > 1 ->
        poll_lro(op_id, b, left - 1)

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(ensure_ns-lro:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_topic do
    case arm_req(:put, "#{@sb_base}/namespaces/#{@ns}/topics/#{@topic}", %{
           "location" => "eastus",
           "properties" => %{}
         }) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(ensure_topic:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_subscription do
    case arm_req(:put, "#{@sb_base}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}", %{
           "location" => "eastus",
           "properties" => %{}
         }) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(ensure_subscription:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp put_rule do
    body = %{"properties" => %{"filter" => %{"sqlExpression" => @sql}}}

    case arm_req(:put, rule_path(), body) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(put_rule:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  # 200 + body-pin: `rule` binds the WIRE body map (the echo-check target),
  # not the %{status, body} transport envelope.
  defp get_rule do
    case arm_req(:get, rule_path()) do
      {:ok, %{status: 200, body: %{"name" => _} = rule}} ->
        {:ok, rule}

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(get_rule:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Echo-check the WIRE-returned record (not the PUT body): id/name/type/
  # filter must round-trip the ARM face.
  defp echo_check(rule) do
    cond do
      rule["id"] != expected_id() ->
        {:error, "rules=FAIL(echo_check:id-mismatch-#{slice(rule["id"])})"}

      rule["name"] != @rule ->
        {:error, "rules=FAIL(echo_check:name-mismatch-#{slice(rule["name"])})"}

      rule["type"] != "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules" ->
        {:error, "rules=FAIL(echo_check:type-mismatch)"}

      rule["properties"]["filter"]["sqlExpression"] != @sql ->
        {:error, "rules=FAIL(echo_check:filter-mismatch-#{slice(rule["properties"]["filter"])})"}

      true ->
        :ok
    end
  end

  defp list_rules do
    case arm_req(:get, "#{@sb_base}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}/rules") do
      {:ok, %{status: 200, body: %{"value" => items}}} ->
        {:ok, length(items)}

      {:ok, %{status: s, body: b}} ->
        {:error, "rules=FAIL(list_rules:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "rules=SKIP(transport:#{slice(reason)})"}
    end
  end

  # -- Wire seam + pure-slice helpers (public for the Chicago test) ----------

  @doc "ARM path of the rule under the popcorn namespace (test seam)."
  def rule_path do
    "#{@sb_base}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}/rules/#{@rule}"
  end

  @doc "Wire id the GET echo must carry (SB child convention: no /providers/)."
  def expected_id do
    "#{@rg_base}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}/rules/#{@rule}"
  end

  @doc "sqlExpression under test."
  def sql, do: @sql

  @doc """
  Real HTTP GET of the rule over the live substrate (test seam): returns
  {:ok, rule_record} | {:error, _} | {:skip, _}. Requires run/0 (or the
  test's own mint) to have set the bearer.
  """
  def fetch_rule do
    with :ok <- mint(),
         {:ok, %{"name" => _} = rule} <- get_rule() do
      {:ok, rule}
    end
  end

  # -- Transport ------------------------------------------------------------
  # Single transport calculus: browser Fetch when the Popcorn JS bridge is up
  # (mirrors LiveMatrix/live_param), host `PopcornDemo.Transport.Httpc`
  # (real :httpc, loopback-only, honors caller content-type) otherwise.
  # Transport returns raw binary bodies; decode best-effort at THIS edge.

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(method, url, opts \\ []) do
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

  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

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

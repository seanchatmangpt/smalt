defmodule PopcornDemo.LivePolicy do
  @moduledoc """
  LANE W3-8 — ARM policy initiatives leg over REAL state (Chicago testbed:
  real bearer mint, real GET list faces, real PUT/GET definition round-trip).

  One `run/0` walks the ARM control plane on `http://127.0.0.1:9443`:

    1. mint STS bearer (scope https://management.azure.com/.default;
       tokenless GET is a real 401 — the 401 leg lives in the test layer)
    2. GET the five policy LIST faces that exist on HEAD
       (`lib/smalt/arm_gateway/router.ex`): policyDefinitions (2020-09-01),
       policyAssignments (2023-04-01), policyExemptions (2022-07-01),
       policyRemediations (2021-10-01), policySetDefinitions (2023-04-01) —
       each must be 200 with `value` as a list (an empty list is REAL state,
       never a fake pass)
    3. PUT a policyDefinition + GET echo + assert it appears in the real list

  KD-112 status (receipt docs/jira/v26.10.19/receipts/kd112-arm-policy-
  initiatives-tbd.md, appended 2026-10-20): the routes are LIVE (not TBD) —
  the initiative/exemption/remediation legs were witnessed PASS at the
  genuine-SDK tier, so this leg runs the real faces instead of SKIPping.
  Known shared-substrate hazard, witnessed this session: a foreign record
  with a nil `id` in the shared `:smalt_policy` ETS 500s the
  policyDefinitions list (`String.downcase(nil)` at lib/smalt/policy.ex:427);
  if that pollution is present the leg reports policy=FAIL(typed) loudly.

  Receipts (run/0 return), house style:
    {:ok,    "policy=OK(<n>-faces-<nd>-defs)"}
    {:skip,  "policy=SKIP(substrate-down|transport:...)"}  -- transport refused
    {:error, "policy=FAIL(<step>:<reason>)"}               -- any other failure

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @sub "w38-sub"
  @api_versions %{
    "policyDefinitions" => "2020-09-01",
    "policyAssignments" => "2023-04-01",
    "policyExemptions" => "2022-07-01",
    "policyRemediations" => "2021-10-01",
    "policySetDefinitions" => "2023-04-01"
  }
  @def_name "w38-def"
  @def_body %{
    "properties" => %{
      "mode" => "All",
      "policyRule" => %{
        "if" => %{"field" => "location", "equals" => "westus"},
        "then" => %{"effect" => "deny"}
      }
    }
  }

  @doc "Full walk: bearer, 5 list faces (200 + value list), def PUT/GET/list round-trip."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    with :ok <- mint(),
         :ok <- list_faces(),
         {:ok, n} <- put_get_list_def() do
      {:ok, "policy=OK(5-faces-#{n}-defs)"}
    end
  end

  # -- Steps ---------------------------------------------------------------

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://management.azure.com/.default"

    case req(:post, "#{@base}/#{@tenant}/oauth2/v2.0/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "policy=FAIL(mint:STS-status-#{s}-body=#{String.slice(inspect(b), 0, 80)})"}

      {:error, reason} ->
        {:skip, "policy=SKIP(transport:#{slice(reason)})"}
    end
  end

  # TYPED DEFECT (witnessed 2026-10-20, this lane): the policyDefinitions and
  # policyAssignments LIST faces scan the WHOLE shared :smalt_policy ETS
  # (lib/smalt/policy.ex:427 and :509) and crash with String.downcase(nil) on
  # any record lacking an "id" key. The rem: receipt rows
  # (record_remediation_receipt/4, policy.ex:900) and the rs: resource-state
  # rows (policy.ex:983) are written to that same table WITHOUT "id" — so any
  # enforcement pass or remediation trigger on the substrate permanently 500s
  # both list faces until restart. The leg is a BOUNDED POLL on the real HTTP
  # observable (transient 500s do clear if no rs:/rem: row lands); a 500 that
  # persists past the deadline fails LOUD with the typed reason below.
  @list_poll_deadline_ms 10_000
  @list_poll_step_ms 500
  defp list_faces do
    Enum.reduce_while(Map.to_list(@api_versions), :ok, fn {face, ver}, :ok ->
      case poll_list(face, ver) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
        {:skip, _} = skip -> {:halt, skip}
      end
    end)
  end

  defp poll_list(face, ver), do: poll_list(face, ver, System.monotonic_time(:millisecond))

  defp poll_list(face, ver, started) do
    case req(
           :get,
           "#{@base}/subscriptions/#{@sub}/providers/Microsoft.Authorization/#{face}?api-version=#{ver}"
         ) do
      {:ok, %{status: 200, body: %{"value" => value}}} when is_list(value) ->
        :ok

      {:ok, %{status: 500}} ->
        if System.monotonic_time(:millisecond) - started >= @list_poll_deadline_ms do
          {:error,
           "policy=FAIL(list-#{face}:HTTP-500-persisted-past-#{@list_poll_deadline_ms}ms-deadline; " <>
             "typed: rs:/rem: receipt rows without id-key in shared :smalt_policy crash String.downcase(nil) at lib/smalt/policy.ex:427|:509)"}
        else
          # SLEEP-CLASS: POLL-STEP (bounded poll on the real HTTP observable)
          Process.sleep(@list_poll_step_ms)
          poll_list(face, ver, started)
        end

      {:ok, %{status: s, body: b}} ->
        {:error, "policy=FAIL(list-#{face}:HTTP-#{s}-#{String.slice(inspect(b), 0, 100)})"}

      {:error, reason} ->
        {:skip, "policy=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp put_get_list_def do
    url = "#{@base}/subscriptions/#{@sub}/providers/Microsoft.Authorization"
    def_name = @def_name

    with {:ok, %{status: 201, body: %{"id" => put_id}}} <-
           req(
             :put,
             "#{url}/policyDefinitions/#{@def_name}?api-version=#{@api_versions["policyDefinitions"]}",
             body: Jason.encode!(@def_body)
           ),
         {:ok, %{status: 200, body: %{"name" => ^def_name}}} <-
           req(
             :get,
             "#{url}/policyDefinitions/#{@def_name}?api-version=#{@api_versions["policyDefinitions"]}"
           ),
         {:ok, %{status: 200, body: %{"value" => defs}}} <-
           req(:get, "#{url}/policyDefinitions?api-version=#{@api_versions["policyDefinitions"]}"),
         true <- Enum.any?(defs, &(&1["id"] == put_id)) do
      {:ok, length(defs)}
    else
      {:ok, %{status: s, body: b}} ->
        {:error, "policy=FAIL(put_get_list_def:HTTP-#{s}-#{String.slice(inspect(b), 0, 100)})"}

      false ->
        {:error, "policy=FAIL(put_get_list_def:PUT-id-missing-from-list)"}

      {:error, reason} ->
        {:skip, "policy=SKIP(transport:#{slice(reason)})"}
    end
  end

  # -- Transport ------------------------------------------------------------
  # Same calculus as LiveParam/LiveMatrix (ERRC-E2 single transport, CLOSED):
  # host Transport.Httpc on the lane (Popcorn JS bridge down on host); the
  # transport honors caller content-type (W4-7), so the private
  # shim_httpc_json re-implementation is deleted. This file is lane-owned
  # (W3-8); no other live_*.ex is touched.

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

    # BK-15 Fetch port (2026-10-21): former hardcoded Httpc pipe crashed in the
    # wasm BEAM (:httpc unavailable) — policy=SKIP(wasm-transport...). Now the
    # kv=OK precedent: Transport.Fetch under the Popcorn JS bridge, Httpc on host.
    result =
      if browser?() do
        PopcornDemo.Transport.Fetch.request(request)
      else
        PopcornDemo.Transport.Httpc.request(request)
      end

    result |> decode_body()
  end

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

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

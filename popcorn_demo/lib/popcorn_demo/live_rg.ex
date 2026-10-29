defmodule PopcornDemo.LiveRg do
  @moduledoc """
  Resource Graph fleet-query walk (lane W3-7, Fortune-5 archetype: fleet-wide
  query). The only collaborators are the REAL smalt substrate and the wire:
  STS bearer mint on 9443, then a real
  `POST /providers/Microsoft.ResourceGraph/resources?application/json`
  query against the ARM gateway on 9443.

  Wire shape (verified with curl against the live substrate BEFORE this
  module existed):
  - STS token: POST {sts}/smalt-tenant/oauth2/v2.0/token (form CT; enforce
    mode mints over the wire, no local crypto).
  - RG query: JSON body `{"query": "...", "options": {"$top": N}}`; a bare
    query whose first word is a pipeline keyword ("project", "where", ...)
    is normalized to a pipeline by the emulator; an explicit leading `|`
    form also works. The KQL subset supported is `| where | take | sort/
    order by | summarize | project | extend` (see Smalt.DataPlane.KQL) —
    `limit` is NOT in the grammar, `take` is.
  - 200 body: `{"count": n, "data": [...], "resultTruncated": bool,
    "totalRecords": n}`. Empty `data` on a fresh substrate is a REAL
    assertion (count == length(data) == totalRecords == 0, data is a list).

  Transport (second-tranche consolidation): both legs (bearer mint + JSON
  query POST) ride `PopcornDemo.Transport` (browser: `Transport.Fetch`,
  host: `Transport.Httpc`). The former local `json_post/3` `:httpc` copy is
  deleted — `Transport.Httpc` now honors the caller's content-type
  (ERRC-E2 close), so the JSON query POST needs no private path, and the
  loopback-only guard lives in the transport itself. Transport returns RAW
  binary bodies; best-effort JSON decode stays at this module's edge
  (`decode_body/1`), so failure strings still render either a decoded map
  or the raw body.

  Receipts (run/0 return):
    {:ok,    "rg=OK(<n>-rows)"}
    {:skip,  "rg=SKIP(substrate-down:<step>:<reason>)"}  -- refused/blocked
    loopback hop (econnrefused / browser failed-to-fetch family), classified
    exactly like the main live leg (BK-TESTBED-F1 close)
    {:error, "rg=FAIL(<step>:<reason>)"}
  """

  @sts "http://127.0.0.1:9443"
  @arm "http://127.0.0.1:9443"
  @tenant "smalt-tenant"
  @api_version "2022-10-01"
  # Query crafted WITHIN the emulator's KQL subset (KQL.ex grammar: project/
  # take; `limit` is not in the grammar).
  @query "| project name | take 5"

  @doc """
  Runs the walk. Returns:

  - `{:ok, "rg=OK(<n>-rows)"}`
  - `{:skip, "rg=SKIP(<loud reason>)"}`
  - `{:error, "rg=FAIL(<step>:<reason>)"}`
  """
  def run do
    with {:ok, token} <- token(),
         {:ok, n} <- query(token) do
      {:ok, "rg=OK(#{n}-rows)"}
    else
      {:error, {step, reason}} when is_binary(step) ->
        # Same classifier as PopcornDemo.Live (BK-TESTBED-F1 close): a refused/
        # blocked loopback hop means the substrate is not listening — a loud
        # SKIP, never a FAIL. Anything else is a real step fault.
        if reason =~ ~r/econnrefused|failed to fetch/i do
          {:skip, "rg=SKIP(substrate-down:#{step}:#{fmt(reason)})"}
        else
          {:error, "rg=FAIL(#{step}:#{fmt(reason)})"}
        end
    end
  end

  # -- walk steps ----------------------------------------------------------

  defp token do
    req(
      :post,
      @sts <> "/#{@tenant}/oauth2/v2.0/token",
      body: "grant_type=client_credentials&client_id=popcorn-w37&client_secret=not-checked",
      headers: [{"content-type", "application/x-www-form-urlencoded"}]
    )
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        {:ok, tok}

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{slice(str(body))}"}}

      {:error, reason} ->
        {:error, {"token", fmt(reason)}}
    end
  end

  defp query(token) do
    payload =
      Jason.encode!(%{
        "query" => @query,
        "options" => %{"$top" => 5}
      })

    case req(
           :post,
           @arm <> "/providers/Microsoft.ResourceGraph/resources?api-version=#{@api_version}",
           headers: [
             {"authorization", "Bearer " <> token},
             {"content-type", "application/json"}
           ],
           body: payload
         ) do
      {:ok, %{status: 200, body: body}} ->
        with %{"count" => count, "data" => data, "totalRecords" => total} <-
               body,
             true <- is_list(data),
             true <- count == length(data),
             true <- total == length(data) do
          {:ok, length(data)}
        else
          _ -> {:error, {"query", "bad-200-shape:#{slice(Jason.encode!(body))}"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"query", "http-#{st}:#{slice(Jason.encode!(body))}"}}

      {:error, reason} ->
        {:error, {"query", fmt(reason)}}
    end
  end

  # -- Transport ------------------------------------------------------------
  # Single transport calculus: browser Fetch when the Popcorn JS bridge is up,
  # host `PopcornDemo.Transport.Httpc` (real :httpc, loopback-only, honors
  # caller content-type) otherwise. The former private json_post/3 + loopback
  # guard are deleted — the transport owns both.

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(method, url, opts) do
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: Keyword.get(opts, :headers, []),
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

  defp str(b) when is_binary(b), do: b
  defp str(b), do: inspect(b)

  defp fmt(term) when is_binary(term), do: slice(term)
  defp fmt(term), do: slice(inspect(term))

  defp slice(bin) when is_binary(bin) do
    bin |> String.slice(0, 120) |> String.replace("\n", " ")
  end
end

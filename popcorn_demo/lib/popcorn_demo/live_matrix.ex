defmodule PopcornDemo.LiveMatrix do
  alias PopcornDemo.Redact
  @moduledoc """
  LANE L2 — Cosmos data-plane matrix over REAL state (Chicago-school testbed:
  real collaborators, real docs, no mocks).

  One `run/0` walks the Cosmos surface on `http://127.0.0.1:8443`:

    1. ensure database `popcorn` (POST /dbs; 201 create, 409 exists)
    2. ensure container `smoke` (POST /dbs/:db/colls; 201 create, 409 exists)
    3. insert one real doc `{"id":..., "kind":"matrix"}` via
       POST /dbs/:db/colls/:coll/docs with `x-ms-documentdb-partitionkey`
    4. fetch the real docs list (GET /dbs/:db/colls/:coll/docs)
    5. evaluate the vendored pure slice `Smalt.CosmosSql.run/3` over the
       REAL fetched docs, asserting the inserted doc matches the WHERE
       clause of `SELECT * FROM c WHERE c.kind = "matrix"`.

  Pure slice over real state is the testbed thesis.

  Auth (witnessed by host-side probe, 2026-10-20): the 9443 STS bearer mint
  `POST /{tenant}/oauth2/v2.0/token` IS accepted on the 8443 cosmos routes
  (`Authorization: Bearer <jwt>`); doc writes additionally need
  `x-ms-documentdb-partitionkey: ["<id>"]` (400 PartitionKey mismatch
  otherwise). Missing bearer -> 401 MissingBearerToken.

  Receipts (run/0 return):
    {:ok,    "matrix=OK(<db>/<coll>:<n>-matched)"}
    {:skip,  "matrix=SKIP(substrate-down)"}   -- connection refused anywhere
    {:error, "matrix=FAIL(<step>:<reason>)"}  -- any other failure

  Transport (ERRC-E2 dedupe, CLOSED): all HTTP rides `PopcornDemo.Transport`
  (browser: `Transport.Fetch`, host: `Transport.Httpc`). `Transport.Httpc`
  now honors a caller-set `content-type` header (form-urlencoded is only
  the no-CT default), so the former local `shim_httpc_json` path-repair copy
  is deleted — single transport, one calculus.
  `Transport.Httpc` returns RAW binary bodies and does not JSON-decode, so
  `decode_body/1` stays at THIS module's edge (walk steps pattern-match on
  decoded JSON).

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @db "popcorn"
  @coll "smoke"
  @doc_id "live-matrix-1"
  @kind "matrix"

  @doc "Full walk: ensure db/coll, insert doc, fetch docs, CosmosSql over real docs."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    with :ok <- mint(),
         :ok <- ensure_db(),
         :ok <- ensure_coll(),
         :ok <- insert_doc(),
         {:ok, docs} <- fetch_docs(),
         :ok <- assert_query(docs) do
      {:ok, "matrix=OK(#{@db}/#{@coll}:#{length(docs)}-matched)"}
    end
  end

  # -- Steps ---------------------------------------------------------------

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://cosmos.azure.com/.default"

    case req(:post, "#{@sts}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "matrix=FAIL(mint:STS-status-#{s}-body=#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "matrix=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_db do
    case req(:post, "#{@base}/dbs", body: Jason.encode!(%{"id" => @db})) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "matrix=FAIL(ensure_db:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "matrix=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_coll do
    body =
      Jason.encode!(%{
        "id" => @coll,
        "partitionKey" => %{"paths" => ["/id"], "kind" => "Hash"}
      })

    case req(:post, "#{@base}/dbs/#{@db}/colls", body: body) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} ->
        {:error, "matrix=FAIL(ensure_coll:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "matrix=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp insert_doc do
    case req(:post, "#{@base}/dbs/#{@db}/colls/#{@coll}/docs",
            body: Jason.encode!(%{"id" => @doc_id, "kind" => @kind}),
            headers: [{"x-ms-documentdb-partitionkey", ~s(["#{@doc_id}"])}]) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} ->
        {:error, "matrix=FAIL(insert_doc:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "matrix=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp fetch_docs do
    case req(:get, "#{@base}/dbs/#{@db}/colls/#{@coll}/docs") do
      {:ok, %{status: 200, body: %{"Documents" => docs}}} ->
        {:ok, docs}

      {:ok, %{status: s, body: b}} ->
        {:error, "matrix=FAIL(fetch_docs:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "matrix=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Pure slice evaluated over the REAL fetched docs: every doc must match
  # `c.kind = "matrix"` and our inserted doc must be present in the match set.
  defp assert_query(docs) do
    # Cosmos SQL string literals are single-quoted (grammar: literal ::=
    # string, lexer admits only '...' strings — double quotes are a typed
    # syntax error, witnessed by this matrix run).
    query = ~s|SELECT * FROM c WHERE c.kind = 'matrix'|

    with {:ok, matched} <- Smalt.CosmosSql.run(query, docs),
         true <- Enum.any?(matched, &(&1["id"] == @doc_id)) do
      :ok
    else
      {:error, {:syntax, reason}} ->
        {:error, "matrix=FAIL(assert_query:syntax-#{reason})"}

      false ->
        {:error, "matrix=FAIL(assert_query:inserted-doc-not-in-match-set)"}
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

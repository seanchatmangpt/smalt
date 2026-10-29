defmodule PopcornDemo.LiveCas do
  @moduledoc """
  LANE W4-3 — optimistic-concurrency (CAS) leg over REAL state (Chicago
  testbed: real docs, real etags, real wire refusals — no mocks).

  One `run/0` walks the Cosmos replace path on `http://127.0.0.1:8443`:

    1. mint STS bearer on 9443 (wire shape proven in LiveMatrix)
    2. ensure db `popcorn` / container `smoke` (201 create, 409 exists)
    3. insert one real doc `{"id": "live-cas-1", "kind": "cas"}`
    4. GET the doc, capture its REAL `_etag`
    5. PUT replace WITH `If-Match: <fresh etag>` → 200
    6. PUT replace WITH the STALE (pre-replace) etag → 412 PreconditionFailed
       (the typed wire refusal — the point of the leg)
    7. DELETE with `If-Match: <fresh etag from the 200>` → 204
    8. re-GET → 404 (gone)

  Server semantics (lib/smalt/data_plane/cosmos.ex): the If-Match check and
  the write run as ONE atomic Store.compare_and_swap inside the Store
  GenServer; If-Match-vs-If-Match races yield exactly one 200 and N-1 412s.
  Wire parity witnessed by curl (2026-10-20): the `_etag` in doc bodies
  ALREADY carries its double quotes ("..."), and If-Match must be sent
  VERBATIM as captured — re-quoting yields ""..."" and a real 412 on the
  fresh replace.

  Partition-key pinion (live_param.ex): `x-ms-documentdb-partitionkey` must
  be a JSON ARRAY — `Jason.encode!([doc["id"]])`.

  Receipts (run/0 return), house style:
    {:ok,    "cas=OK(<stages>)"}
    {:skip,  "cas=SKIP(substrate-down)"}   -- transport refused
    {:error, "cas=FAIL(<step>:<reason>)"}  -- any other failure

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  alias PopcornDemo.Redact

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @db "popcorn"
  @coll "smoke"
  @doc_id "live-cas-1"
  @kind "cas"

  @doc "Full CAS walk: insert, etag capture, fresh replace, stale refusal, conditional delete, 404."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    with :ok <- mint(),
         :ok <- ensure_db(),
         :ok <- ensure_coll(),
         :ok <- insert_doc(),
         {:ok, etag0} <- get_doc_etag(),
         {:ok, etag1} <- replace_fresh(etag0),
         :ok <- replace_stale(etag0),
         :ok <- delete_conditional(etag1),
         :ok <- assert_404() do
      {:ok,
       "cas=OK(insert,etag,fresh-200,stale-412,delete-204,gone-404)"}
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
        {:error, "cas=FAIL(mint:STS-status-#{s}-body=#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "cas=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_db do
    case req(:post, "#{@base}/dbs", body: Jason.encode!(%{"id" => @db})) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "cas=FAIL(ensure_db:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "cas=SKIP(transport:#{slice(reason)})"}
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
        {:error, "cas=FAIL(ensure_coll:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "cas=SKIP(transport:#{reason |> slice() |> inspect()})"}
    end
  end

  defp insert_doc do
    case req(:post, "#{@base}/dbs/#{@db}/colls/#{@coll}/docs",
            body: Jason.encode!(%{"id" => @doc_id, "kind" => @kind, "v" => 1}),
            headers: [{"x-ms-documentdb-partitionkey", Jason.encode!([@doc_id])}]) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} ->
        {:error, "cas=FAIL(insert_doc:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}
      {:error, reason} -> {:skip, "cas=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # GET the single doc and capture its real `_etag` from the body.
  defp get_doc_etag do
    case req(:get, doc_url()) do
      {:ok, %{status: 200, body: %{"_etag" => etag}}} when is_binary(etag) ->
        {:ok, etag}

      {:ok, %{status: s, body: b}} ->
        {:error, "cas=FAIL(get_doc_etag:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "cas=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # Fresh-etag replace must succeed with 200 and hand back the NEW etag.
  defp replace_fresh(etag0) do
    case put_doc(etag0, %{"id" => @doc_id, "kind" => @kind, "v" => 2}) do
      {:ok, %{status: 200, body: %{"_etag" => etag1}}} when is_binary(etag1) ->
        {:ok, etag1}

      {:ok, %{status: s, body: b}} ->
        {:error, "cas=FAIL(replace_fresh:HTTP-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "cas=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # Stale-etag replace must be refused on the wire: 412 PreconditionFailed.
  defp replace_stale(etag0) do
    case put_doc(etag0, %{"id" => @doc_id, "kind" => @kind, "v" => 3}) do
      {:ok, %{status: 412}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "cas=FAIL(replace_stale:wanted-412-got-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "cas=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # Conditional delete with the post-replace fresh etag → 204.
  defp delete_conditional(etag1) do
    headers = if_match(etag1)

    case req(:delete, doc_url(), headers: headers) do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "cas=FAIL(delete_conditional:wanted-204-got-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "cas=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  defp assert_404 do
    case req(:get, doc_url()) do
      {:ok, %{status: 404}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "cas=FAIL(assert_404:wanted-404-got-#{s}-#{Redact.fragment(inspect(b))})"}

      {:error, reason} ->
        {:skip, "cas=SKIP(transport:#{slice(inspect(reason))})"}
    end
  end

  # -- Helpers --------------------------------------------------------------

  defp doc_url, do: "#{@base}/dbs/#{@db}/colls/#{@coll}/docs/#{@doc_id}"

  defp if_match(etag), do: [{"if-match", etag}]

  defp put_doc(etag, doc) do
    req(:put, doc_url(),
      body: Jason.encode!(doc),
      headers: if_match(etag) ++ [{"x-ms-documentdb-partitionkey", Jason.encode!([@doc_id])}]
    )
  end

  # -- Transport ------------------------------------------------------------
  # Same calculus as LiveMatrix (ERRC-E2 single transport): browser Fetch
  # when the Popcorn JS bridge is up, else host Transport.Httpc (which honors
  # a caller-set content-type; JSON is the default here). This file is
  # lane-owned (W4-3); live_matrix.ex / live_param.ex are NOT touched.

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(method, url, opts \\ []) do
    # Browsers reject GET/HEAD with a body (witnessed in LiveMatrix).
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

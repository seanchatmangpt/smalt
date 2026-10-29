defmodule PopcornDemo.LiveParam do
  @moduledoc """
  LANE W2-8 — parameterized Cosmos SQL leg over REAL state (Chicago
  testbed: real docs, real fetch, vendored pure slice with @params —
  the Fortune-5 norm is parameterized queries, not literal-baked SQL).

  One `run/0` walks the Cosmos surface on `http://127.0.0.1:8443`:

    1. mint STS bearer on 9443 (wire shape proven in LiveMatrix)
    2. ensure db `popcorn` / container `smoke` (201 create, 409 exists)
    3. insert TWO real docs with distinct `kind`/`size` fields
    4. fetch the real docs feed (GET /dbs/:db/colls/:coll/docs)
    5. `Smalt.CosmosSql.run/3` with a @param query

       SELECT * FROM c WHERE c.kind = @kind AND c.size > @min

       asserting exactly the right doc(s) match (positive and negative
       parameter bindings in the test layer).

  Receipts (run/0 return), house style:
    {:ok,    "param=OK(<n>-matched-params)"}
    {:skip,  "param=SKIP(substrate-down)"}   -- transport refused
    {:error, "param=FAIL(<step>:<reason>)"}  -- any other failure

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` only.
  """

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @db "popcorn"
  @coll "smoke"
  @doc_a %{"id" => "live-param-a", "kind" => "param", "size" => 100}
  @doc_b %{"id" => "live-param-b", "kind" => "param", "size" => 5}
  @query ~s|SELECT * FROM c WHERE c.kind = @kind AND c.size > @min|

  @doc "Full walk: ensure db/coll, insert 2 docs, fetch, @param query over real docs."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    with :ok <- mint(),
         :ok <- ensure_db(),
         :ok <- ensure_coll(),
         :ok <- insert_docs(),
         {:ok, docs} <- fetch_docs(),
         {:ok, n} <- assert_param_query(docs) do
      {:ok, "param=OK(#{n}-matched-params)"}
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
        {:error, "param=FAIL(mint:STS-status-#{s}-body=#{String.slice(inspect(b), 0, 80)}...)"}

      {:error, reason} ->
        {:skip, "param=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_db do
    case req(:post, "#{@base}/dbs", body: Jason.encode!(%{"id" => @db})) do
      {:ok, %{status: s}} when s in [201, 409] -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "param=FAIL(ensure_db:HTTP-#{s}-#{inspect(b)})"}
      {:error, reason} -> {:skip, "param=SKIP(transport:#{slice(reason)})"}
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
        {:error, "param=FAIL(ensure_coll:HTTP-#{s}-#{inspect(b)})"}
      {:error, reason} -> {:skip, "param=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp insert_docs do
    Enum.reduce_while([@doc_a, @doc_b], :ok, fn doc, :ok ->
      pk = Jason.encode!([doc["id"]])
      case req(:post, "#{@base}/dbs/#{@db}/colls/#{@coll}/docs",
              body: Jason.encode!(doc),
              headers: [{"x-ms-documentdb-partitionkey", pk}]) do
        {:ok, %{status: s}} when s in [201, 409] ->
          {:cont, :ok}

        {:ok, %{status: s, body: b}} ->
          {:halt, {:error, "param=FAIL(insert_docs:HTTP-#{s}-#{inspect(b)})"}}

        {:error, reason} ->
          {:halt, {:skip, "param=SKIP(transport:#{slice(reason)})"}}
      end
    end)
  end

  defp fetch_docs do
    case req(:get, "#{@base}/dbs/#{@db}/colls/#{@coll}/docs") do
      {:ok, %{status: 200, body: %{"Documents" => docs}}} ->
        {:ok, docs}

      {:ok, %{status: s, body: b}} ->
        {:error, "param=FAIL(fetch_docs:HTTP-#{s}-#{inspect(b)})"}

      {:error, reason} ->
        {:skip, "param=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Pure slice over the REAL fetched docs with bound @params. The inserted
  # `size=100` doc must be the only match for (kind="param", size>50); the
  # `size=5` doc must be excluded. Missing-param bindings are a typed parse
  # error in the slice — exercised by the test layer.
  defp assert_param_query(docs) do
    params = %{"kind" => "param", "min" => 50}

    case Smalt.CosmosSql.run(@query, docs, params) do
      {:ok, matched} ->
        ids = Enum.map(matched, & &1["id"])

        if @doc_a["id"] in ids and @doc_b["id"] not in ids do
          {:ok, length(matched)}
        else
          {:error,
           "param=FAIL(assert_param_query:match-set=#{inspect(ids)}-want-only-#{@doc_a["id"]})"}
        end

      {:error, reason} ->
        {:error, "param=FAIL(assert_param_query:#{slice(reason)})"}
    end
  end

  # -- Transport ------------------------------------------------------------
  # Same calculus as LiveMatrix (ERRC-E2 single transport, CLOSED): browser
  # Fetch when the Popcorn JS bridge is up, else host Transport.Httpc — the
  # transport honors caller content-type (W4-7), so the private
  # shim_httpc_json re-implementation is deleted. Get/empty-body rides Httpc
  # as-is. This file is lane-owned (W2-8); live_matrix.ex is NOT touched.

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

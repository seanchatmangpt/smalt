defmodule PopcornDemo.LiveCasTest do
  use ExUnit.Case, async: false

  # Chicago-school leg for W4-3: real substrate (cosmos 8443 + STS 9443),
  # real docs, real etags, real wire refusals. The 412 on a stale If-Match
  # is the point — a real precondition-failure on the wire, not a simulated
  # one. No mocks.

  alias PopcornDemo.LiveCas

  # Order-independence: the run/0 walk owns doc `live-cas-1`; each focused
  # wire test owns its OWN doc id and starts with a defensive unconditional
  # delete, so no test depends on another's leftover state (Chicago: real
  # state, arranged and cleaned by the test itself).
  describe "run/0 full CAS walk over live substrate" do
    test "returns OK naming all six stages" do
      assert {:ok, "cas=OK(insert,etag,fresh-200,stale-412,delete-204,gone-404)"} =
               LiveCas.run()
    end

    test "fresh-etag replace returns 200 with a NEW _etag over the real wire" do
      doc = "live-cas-fresh"
      purge(doc)
      etag0 = insert_and_capture!(doc)

      assert {:ok, %{status: 200, body: %{"_etag" => etag1, "v" => 2}}} =
               put_doc(doc, etag0, %{"id" => doc, "kind" => "cas", "v" => 2})

      assert is_binary(etag1) and etag1 != ""
      assert etag1 != etag0, "a successful replace must mint a fresh etag"
      purge(doc)
    end

    test "stale-etag replace is refused 412 PreconditionFailed on the real wire" do
      doc = "live-cas-stale"
      purge(doc)
      etag0 = insert_and_capture!(doc)

      # Advance the doc once with a fresh replace so etag0 is genuinely stale.
      assert {:ok, %{status: 200, body: %{"_etag" => _fresh}}} =
               put_doc(doc, etag0, %{"id" => doc, "kind" => "cas", "v" => 2})

      # Now replay the STALE etag: the server's atomic CAS must refuse 412.
      assert {:ok, %{status: 412, body: %{"code" => "PreconditionFailed"}}} =
               put_doc(doc, etag0, %{"id" => doc, "kind" => "cas", "v" => 3})

      purge(doc)
    end

    test "re-GET after conditional delete is 404" do
      doc = "live-cas-gone"
      purge(doc)
      etag0 = insert_and_capture!(doc)

      assert {:ok, %{status: 200, body: %{"_etag" => fresh}}} =
               put_doc(doc, etag0, %{"id" => doc, "kind" => "cas", "v" => 2})

      assert {:ok, %{status: 204}} = delete_doc(doc, fresh)
      assert {:ok, %{status: 404}} = http(:get, doc_url(doc))
    end
  end

  # -- Real collaborators ----------------------------------------------------
  # Same transport replication as LiveParamTest: the module has no public
  # fetch helpers, so the tests drive the real endpoints via :httpc directly
  # (real mint, real PUT/GET/DELETE, real substrate).

  @base "http://127.0.0.1:8443"
  @doc_url "#{@base}/dbs/popcorn/colls/smoke/docs/live-cas-1"

  defp insert_and_capture!(doc) do
    {:ok, token} = ensure_token()

    {:ok, %{status: s}} =
      http(:post, "#{@base}/dbs/popcorn/colls/smoke/docs",
        body: Jason.encode!(%{"id" => doc, "kind" => "cas", "v" => 1}),
        headers: [{"x-ms-documentdb-partitionkey", Jason.encode!([doc])}]
      )

    assert s in [201, 409]

    assert {:ok, %{status: 200, body: %{"_etag" => etag}}} = http(:get, doc_url(doc))
    etag
  end

  defp put_doc(doc, etag, body_doc) do
    http(:put, doc_url(doc),
      body: Jason.encode!(body_doc),
      headers: [{"if-match", etag},
                {"x-ms-documentdb-partitionkey", Jason.encode!([doc])}]
    )
  end

  defp delete_doc(doc, etag) do
    http(:delete, doc_url(doc), headers: [{"if-match", etag}])
  end

  # Unconditional delete (no If-Match); 204 or 404 are both clean state.
  defp purge(doc) do
    assert {:ok, %{status: status}} = http(:delete, doc_url(doc))
    assert status in [204, 404]
  end

  defp doc_url(doc), do: "#{@base}/dbs/popcorn/colls/smoke/docs/#{doc}"

  defp ensure_token do
    case Process.get({:cas_test, :token}) do
      nil ->
        {:ok, tok} = mint()
        Process.put({:cas_test, :token}, tok)
        {:ok, tok}

      tok ->
        {:ok, tok}
    end
  end

  defp mint do
    form =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://cosmos.azure.com/.default"

    req =
      {~c"http://127.0.0.1:9443/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token", [],
       ~c"application/x-www-form-urlencoded", String.to_charlist(form)}

    case :httpc.request(:post, req, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode!(body) do
          %{"access_token" => tok} when is_binary(tok) -> {:ok, tok}
          other -> flunk("STS mint returned no access_token: #{inspect(other)}")
        end

      {:ok, {{_, status, _}, _, body}} ->
        flunk("STS mint HTTP #{status}: #{inspect(body)}")

      {:error, reason} ->
        flunk("SKIP(substrate-down:sts) transport: #{inspect(reason)}")
    end
  end

  defp http(method, url, opts \\ []) do
    {:ok, token} =
      case Process.get({:cas_test, :token}) do
        nil -> mint()
        tok -> {:ok, tok}
      end

    headers =
      [{~c"authorization", String.to_charlist("Bearer " <> token)}] ++
        Enum.map(opts[:headers] || [], fn {k, v} ->
          {String.to_charlist(String.downcase(k)), String.to_charlist(v)}
        end)

    body = opts[:body]

    req =
      if body do
        {String.to_charlist(url), headers, ~c"application/json",
         String.to_charlist(body)}
      else
        {String.to_charlist(url), headers}
      end

    case :httpc.request(method, req, [], body_format: :binary) do
      {:ok, {{_, status, _}, _, resp_body}} ->
        decoded = case Jason.decode(resp_body) do
          {:ok, map} -> map
          _ -> resp_body
        end

        {:ok, %{status: status, body: decoded}}

      {:error, reason} ->
        flunk("SKIP(substrate-down:#{method}) transport: #{inspect(reason)}")
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    root = :code.root_dir() |> to_string()

    root
    |> then(&Path.wildcard(Path.join(&1, "lib/*/ebin")))
    |> Enum.each(&:code.add_pathz(String.to_charlist(&1)))

    :ok
  end
end

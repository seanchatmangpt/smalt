defmodule PopcornDemo.LiveParamTest do
  use ExUnit.Case, async: false

  # Chicago-school leg: real substrate (cosmos 8443 + STS 9443), real docs,
  # real fetch; the vendored `Smalt.CosmosSql.run/3` slice evaluated over
  # the REAL feed with @params. No mocks. Includes a negative: a mismatched
  # parameter binding must yield an EMPTY match set (typed, no crash), and
  # a missing binding must be a typed parse error.

  alias PopcornDemo.LiveParam

  @query ~s|SELECT * FROM c WHERE c.kind = @kind AND c.size > @min|

  describe "run/0 full walk over live substrate" do
    test "returns OK with n >= 1 matched docs via @params" do
      assert {:ok, "param=OK(" <> rest} = LiveParam.run()
      n = rest |> String.split("-matched-params") |> hd() |> String.to_integer()
      assert n >= 1
    end

    test "positive binding matches exactly the size>50 param doc over the real feed" do
      docs = real_docs!()

      {:ok, matched} =
        Smalt.CosmosSql.run(@query, docs, %{"kind" => "param", "min" => 50})

      ids = Enum.map(matched, & &1["id"])
      assert "live-param-a" in ids
      refute "live-param-b" in ids
    end

    test "negative binding (kind mismatch) yields an EMPTY match set, typed ok" do
      docs = real_docs!()

      assert {:ok, []} =
               Smalt.CosmosSql.run(@query, docs, %{"kind" => "no-such-kind", "min" => 0})
    end

    test "negative binding (size above all docs) yields an EMPTY match set, typed ok" do
      docs = real_docs!()

      assert {:ok, []} =
               Smalt.CosmosSql.run(@query, docs, %{"kind" => "param", "min" => 10_000})
    end

    test "missing @param binding is a typed unbound-params error over real docs" do
      docs = real_docs!()
      # Real typed shape: the slice reports unbound @params as a syntax error
      # naming the missing bindings (witnessed, 2026-10-20).
      assert {:error, {:syntax, "Unbound parameter(s): kind, min"}} =
               Smalt.CosmosSql.run(@query, docs, %{})
    end
  end

  # -- Real collaborators ----------------------------------------------------

  defp real_docs! do
    assert {:ok, "param=OK(" <> _} = LiveParam.run()

    {:ok, %{"Documents" => docs}} =
      mint_then_get("http://127.0.0.1:8443/dbs/popcorn/colls/smoke/docs")

    docs
  end

  # Real STS mint + real :httpc GET (same endpoints the module uses; the
  # module has no public fetch, so the test replicates the transport, not
  # the logic). Code-path warm-up per the host toolchain note.
  defp mint_then_get(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    root = :code.root_dir() |> to_string()

    root
    |> then(&Path.wildcard(Path.join(&1, "lib/*/ebin")))
    |> Enum.each(&:code.add_pathz(String.to_charlist(&1)))

    with {:ok, token} <- mint(),
         {:ok, body} <- get_docs(token, url) do
      {:ok, Jason.decode!(body)}
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

  defp get_docs(token, url) do
    req =
      {String.to_charlist(url),
       [{~c"authorization", String.to_charlist("Bearer " <> token)}]}

    case :httpc.request(:get, req, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, body}} ->
        flunk("docs GET HTTP #{status}: #{inspect(body)}")

      {:error, reason} ->
        flunk("SKIP(substrate-down:docs) transport: #{inspect(reason)}")
    end
  end
end

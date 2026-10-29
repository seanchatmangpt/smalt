defmodule PopcornDemo.LiveMatrixTest do
  use ExUnit.Case, async: false

  # Chicago-school live leg over the REAL smalt substrate on loopback
  # (cosmos plane 8443, STS 9443). No mocks: `run/0` walks the actual data
  # plane; the "real docs fetch" used by the pure-slice tests is a real
  # :httpc GET against the same endpoint the module uses. A down substrate
  # surfaces as a loud transport failure naming the step, never a fake pass.
  alias PopcornDemo.LiveMatrix

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @db "popcorn"
  @coll "smoke"
  @doc_id "live-matrix-1"

  describe "run/0 full walk over live substrate" do
    test "returns OK with n >= 1 matched docs" do
      assert {:ok, "matrix=OK(popcorn/smoke:" <> rest} = LiveMatrix.run()
      n = rest |> String.split("-matched") |> hd() |> String.to_integer()
      assert n >= 1
    end

    test "double-quoted SQL literal is a typed {:error, {:syntax, _}} over real docs" do
      docs = real_docs!()

      result =
        Smalt.CosmosSql.run(~s|SELECT * FROM c WHERE c.kind = "matrix"|, docs)

      assert {:error, {:syntax, _reason}} = result
    end

    test "inserted doc id is present in the real docs feed" do
      docs = real_docs!()
      assert Enum.any?(docs, &(&1["id"] == @doc_id))
    end
  end

  # -- Real collaborators ----------------------------------------------------

  # Real docs fetch: STS bearer mint over the loopback STS (9443) then a
  # real :httpc GET on the same /docs endpoint the module's fetch_docs uses
  # (the module has no public fetch, so the test replicates the transport,
  # not the logic). Mirrors the module's toolchain note: this asdf OTP-29
  # inets resolves :http_util/:public_key lazily, so warm the code path the
  # same way before the first request.
  defp real_docs! do
    {:ok, %{"Documents" => docs}} = mint_then_get()
    docs
  end

  defp mint_then_get do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    root = :code.root_dir() |> to_string()

    root
    |> then(&Path.wildcard(Path.join(&1, "lib/*/ebin")))
    |> Enum.each(&:code.add_pathz(String.to_charlist(&1)))

    with {:ok, token} <- mint(),
         {:ok, body} <- get_docs(token) do
      {:ok, Jason.decode!(body)}
    end
  end

  defp mint do
    form =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://cosmos.azure.com/.default"

    req =
      {String.to_charlist("#{@sts}/#{@tenant}/oauth2/v2.0/token"), [],
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

  defp get_docs(token) do
    url = "#{@base}/dbs/#{@db}/colls/#{@coll}/docs"

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

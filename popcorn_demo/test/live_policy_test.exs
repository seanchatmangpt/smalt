defmodule PopcornDemo.LivePolicyTest do
  use ExUnit.Case, async: false

  # Chicago-school leg: real substrate (ARM 9443 + STS), real bearer, real
  # GET list faces, real PUT/GET definition round-trip. No mocks. Negative:
  # a tokenless GET on the same face is a real 401 (bearer-gated surface).

  alias PopcornDemo.LivePolicy

  @base "http://127.0.0.1:9443"
  @sub "w38-sub"
  @tenant "00000000-0000-0000-0000-000000000000"
  @face "policyDefinitions"

  describe "run/0 full walk over live substrate" do
    test "returns OK across 5 list faces with >= 1 real definition" do
      assert {:ok, "policy=OK(5-faces-" <> rest} = LivePolicy.run()
      n = rest |> String.split("-defs") |> hd() |> String.to_integer()
      assert n >= 1
    end
  end

  describe "real wire shapes over the same faces" do
    test "list face returns 200 with value as a real list" do
      {:ok, token} = mint()
      {:ok, %{status: 200, body: body}} = get(token, list_url(@face, "2020-09-01"))
      assert %{"value" => value} = body
      assert is_list(value)
    end

    test "tokenless GET on the same face is a real 401 (bearer gate)" do
      {:ok, %{status: 401, body: body}} = get(nil, list_url(@face, "2020-09-01"))
      assert body["error"]["code"] in ["InvalidAuthenticationToken", "AuthenticationFailed", "Unauthorized"]
    end

    test "wrong api-version is a typed 400 naming the per-type latest" do
      {:ok, token} = mint()
      {:ok, %{status: 400, body: body}} = get(token, list_url("policyExemptions", "2099-01-01"))
      assert body["error"]["code"] == "InvalidApiVersionParameter"
      assert body["error"]["message"] =~ "policyExemptions"
    end
  end

  # -- Real collaborators ----------------------------------------------------
  # Real STS mint + real :httpc (same endpoints the module uses; the module
  # has no public fetch, so the test replicates the transport, not the
  # logic). Code-path warm-up per the host toolchain note.

  defp mint do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    repair_code_path()

    form =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://management.azure.com/.default"

    req =
      {~c"#{@base}/#{@tenant}/oauth2/v2.0/token", [],
       ~c"application/x-www-form-urlencoded", String.to_charlist(form)}

    case :httpc.request(:post, req, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode!(body) do
          %{"access_token" => tok} when is_binary(tok) -> {:ok, tok}
          other -> flunk("STS mint returned no access_token: #{inspect(other)}")
        end

      {:error, reason} ->
        flunk("SKIP(substrate-down:sts) transport: #{inspect(reason)}")
    end
  end

  defp list_url(face, ver),
    do: "#{@base}/subscriptions/#{@sub}/providers/Microsoft.Authorization/#{face}?api-version=#{ver}"

  defp get(nil, url) do
    req = {String.to_charlist(url), []}
    do_get(req)
  end

  defp get(token, url) do
    req = {String.to_charlist(url), [{~c"authorization", String.to_charlist("Bearer " <> token)}]}
    do_get(req)
  end

  defp do_get(req) do
    case :httpc.request(:get, req, [], body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} ->
        {:ok, %{status: status, body: Jason.decode!(body)}}

      {:error, reason} ->
        flunk("SKIP(substrate-down:#{req |> elem(0) |> List.to_string()}) transport: #{inspect(reason)}")
    end
  end

  defp repair_code_path do
    root = :code.root_dir() |> to_string()

    root
    |> then(&Path.wildcard(Path.join(&1, "lib/*/ebin")))
    |> Enum.each(&:code.add_pathz(String.to_charlist(&1)))
  end
end

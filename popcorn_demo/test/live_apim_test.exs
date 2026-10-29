defmodule PopcornDemo.LiveApimTest do
  use ExUnit.Case, async: false

  # Chicago-school leg for X2, UNSUPPORTED branch: the face-absence claim is
  # grounded on REAL wire observations against the live substrate (9443,
  # never restarted) — no mocks, no simulated absence. Non-vacuity: if an
  # ApiManagement face ever lands, run/0 must FAIL loudly, not keep
  # reporting SKIP.

  alias PopcornDemo.LiveApim

  @arm "http://127.0.0.1:9443"
  @probe_url "#{@arm}/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/x2/providers/Microsoft.ApiManagement/service/x2-probe?api-version=2022-08-01"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    root = :code.root_dir() |> to_string()

    root
    |> then(&Path.wildcard(Path.join(&1, "lib/*/ebin")))
    |> Enum.each(&:code.add_pathz(String.to_charlist(&1)))

    :ok
  end

  describe "run/0 — typed UNSUPPORTED(apim-face-absent)" do
    test "returns the honest SKIP fragment, never a fake pass" do
      assert {:skip, "apim=SKIP(apim-face-absent)"} = LiveApim.run()
    end
  end

  describe "face absence — real wire probes (Chicago)" do
    test "bearer-authed PUT of a would-be Microsoft.ApiManagement/service is typed-refused 400" do
      tok = mint!()
      body =
        Jason.encode!(%{
          "id" => "x2-probe",
          "name" => "x2-probe",
          "type" => "Microsoft.ApiManagement/service",
          "properties" => %{"publisherEmail" => "x2@smalt.local", "publisherName" => "x2"}
        })

      assert {:ok, {{_, 400, _}, _, resp}} =
               :httpc.request(
                 :put,
                 {String.to_charlist(@probe_url), auth(tok), ~c"application/json",
                  String.to_charlist(body)},
                 [],
                 body_format: :binary
               )

      # The refusal must be the TYPED ontology refusal, not an auth miss:
      assert %{"error" => %{"code" => "InvalidResourceShape", "message" => msg}} =
               Jason.decode!(resp)

      assert msg =~ "GraphLaw validation failure"
      assert msg =~ "not an admitted ontology individual"
      assert msg =~ "Microsoft.ApiManagement/service"
    end

    test "the refused PUT leaves no residue: authed GET of the same URI is 404" do
      tok = mint!()

      assert {:ok, {{_, 404, _}, _, _}} =
               :httpc.request(
                 :get,
                 {String.to_charlist(@probe_url), auth(tok)},
                 [],
                 []
               )
    end

    test "router source routes sibling faces but has no ApiManagement family" do
      # popcorn_demo/test -> repo root is two levels up
      router_src =
        Path.expand("../../lib/smalt/arm_gateway/router.ex", __DIR__)
        |> File.read!()

      refute router_src =~ "Microsoft.ApiManagement",
             "router.ex now routes Microsoft.ApiManagement — re-author the walk branch"

      # Sibling faces the router DOES route (guards against reading a
      # truncated/wrong router file — keeps this test non-vacuous).
      assert router_src =~ "Microsoft.Resources/resourceGroups"
      assert router_src =~ "Microsoft.DocumentDB/databaseAccounts"
    end
  end

  # -- Real collaborators ------------------------------------------------------

  defp mint! do
    form =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=https://management.azure.com/.default"

    url = "#{@arm}/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token"

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(
               :post,
               {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded",
                String.to_charlist(form)},
               [],
               body_format: :binary
             )

    assert %{"access_token" => tok} = Jason.decode!(body)
    tok
  end

  defp auth(tok), do: [{~c"authorization", String.to_charlist("Bearer " <> tok)}]
end

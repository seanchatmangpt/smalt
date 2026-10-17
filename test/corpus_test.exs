# Incidents-as-permanent-evals: wire-incident replay corpus.
#
# test/corpus/ holds one module per CLOSED incident family; each test is
# tagged :corpus and asserts the fixed wire shape cannot regress. This file
# loads every corpus module (so `mix test test/corpus_test.exs` runs them
# all) and fences the corpus contract itself: every family is present, cites
# its incident receipt/fix site, and every named fix site still exists in
# lib/.
defmodule CorpusTest do
  use ExUnit.Case, async: false

  @corpus_modules [
    Smalt.Corpus.ApiVersionAdmission,
    Smalt.Corpus.BlobContainerReput,
    Smalt.Corpus.HeadDatabaseAccountNames,
    Smalt.Corpus.SecretCrossPlaneSeed,
    Smalt.Corpus.CosmosArmContainer,
    Smalt.Corpus.VaultEnrichment,
    Smalt.Corpus.EhCreatedAt,
    Smalt.Corpus.TagsNormalization,
    Smalt.Corpus.ShaclFuzz
  ]

  # Every family cites the lib/ fix site that closed its incident (module +
  # a distinctive CALL-SHAPE pattern the fix must still contain). Regexes with
  # word boundaries + call shape, not bare substrings: a substring-preserving
  # mutation (normalize_tags → normalize_tags_vacuity) must FAIL this fence,
  # not ride through on the unchanged substring. Non-vacuity of this exact
  # property is proven by scripts/shim_court/corpus_fence_court.sh.
  @fix_sites [
    {Smalt.ArmGateway.Router, ~r/\bcheck_version\(/},
    {Smalt.EgressRouter, ~r/\bcontainer_reput_arm\(/},
    {Smalt.ArmGateway.Router, ~r{databaseAccountNames/:name}},
    {Smalt.ArmGateway.Router, ~r/\bseed_data_plane_secret\(/},
    {Smalt.ArmGateway.Router, ~r/\bseed_cosmos_child\(/},
    {Smalt.ArmGateway.Defaults, ~r/"vaultUri"/},
    {Smalt.ArmGateway.Defaults, ~r/"createdAt"/},
    {Smalt.ArmGateway.Router, ~r/\bnormalize_tags\(/},
    {Smalt.ArmGateway.Router, ~r/Defaults hydrate BEFORE shape validation/}
  ]

  @corpus_dir Path.join(__DIR__, "corpus")

  # Load helper first, then each family module. Case modules defined here are
  # registered with ExUnit for THIS run — one `mix test test/corpus_test.exs`
  # executes the whole corpus.
  corpus_files =
    ["helper", "api_version_admission", "blob_container_reput", "head_database_account_names",
     "secret_cross_plane_seed", "cosmos_arm_container", "vault_enrichment", "eh_created_at",
     "tags_normalization", "shacl_fuzz"]

  Enum.each(corpus_files, fn name ->
    Code.require_file(Path.join(@corpus_dir, "#{name}.exs"))
  end)

  test "corpus inventory: all 9 incident families are present" do
    Enum.each(@corpus_modules, fn m ->
      assert {:module, ^m} = Code.ensure_loaded(m), "corpus family missing: #{inspect(m)}"
    end)

    assert length(@corpus_modules) == 9
  end

  test "every corpus fix site still exists in lib/ (dead-citation fence)" do
    Enum.each(@fix_sites, fn {module, token} ->
      assert Code.ensure_loaded!(module)
      assert function_exported?(module, :module_info, 1)

      src =
        module
        |> List.wrap()
        |> then(fn [m] ->
          m.module_info(:compile)[:source] |> to_string()
        end)

      assert File.exists?(src)
      assert File.read!(src) =~ token,
             "fix site token #{inspect(token)} vanished from #{module}"
    end)
  end

  test "corpus files exist on disk (one per family, plus helper + README)" do
    files = File.ls!(@corpus_dir)

    for name <- @corpus_modules do
      expected =
        name |> Module.split() |> List.last() |> Macro.underscore()
        |> then(&(&1 <> ".exs"))

      assert expected in files, "missing corpus file #{expected} in #{@corpus_dir}"
    end

    assert "helper.exs" in files
    assert "README.md" in files
  end
end

# Integration-tier census (BK-PATW, v26.10.22): the population fence for
# test/integration, mirroring test/internal/internal_tier_census_test.exs.
#
# Elixir 1.20's default `*_test.exs` load filter silently does NOT load any
# other top-level `.exs` under a batched `mix test test/integration` — the
# batch-drop hazard BK-POWLH2-3/BK-POWLH4 named. This census makes every
# non-loading file a REGISTERED, typed row instead of a silent warning-list
# entry. Fail-closed: an unregistered non-pattern file trips the population
# fence; a registered row without a typed-skip reason trips the reason
# fence.
#
# Classes:
#   :script — non-ExUnit script court: plain `.exs` run individually per its
#             own `# Run:` header (elixir file.exs / mix run). The verdict is
#             the printed court line + exit contract, never ExUnit. It never
#             loads under the batched default load filter (silent
#             non-execution), so the skip is typed here, not silent.
#   :script_self_exit — a :script whose tail runner additionally calls
#             System.stop/halt at script end (loading one in the batch would
#             halt the VM mid-batch — the BK-POWLH2-3 class).
defmodule Integration.TierCensusTest do
  use ExUnit.Case, async: true

  @dir "test/integration"

  # -- registered script-class population --------------------------------------
  # Every top-level test/integration/*.exs that does NOT match `*_test.exs`
  # must appear here with its class + typed-skip reason. Growth is a
  # reviewed diff; removal is receipt-gated.
  @script_class %{
    "coldchain_pipeline_court.exs" =>
      {:script,
       "non-ExUnit script court: never loads under the batched mix test default load filter (silent non-execution) — run individually per its # Run: header; verdict is the printed COLD-1 COURT line + tmp/coldchain-court-result.terms"},
    "coldchain_sql_seed_court.exs" =>
      {:script,
       "non-ExUnit script court: never loads under the batched mix test default load filter (silent non-execution) — run individually per its # Run: header; verdict is the printed court lines"},
    "gld1_sql_n3_court.exs" =>
      {:script,
       "non-ExUnit script court: never loads under the batched mix test default load filter (silent non-execution) — run individually per its # Run: header; verdict is the printed GLD-1 COURT line + tmp/gld1-court-result.terms"},
    "gld2_cdc_court.exs" =>
      {:script_self_exit,
       "script court whose tail runner self-exits (System.stop/halt): loading it in the batch would halt the VM mid-batch — run individually per its # Run: header (exit 0 = PASS)"},
    "gld5fix_roundtrip_court.exs" =>
      {:script,
       "non-ExUnit script court: never loads under the batched mix test default load filter (silent non-execution) — run individually per its # Run: header (Code.compile_file + Gld5fix.Court.run())"},
    "ja12_hot_reload_court.exs" =>
      {:script,
       "non-ExUnit script court: never loads under the batched mix test default load filter (silent non-execution) — run individually; exit/1 contract on failure; also registered in scripts/sleep_gate_classes.json for its bounded receive timeouts"},
    "ja13_supervisor_intensity_court.exs" =>
      {:script,
       "non-ExUnit script court: never loads under the batched mix test default load filter (silent non-execution) — run individually (JA13.main()); verdict is the printed court verdict + exit contract"},
    "sj1_journal_sink_court.exs" =>
      {:script_self_exit,
       "script court whose tail runner self-exits (System.stop/halt): loading it in the batch would halt the VM mid-batch — run individually per its # Run: header (mix run)"},
    "sj4_journal_wire_court.exs" =>
      {:script_self_exit,
       "script court whose tail runner self-exits (System.stop/halt): loading it in the batch would halt the VM mid-batch — run individually per its # Run: header (mix run --no-start, MIX_ENV=dev)"},
    "w3cc_acp_court.exs" =>
      {:script_self_exit,
       "script court whose tail runner self-exits (non-ExUnit script: verdict is the printed court line + exit contract, never ExUnit — loading it in the batch would halt the VM mid-batch) — run individually per its # Run: header"},
    # Fixture GENERATORS (not courts): one-shot .exs utilities that build the
    # deterministic corpora under test/integration/fixtures/; run on demand
    # via `elixir`, never loaded by the batch (also a documented non-loading
    # class, registered here so the population fence is total).
    "fixtures/coldchain/generate_fixtures.exs" =>
      {:fixture_generator,
       "one-shot corpus generator (writes test/integration/fixtures/coldchain/*); not a court — run on demand via elixir, never loaded by the batch"},
    "fixtures/sqld2/generate_dump.exs" =>
      {:fixture_generator,
       "one-shot corpus generator (writes test/integration/fixtures/sqld2/*); not a court — run on demand via elixir, never loaded by the batch"}
  }

  test "population fence: every non-pattern top-level .exs is a registered script-class row" do
    on_disk =
      @dir
      |> Path.join("**/*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @dir))
      |> MapSet.new()

    pattern_files = MapSet.filter(on_disk, &String.ends_with?(&1, "_test.exs"))
    script_files = MapSet.difference(on_disk, pattern_files)

    unregistered = MapSet.difference(script_files, MapSet.new(Map.keys(@script_class)))
    stale = MapSet.difference(MapSet.new(Map.keys(@script_class)), script_files)

    assert unregistered == MapSet.new(),
           "UNREGISTERED non-pattern file(s) in test/integration — register in @script_class with a typed reason or convert to *_test.exs: #{inspect(MapSet.to_list(unregistered))}"

    assert stale == MapSet.new(),
           "STALE @script_class row(s) — file no longer on disk: #{inspect(MapSet.to_list(stale))}"
  end

  test "reason fence: every registered row carries a typed-skip reason naming its class" do
    for {file, {class, reason}} <- @script_class do
      assert class in [:script, :script_self_exit, :fixture_generator],
             "unknown class #{inspect(class)} for #{file}"
      assert is_binary(reason) and String.trim(reason) != "", "#{file} has no typed-skip reason"
    end
  end

  test "non-vacuity: registered script courts are non-ExUnit sources on disk" do
    for {file, {class, _reason}} <- @script_class do
      source = File.read!(Path.join(@dir, file))
      if class != :fixture_generator do
        refute source =~ "use ExUnit.Case", "#{file} is now ExUnit — reclassify or convert"
      end

      if class == :script_self_exit do
        assert source =~ ~r/System\.(stop|halt)/,
               "registered self-exit court #{file} has no System.stop/halt — reclassify"
      end
    end
  end
end

# Tier-population fence for the :stress tier (docs/jira/v26.10.18/
# rewrite-drafts/stress-tier.md §5/§7.2). Runs in the DEFAULT suite (untagged)
# so silent tag loss rings in T1, not only in the tier itself.
#
# Falsifier: delete any `@tag :stress` / `@moduletag :stress` line and this
# test fails — a hollowed tier cannot pass quietly.

defmodule StressTierCensusTest do
  use ExUnit.Case, async: true

  @tier_min 20

  test "stress tier population >= #{@tier_min} (tag loss fails loudly)" do
    {tagged, moduletagged} =
      Path.wildcard("test/**/*.{ex,exs}")
      |> Enum.sort()
      |> Enum.map(fn path ->
        s = File.read!(path)

        n_tags = length(Regex.scan(~r/^\s*@tag :stress\b/m, s))

        if Regex.match?(~r/^\s*@moduletag :stress\b/m, s) do
          # Module-tagged file: every "test " definition in it is a stress case.
          {n_tags, length(Regex.scan(~r/^\s*test "/m, s))}
        else
          {n_tags, 0}
        end
      end)
      |> Enum.unzip()

    tag_cases = Enum.sum(tagged)
    module_cases = Enum.sum(moduletagged)
    total = tag_cases + module_cases

    assert total >= @tier_min,
           "stress tier hollowed: only #{total} stress cases detected " <>
             "(#{tag_cases} @tag :stress + #{module_cases} in @moduletag :stress files); " <>
             "need >= #{@tier_min}. A tag was likely dropped."

    # The 15-row inventory from stress-tier.md §3 must be present.
    assert tag_cases >= 8, "expected >= 8 single-test :stress tags, got #{tag_cases}"
    assert length(Enum.filter(moduletagged, &(&1 > 0))) >= 7,
           "expected >= 7 module-tagged stress files"
  end
end

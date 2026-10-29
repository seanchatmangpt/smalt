# ERRC-R2 (RAISE) — Chicago-school live leg over the REAL smalt substrate
# (ARM control plane 9443, SB rules family). No mocks: run/0 walks the real
# ARM face — STS mint, RG/namespace/topic/subscription PUT, rule PUT/GET/
# LIST over real :httpc, then the vendored pure slice (Smalt.SbRules) over
# the real wire-returned filter. A down substrate surfaces as a loud FAIL
# naming the step, never a fake pass.
#
# Context: solo (live substrate leg, host-side :httpc).

defmodule PopcornDemo.LiveRulesTest do
  use ExUnit.Case, async: false

  alias PopcornDemo.LiveRules

  describe "run/0 full walk over live substrate" do
    test "returns OK with the rule listed" do
      assert {:ok, "rules=OK(popcorn-r:" <> rest} = LiveRules.run()
      n = rest |> String.split("-listed") |> hd() |> String.to_integer()
      assert n >= 1
    end
  end

  describe "pure slice over real wire-returned state" do
    test "compiles the real filter and matches a real-shaped message map" do
      rule = fetch_rule_via_http!()

      props = %{"filter" => rule["properties"]["filter"]}

      assert {:ok, {:sql_ast, ast}} = Smalt.SbRules.compile(props)

      matching = %{label: "popcorn", app_props: %{"priority" => 1}}
      non_matching = %{label: "other", app_props: %{}}

      assert Smalt.SbRules.filter_matches_for_test?(ast, matching)
      refute Smalt.SbRules.filter_matches_for_test?(ast, non_matching)
    end

    test "wire echo carries the SB child id convention (no /providers/)" do
      rule = fetch_rule_via_http!()
      assert rule["id"] == LiveRules.expected_id()
    end
  end

  # -- Real collaborator -----------------------------------------------------
  # A real :httpc GET (with fresh STS mint) against the same endpoint run/0
  # uses, so the slice assertions consume the real wire record, not
  # module-internal state.

  defp fetch_rule_via_http! do
    case LiveRules.fetch_rule() do
      {:ok, rule} -> rule
      other -> flunk("live rule GET failed: #{inspect(other)}")
    end
  end
end

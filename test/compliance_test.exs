# Compliance corpus loader: test/compliance/*.exs (c1..c7) are wire-court
# suites whose filenames never matched the default `*_test.exs` ExUnit glob
# and which nothing required — 170 tests that never ran in any gate. This
# driver follows the test/corpus_test.exs precedent: Code.require_file every
# family, then fence the inventory (all modules load; per-file `test "` counts
# match the register; the register sums to 170).
defmodule ComplianceLoaderTest do
  use ExUnit.Case, async: false

  @compliance_modules [
    Smalt.Compliance.C1ArmTest,
    Compliance.C2KeyvaultTest,
    Smalt.Compliance.C3CosmosTest,
    Smalt.Compliance.C4BlobTest,
    Smalt.Compliance.C5ServicebusTest,
    Smalt.Compliance.C6OauthTest,
    Smalt.Compliance.C7EventsTest
  ]

  @compliance_dir Path.join(__DIR__, "compliance")

  # Per-file `test "` counts (grep -cE '^\s*test ' test/compliance/*.exs).
  @register_counts %{
    "c1_arm" => 26,
    "c2_keyvault" => 16,
    "c3_cosmos" => 28,
    "c4_blob" => 49,
    "c5_servicebus" => 16,
    "c6_oauth" => 18,
    "c7_events" => 17
  }

  c_files = ["c1_arm", "c2_keyvault", "c3_cosmos", "c4_blob", "c5_servicebus", "c6_oauth", "c7_events"]

  Enum.each(c_files, fn name ->
    Code.require_file(Path.join(@compliance_dir, "#{name}.exs"))
  end)

  test "compliance inventory: all 7 families are present" do
    Enum.each(@compliance_modules, fn m ->
      assert {:module, ^m} = Code.ensure_loaded(m), "compliance family missing: #{inspect(m)}"
    end)
  end

  test "compliance inventory: per-file test counts match the register" do
    Enum.each(@register_counts, fn {name, expected} ->
      body = File.read!(Path.join(@compliance_dir, "#{name}.exs"))
      actual = Enum.count(String.split(body, "\n"), fn line ->
        Regex.match?(~r/^\s*test /, line)
      end)
      assert actual == expected, "compliance #{name}: #{actual} tests, register says #{expected}"
    end)
  end

  test "compliance inventory: the register sums to 170" do
    assert @register_counts |> Map.values() |> Enum.sum() == 170
  end
end

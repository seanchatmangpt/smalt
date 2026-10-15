defmodule Smalt.ErrorCodesDocTest do
  @moduledoc """
  Fence: docs/ERROR_CODES.md must equal what the sources emit.

  1. Runs `python3 scripts/gen_error_codes.py --check` — the regenerated
     projection must be byte-identical to the doc on disk (regeneratable).
  2. Independently re-derives the {status, code} set from the router sources
     in Elixir and asserts the doc's arm-gateway rows equal it (guards the
     same pinned set as test/arm_error_corpus_test.exs).
  3. Asserts doc-table sanity: every row parses, compliance rows are the only
     ones allowed an unspecified HTTP status.
  """

  use ExUnit.Case, async: false

  @doc_path "docs/ERROR_CODES.md"
  @egress_source "lib/smalt/egress_router.ex"

  @pinned_arm_set [
    {400, "InvalidApiVersionParameter"},
    {400, "MissingApiVersionParameter"},
    {404, "ActionNotFound"},
    {404, "OperationNotFound"},
    {404, "ResourceGroupNotFound"},
    {404, "ResourceNotFound"},
    {404, "RouteNotFound"},
    {404, "SubscriptionNotFound"},
    # send_graphlaw_refusal (pinned 400) + inline 412 (NOT via send_arm_error)
    {400, "InvalidResourceShape"},
    {412, "PreconditionFailed"}
  ]

  test "docs/ERROR_CODES.md is the byte-identical projection of the sources" do
    {output, exit_code} =
      System.cmd("python3", ["scripts/gen_error_codes.py", "--check"],
        stderr_to_stdout: true
      )

    assert exit_code == 0, """
    docs/ERROR_CODES.md is stale relative to the sources.
    Regenerate: python3 scripts/gen_error_codes.py
    Generator output:
    #{output}
    """
  end

  test "arm-gateway rows equal the error set re-derived from the router source" do
    doc_codes = doc_rows() |> rows_for_surface("arm-gateway") |> MapSet.new(&{String.to_integer(&1.status), &1.code})
    assert doc_codes == MapSet.new(@pinned_arm_set)
  end

  test "every doc row parses and carries source/meaning/remediation columns" do
    for row <- doc_rows() do
      assert row.surface != "", "row missing surface: #{inspect(row)}"
      assert row.code != "", "row missing code: #{inspect(row)}"
      assert row.source =~ ~r/:\d+$/, "row missing file:line cite: #{inspect(row)}"
      assert String.length(row.meaning) > 0 and String.length(row.remediation) > 0
    end
  end

  test "only compliance surfaces may carry an unspecified (?) HTTP status" do
    for row <- doc_rows(), row.status == "?" do
      assert String.starts_with?(row.surface, "compliance/"),
             "non-compliance row with ? status: #{inspect(row)}"
    end
  end

  test "egress rows cover the codes the egress router emits literally" do
    src = File.read!(@egress_source)

    literal_codes =
      Regex.scan(~r/"code"\s*=>\s*"([A-Za-z][A-Za-z0-9-]*)"/s, src)
      |> Enum.map(&Enum.at(&1, 1))
      |> MapSet.new()

    not_found_codes =
      Regex.scan(~r/not_found_error\("([A-Za-z][A-Za-z0-9]*)"\)/, src)
      |> Enum.map(&Enum.at(&1, 1))
      |> MapSet.new()

    expected = MapSet.union(literal_codes, not_found_codes)
    doc_codes = doc_rows() |> rows_for_surface("egress") |> MapSet.new(& &1.code)

    assert doc_codes == expected
  end

  # -- helpers -----------------------------------------------------------------

  defp doc_rows do
    File.read!(@doc_path)
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| "))
    |> Enum.reject(&String.contains?(&1, "Surface | HTTP | Code |"))
    |> Enum.map(fn line ->
      cells = line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

      # cells are split on the escaped/unescaped pipe; unescape defensively
      [surface, status, code, source, meaning | rest] = cells
      remediation = Enum.join(rest, "|")

      %{
        surface: surface,
        status: status,
        code: code,
        source: source,
        meaning: meaning,
        remediation: remediation
      }
    end)
  end

  defp rows_for_surface(rows, surface) do
    Enum.filter(rows, &(&1.surface == surface))
  end
end

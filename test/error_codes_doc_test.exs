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
    {412, "PreconditionFailed"},
    # R30 resource-group location immutability (do_rg_put/4 send_arm_error site)
    {400, "LocationMismatch"},
    # Cross-lane integration: codes emitted by concurrently landed source edits
    # (sb-rules lane, azapi filter lane) registered here.
    {400, "InvalidAction"},
    {400, "InvalidFilter"},
    {404, "RuleNotFound"},
    # ARM secret rotation trigger (v26.10.16 console C4 lane): typed 409 when
    # the ARM record exists but carries no data-plane version to rotate.
    {409, "SecretVersionNotFound"},
    # Smalt.Policy inline denial (violation_body/2, NOT send_arm_error; fixed
    # 400 per the module doc) — generator parses policy.ex directly (X7).
    {400, "PolicyViolation"}
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

    # The LRO poll route emits its typed error member (status Failed at 200)
    # from lro.ex, not router.ex — re-derive it the same way the generator
    # does (the "code" literal inside the evaluate/2 fallback) so a new LRO
    # error code without a doc regen fails this fence (lens-10 cycle-1).
    lro_src = File.read!("lib/smalt/arm_gateway/lro.ex")
    lro_codes =
      # def/p-def tolerant anchor (sibling refactor promoted evaluate/2 to
      # def; witnessed 2026-10-15, v26.10.14 lane 14) — matches the generator
      case Regex.run(~r/defp? evaluate\((?s:.)*"code"\s*=>\s*"([A-Za-z][A-Za-z0-9]*)"/, lro_src) do
        [_, code] -> MapSet.new([{200, code}])
        _ -> MapSet.new()
      end

    assert doc_codes == MapSet.union(MapSet.new(@pinned_arm_set), lro_codes)
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

  test "compliance rows cover every code the compliance corpus pins literally" do
    expected =
      Path.wildcard("test/compliance/*.exs")
      |> Enum.flat_map(fn f ->
        src = File.read!(f)

        # Mirror the generator's compliance pattern exactly: the "error" member
        # (RFC 6749 §5.2 OAuth token endpoint, compliance/c6-oauth) and
        # underscore codes (invalid_request et al.) are pinned codes too.
        Regex.scan(~r/\[\s*"(?:code|error)"\s*\]\s*==\s*"([A-Za-z0-9_-]+)"/, src)
        |> Enum.map(fn [_, code] ->
          {"compliance/#{Path.basename(f, ".exs") |> String.replace("_", "-")}", code}
        end)
      end)
      |> MapSet.new()

    doc_compliance =
      doc_rows()
      |> Enum.filter(&String.starts_with?(&1.surface, "compliance/"))
      |> MapSet.new(&{&1.surface, &1.code})

    assert doc_compliance == expected,
           "compliance coverage drift: doc=#{inspect(MapSet.to_list(doc_compliance))} sources=#{inspect(MapSet.to_list(expected))}"
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

    # Mirror the generator's helper-def skip (R143): "code" literals inside a
    # defp ...error / defp ...api_version definition window are emitted with a
    # fixed status added separately (witnessed: invalid_eg1_event_error's
    # InvalidEventGridEvent), so they are NOT standalone doc rows.
    lines = String.split(src, "\n")

    helper_skipped =
      Enum.with_index(lines, 1)
      |> Enum.flat_map(fn {line, i} ->
        if Regex.match?(~r/"code"\s*=>\s*"([A-Za-z][A-Za-z0-9-]*)"/, line) do
          window = Enum.slice(lines, max(0, i - 15), 15)

          if Enum.any?(window, &Regex.match?(~r/defp\s+\w*(error|api_version)/, &1)) do
            case Regex.run(~r/"code"\s*=>\s*"([A-Za-z][A-Za-z0-9-]*)"/, line) do
              [_, code] -> [code]
              _ -> []
            end
          else
            []
          end
        else
          []
        end
      end)
      |> MapSet.new()

    expected =
      literal_codes
      |> MapSet.difference(helper_skipped)
      # The generator re-adds the helper-defined envelopes with fixed statuses
      # (see gen_error_codes.py "helper-defined envelopes" table, R143).
      |> MapSet.union(
        MapSet.new(["RouteNotReady", "InvalidBody", "InvalidCloudEvent", "InvalidQueryParameterValue", "InvalidApiVersion", "InvalidEventGridEvent"])
      )
      |> MapSet.union(not_found_codes)

    doc_codes = doc_rows() |> rows_for_surface("egress") |> MapSet.new(& &1.code)

    assert doc_codes == expected
  end

  test "a doc row with an escaped pipe parses with an intact meaning/remediation boundary" do
    # The generator escapes literal pipes as `\|`; the fence's own row parser
    # must mirror Smalt.DSPy.Remediation.split_row/1 (lens-4: a naive split
    # silently corrupts the meaning/remediation boundary and stays green).
    doc = """
    <!-- gen -->
    # ERROR_CODES

    | Surface | HTTP | Code | Source | Meaning | Remediation (agent hint) |
    |---|---|---|---|---|---|
    | egress | 400 | PipeCode | s.ex:1 | mean \\| ing | rem \\| ed |
    """

    rows =
      doc
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| "))
      |> Enum.reject(&String.contains?(&1, "Surface | HTTP | Code |"))
      |> parse_row_lines()

    assert [%{code: "PipeCode", meaning: "mean | ing", remediation: "rem | ed"}] = rows
  end

  # -- helpers -----------------------------------------------------------------

  defp doc_rows do
    File.read!(@doc_path)
    |> String.split("\n")
    # Scope to the main surface table: everything before the "Bearer
    # sub-codes" section (whose rows carry a different 5-column shape and are
    # fenced separately by the generator's own --check byte-identity).
    |> Enum.take_while(&(&1 != "## Bearer sub-codes"))
    |> Enum.filter(&String.starts_with?(&1, "| "))
    |> Enum.reject(&String.contains?(&1, "Surface | HTTP | Code |"))
    |> parse_row_lines()
  end

  defp parse_row_lines(lines) do
    Enum.map(lines, fn line ->
      # Escape-aware scan mirroring Smalt.DSPy.Remediation.split_row/1 (lens-5
      # hostile cells): `\|` is a literal pipe, `\\` a literal backslash, and
      # a lone trailing `\|` is content — a naive "|" split silently corrupts
      # the meaning/remediation boundary and stays green.
      cells =
        line
        |> String.graphemes()
        |> scan_cells([], [])
        |> Enum.map(&String.trim/1)

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

  defp scan_cells(["\\" | [next | rest]], cur, cells),
    do: scan_cells(rest, [next | cur], cells)

  # A lone trailing backslash needs no special clause: the generic char clause
  # below already keeps it as content (lens-6: dedicated clause deleted as an
  # equivalent-mutant dead code).

  defp scan_cells(["|" | rest], cur, cells),
    do: scan_cells(rest, [], [cur | cells])

  defp scan_cells([c | rest], cur, cells),
    do: scan_cells(rest, [c | cur], cells)

  defp scan_cells([], cur, cells) do
    all = (Enum.reverse(cells) ++ [cur]) |> Enum.map(&Enum.reverse/1) |> Enum.map(&Enum.join/1)

    case all do
      ["" | rest] ->
        case Enum.reverse(rest) do
          ["" | inner] -> Enum.reverse(inner)
          _ -> rest
        end

      other ->
        other
    end
  end

  defp rows_for_surface(rows, surface) do
    Enum.filter(rows, &(&1.surface == surface))
  end
end

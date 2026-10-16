defmodule Smalt.DSPy.RemediationTest do
  @moduledoc """
  Deterministic unit tests for the offline DSPy remediation signature.
  Chicago discipline: real doc file, real transformation, no mocks, no
  network, no LLM. The end-to-end run writes to a unique tmp dir deleted in
  the same test (lane-lease cleanup law).
  """

  use ExUnit.Case, async: true

  alias Smalt.DSPy.Remediation

  @doc_path Path.expand("docs/ERROR_CODES.md", File.cwd!())

  defp row(code, source, hint) do
    %Remediation{surface: "s", http: "1", code: code, source: source, meaning: "m", hint: hint}
  end

  # A minimal synthetic table with known shape (used for determinism asserts
  # independent of the live doc's row set).
  @sample """
  # ERROR_CODES

  | Surface | HTTP | Code | Source | Meaning | Remediation (agent hint) |
  |---|---|---|---|---|---|
  | arm-gateway | 400 | InvalidApiVersionParameter | lib/x.ex:1 | bad version. [annotation] | Send the latest version. |
  | egress | 404 | BlobNotFound | lib/y.ex:2 | no blob. [annotation] | PUT the blob first. |
  | compliance/c2-keyvault | ? | KeyNotFound | test/z.exs:9 | no key. [annotation] | Read the message body; fix the request per the cited source. |
  trailing line outside table
  """

  describe "parse/1" do
    test "parses typed rows from the real doc" do
      doc = File.read!(@doc_path)
      rows = Remediation.parse(doc)

      assert rows != []
      assert %Remediation{} = hd(rows)
      # Every row fully typed: no nil fields, no residual pipe artifacts.
      Enum.each(rows, fn r ->
        assert r.surface != "" and r.http != "" and r.code != ""
        assert r.source != "" and r.meaning != "" and r.hint != ""
        refute String.contains?(r.code, "|")
      end)
    end

    test "is deterministic on the real doc" do
      doc = File.read!(@doc_path)
      assert Remediation.parse(doc) == Remediation.parse(doc)
    end

    test "returns [] when no table present and stops at table end" do
      assert Remediation.parse("no table here\nat all") == []
      assert length(Remediation.parse(@sample)) == 3
    end

    test "raises on a malformed row instead of skipping" do
      bad = String.replace(@sample, "| egress | 404 | BlobNotFound", "| egress | 404")

      assert_raise ArgumentError, ~r/malformed ERROR_CODES row/, fn ->
        Remediation.parse(bad)
      end
    end

    test "escaped pipes in cells (generator esc/1 output) parse as content, not cell breaks" do
      # A generator annotation containing a literal pipe is emitted as `\|`;
      # the parser must not split on it (lens-4 witnessed 7-cell false raise).
      doc = """
      | Surface | HTTP | Code | Source | Meaning | Remediation (agent hint) |
      |---|---|---|---|---|---|
      | egress | 400 | X | s.ex:1 | a \\| b | hint \\| more |
      """

      assert [%Remediation{} = row] = Remediation.parse(doc)
      assert {row.surface, row.http, row.code} == {"egress", "400", "X"}
      assert row.meaning == "a | b"
      assert row.hint == "hint | more"
    end

    test "hostile cells: doubled escape, literal backslash+pipe, and trailing escaped pipe (lens 5)" do
      # Doc bytes the NEW generator esc/1 can emit (backslash escaped first):
      #   source `a\|b`    -> doc `a\\|b`   (one cell, backslash + pipe kept)
      #   source `x\\y`    -> doc `x\\\\y`  (literal backslashes kept)
      #   source `end|`    -> doc `end\|` at row end (content, not terminator)
      doc = """
      | Surface | HTTP | Code | Source | Meaning | Remediation (agent hint) |
      |---|---|---|---|---|---|
      | egress | 400 | Esc | s.ex:1 | a \\\\ | b |
      | egress | 400 | Bs | s.ex:2 | x \\\\ y | r2 |
      | egress | 400 | Trail | s.ex:3 | m3 | ends \\|
      """

      assert [%Remediation{} = esc, %Remediation{} = bs, %Remediation{} = trail] =
               Remediation.parse(doc)

      # `\\` (doubled escape) = literal backslash; the following pipe is a
      # REAL separator: meaning "a \" with hint "b" recovers exactly.
      assert esc.meaning == "a \\"
      assert esc.hint == "b"

      # `\\` mid-cell = literal backslash, no split.
      assert bs.meaning == "x \\ y"

      # A trailing `\|` on the row's LAST cell is CONTENT: no terminator
      # artifact, no corruption, and the row needs no extra terminator pipe.
      assert trail.meaning == "m3"
      assert trail.hint == "ends |"
    end

    test "round-trip: every esc/1-emittable hostile cell parses back to its source" do
      # Property pin of the esc/1 <-> split_row/1 inverse pair (lens 5): for
      # each hostile source cell, project with the generator's own esc
      # semantics and require parse/1 to restore the original cell.
      for source <- ["a|b", "a\\|b", "x\\y", "ends|", "\\", "|", "\\|", "p|q|r"] do
        esc =
          source
          |> String.replace("\\", "\\\\")
          |> String.replace("|", "\\|")

        doc = """
        | Surface | HTTP | Code | Source | Meaning | Remediation (agent hint) |
        |---|---|---|---|---|---|
        | egress | 400 | RT | s.ex:1 | #{esc} | hint |
        """

        assert [%Remediation{} = row] = Remediation.parse(doc)
        assert row.meaning == String.trim(source), "round-trip failed for #{inspect(source)}"
      end
    end

    test "round-trip through the REAL generator esc/1: source -> doc bytes -> parse restores the source (lens 6)" do
      # The lens-5/6 property pinned above mirrors esc/1 in Elixir; THIS pin
      # calls the real generator (scripts/gen_error_codes.py esc/1) through a
      # python subprocess so the doc bytes are produced by the shipping esc,
      # not by a mirror (Chicago: real collaborators). Any drift between the
      # mirror and the real esc breaks this test.
      py =
        "import sys; sys.path.insert(0, 'scripts'); import gen_error_codes as g\n" <>
          "print(g.esc(sys.argv[1]))\n"

      sources = ["a|b", "a\\|b", "x\\y", "ends|", "\\", "|", "\\|", "p|q|r", "a \\\\ b | c"]

      escaped =
        Enum.map(sources, fn s ->
          {out, 0} = System.cmd("python3", ["-c", py, s])
          String.trim_trailing(out, "\n")
        end)

      for {source, esc} <- Enum.zip(sources, escaped) do
        doc = """
        | Surface | HTTP | Code | Source | Meaning | Remediation (agent hint) |
        |---|---|---|---|---|---|
        | egress | 400 | RT6 | s.ex:1 | #{esc} | hint |
        """

        assert [%Remediation{} = row] = Remediation.parse(doc)
        assert row.meaning == String.trim(source), "real-esc round-trip failed for #{inspect(source)}"
      end
    end
  end

  describe "propose/1" do
    test "splits adopted vs boilerplate-flagged rows deterministically" do
      rows = Remediation.parse(@sample)

      %{adopted: adopted, needs_review: needs_review} = proposals = Remediation.propose(rows)

      assert Enum.map(adopted, & &1.code) == ["InvalidApiVersionParameter", "BlobNotFound"]
      assert Enum.map(needs_review, & &1.code) == ["KeyNotFound"]
      # Deterministic: same input => identical digests.
      assert proposals.evidence_digest == Remediation.propose(rows).evidence_digest
      assert String.length(proposals.evidence_digest) == 64
    end
  end

  describe "court_verdict/1" do
    test "passes at the reuse rung with zero llm residue and a digest" do
      proposals = Remediation.propose(Remediation.parse(@sample))
      verdict = Remediation.court_verdict(proposals)

      assert verdict.passed
      assert verdict.rung == :reuse
      assert verdict.score == 1.0
      assert String.length(verdict.verdict_digest) == 64
      assert verdict.verdict_digest == Remediation.court_verdict(proposals).verdict_digest
    end

    test "duplicate code rows are preserved, never silently deduplicated or shadowed" do
      # registry-analogue anti-last-wins pin (lens-3): unlike a name-keyed
      # registry, duplicate error-code rows both survive to the human review
      r1 = row("DUP", "a:1", "h")
      r2 = row("DUP", "a:2", "h2")

      proposals = Remediation.propose([r1, r2])

      assert proposals.adopted == [r1, r2]
      assert proposals.needs_review == []
    end

    test "empty proposals fail the court closed (no rows => no pass)" do
      refute Remediation.court_verdict(%{adopted: [], needs_review: [], evidence_digest: "x"}).passed
    end
  end

  describe "render_review/3" do
    test "renders byte-identical markdown for identical input" do
      doc = File.read!(@doc_path)
      proposals = Remediation.propose(Remediation.parse(doc))
      verdict = Remediation.court_verdict(proposals)

      a = Remediation.render_review(doc, proposals, verdict)
      b = Remediation.render_review(doc, proposals, verdict)

      assert a == b
      assert a =~ "Reuse (1/8, non-LLM)"
      assert a =~ proposals.evidence_digest
      assert a =~ "INAPPLICABLE-RUNTIME"
    end
  end

  describe "run/2 end-to-end (real file IO, temp dir cleaned on exit)" do
    test "writes the review file with expected summary" do
      out_dir = Path.join(System.tmp_dir!(), "smalt-dspy-test-#{System.unique_integer([:positive])}")
      out_path = Path.join(out_dir, "review.md")

      on_exit(fn -> File.rm_rf!(out_dir) end)

      assert {:ok, ^out_path,
              %{total: total, adopted: adopted, needs_review: needs_review}} =
               Remediation.run(@doc_path, out_path)

      assert total == adopted + needs_review and total > 0

      content = File.read!(out_path)
      assert content =~ "# DSPy remediation review"
      assert content =~ "Evidence digest"
    end
  end
end

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

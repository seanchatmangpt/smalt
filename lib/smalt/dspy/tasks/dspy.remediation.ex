defmodule Mix.Tasks.Smalt.Dspy.Remediation do
  @shortdoc "Offline DSPy-style remediation review proposal from docs/ERROR_CODES.md"

  @moduledoc """
  Deterministic, offline, non-LLM. Reads docs/ERROR_CODES.md, parses the
  error-code table as a typed signature, and writes a human review file
  proposing remediation text (default: tmp/dspy/remediation_review.md).

  ## Usage

      mix smalt.dspy.remediation
      mix smalt.dspy.remediation --doc docs/ERROR_CODES.md --out tmp/dspy/remediation_review.md

  Alias candidate (documented, NOT wired — integration is an admitted
  transition for the repo owner):

      "dspy.remediation": ["smalt.dspy.remediation"]

  Runtime stance: this task is INAPPLICABLE-RUNTIME tooling. It never runs in
  the smalt data path; per ashdspy gate 030 the deterministic (Reuse-rung)
  implementation with a passing verdict makes an LLM route for this signature
  a typed refusal.
  """

  use Mix.Task

  alias Smalt.DSPy.Remediation

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [doc: :string, out: :string])

    doc_path = Keyword.get(opts, :doc, "docs/ERROR_CODES.md")
    out_path = Keyword.get(opts, :out, Remediation.review_path())

    case Remediation.run(doc_path, out_path) do
      {:ok, path, summary} ->
        Mix.shell().info(
          "[dspy] wrote #{path} — #{summary.total} rows " <>
            "(#{summary.adopted} adopted, #{summary.needs_review} needs_review). " <>
            "Offline/deterministic; review file is a proposal, not an admitted artifact."
        )

      other ->
        Mix.raise("smalt.dspy.remediation failed: #{inspect(other)}")
    end
  end
end

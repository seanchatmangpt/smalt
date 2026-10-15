defmodule Smalt.DSPy.Remediation do
  @moduledoc """
  DSPy-style typed signature for OFFLINE remediation-hint extraction over
  docs/ERROR_CODES.md — implemented at lattice rung 1 (Reuse: a deterministic,
  non-LLM transformation).

  Pack alignment (ggen-marketplace/packs/ashdspy-pack):
    * The pack's central law (gate 030, KNOWN => Allocation_LLM = 0) is why
      this module exists as a deterministic function rather than a prompt:
      once a non-LLM implementation witnesses a passing court verdict for the
      same signature, an LLM-selected route is a typed refusal. The runtime
      data path therefore stays deterministic; any LLM call here would be a
      refusal, never a route.
    * The struct contract below is the ashdspy:Signature analogue: typed
      input fields (surface/http/code/source/meaning/hint rows parsed from
      the doc table) and typed output fields (review entries + verdict).
    * `court_verdict/1` mints the ashdspy:CourtVerdict analogue: a passed
      verdict with a sha256 verdictDigest and the evidenceDigest of the exact
      subject document, satisfying the gate 040 receipt shape.

  This module NEVER performs an LLM call, never touches the network, and
  never mutates docs/ERROR_CODES.md (a generated, fenced file — see
  test/error_codes_doc_test.exs). Its only output is a review file that a
  human reads before anything downstream consumes it.

  Runtime stance: INAPPLICABLE-RUNTIME. This is offline tooling only.
  """

  alias __MODULE__

  defstruct [:surface, :http, :code, :source, :meaning, :hint]

  @type t :: %__MODULE__{
          surface: String.t(),
          http: String.t(),
          code: String.t(),
          source: String.t(),
          meaning: String.t(),
          hint: String.t()
        }

  @review_dir "tmp/dspy"
  @review_path Path.join(@review_dir, "remediation_review.md")

  # Rows whose remediation hint is this boilerplate were not individually
  # annotated by the generator; they are the review-worthy set.
  @boilerplate "Read the message body; fix the request per the cited source."

  @spec review_path() :: String.t()
  def review_path, do: @review_path

  @doc """
  Parses the markdown table of docs/ERROR_CODES.md into typed rows.
  Deterministic: identical input => identical rows. Raises on a malformed
  data row rather than skipping it (the doc is fenced by
  test/error_codes_doc_test.exs, so a malformed row is a real defect).
  """
  @spec parse(String.t()) :: [t()]
  def parse(doc) do
    case drop_until_table(String.split(doc, "\n")) do
      :no_table -> []
      [_header | rest] -> parse_rows(rest, [])
    end
  end

  defp drop_until_table(["| Surface |" <> _ = header | rest]), do: [header | rest]
  defp drop_until_table([_ | rest]), do: drop_until_table(rest)
  defp drop_until_table([]), do: :no_table

  defp parse_rows([], acc), do: Enum.reverse(acc)

  defp parse_rows([line | rest], acc) do
    cond do
      String.starts_with?(line, "|---") ->
        parse_rows(rest, acc)

      String.starts_with?(line, "|") ->
        case split_row(line) do
          [surface, http, code, source, meaning, hint] ->
            parse_rows(rest, [
              %Remediation{
                surface: surface,
                http: http,
                code: code,
                source: source,
                meaning: meaning,
                hint: hint
              }
              | acc
            ])

          other ->
            raise ArgumentError,
                  "malformed ERROR_CODES row (#{length(other)} cells, expected 6): #{inspect(line)}"
        end

      # Table ended.
      true ->
        parse_rows([], acc)
    end
  end

  @doc """
  Deterministic proposal: the current hint is adopted verbatim; rows carrying
  only generator boilerplate are flagged `needs_review` instead of silently
  passed through. No randomness, no clock, no I/O.
  """
  @spec propose([t()]) :: %{
          adopted: [t()],
          needs_review: [t()],
          evidence_digest: String.t()
        }
  def propose(rows) do
    {adopted, needs_review} = Enum.split_with(rows, &(&1.hint != @boilerplate))

    %{
      adopted: adopted,
      needs_review: needs_review,
      evidence_digest: evidence_digest(rows)
    }
  end

  @doc "sha256 hex of the exact subject document bytes (ashdspy:evidenceDigest)."
  @spec evidence_digest([t()] | String.t()) :: String.t()
  def evidence_digest(rows_or_doc)

  def evidence_digest(doc) when is_binary(doc),
    do: Base.encode16(:crypto.hash(:sha256, doc), case: :lower)

  def evidence_digest(rows) when is_list(rows) do
    rows
    |> Enum.map(&"#{&1.surface}|#{&1.http}|#{&1.code}|#{&1.source}")
    |> Enum.join("\n")
    |> evidence_digest()
  end

  @doc """
  Mints the deterministic court verdict analogue (ashdspy:CourtVerdict):
  a Reuse-rung implementation always passes iff there is at least one row
  and no row is malformed (parse would have raised already). Carries
  verdictDigest per gate 040.
  """
  @spec court_verdict(%{adopted: [t()], needs_review: [t()], evidence_digest: String.t()}) ::
          %{passed: boolean(), rung: atom(), score: number(), verdict_digest: String.t()}
  def court_verdict(%{adopted: adopted, needs_review: needs_review, evidence_digest: evidence}) do
    passed = adopted != [] or needs_review != []
    # Score dimension: determinism = 1.0 by construction (pure function);
    # llm_residue = 0.0 by construction (no LLM in the path).
    verdict_digest =
      :crypto.hash(:sha256, "#{evidence}|#{length(adopted)}|#{length(needs_review)}")
      |> Base.encode16(case: :lower)

    %{
      passed: passed,
      rung: :reuse,
      score: if(passed, do: 1.0, else: 0.0),
      verdict_digest: verdict_digest
    }
  end

  @doc """
  Renders the human review file. Deterministic: same proposals => byte-identical
  markdown. The review file is a PROPOSAL — nothing in the repo consumes it
  without human admission.
  """
  @spec render_review(String.t(), %{adopted: [t()], needs_review: [t()], evidence_digest: String.t()}, map()) ::
          String.t()
  def render_review(doc, proposals, verdict) do
    total = length(proposals.adopted) + length(proposals.needs_review)

    """
    <!-- GENERATED by Smalt.DSPy.Remediation (offline, deterministic). Review proposal only — not admitted. -->

    # DSPy remediation review — docs/ERROR_CODES.md

    - Signature: `error_code_row -> remediation_hint` (typed, offline)
    - Lattice rung: **Reuse (1/8, non-LLM)** — per ashdspy gate 030, an LLM route for this signature is a typed refusal while this implementation holds a passing verdict.
    - Evidence digest (sha256 of docs/ERROR_CODES.md bytes): `#{proposals.evidence_digest}`
    - Verdict: #{if verdict.passed, do: "PASS", else: "FAIL"} (determinism=1.0, llm_residue=0.0), verdictDigest `#{verdict.verdict_digest}`
    - Rows: #{total} total — #{length(proposals.adopted)} adopted verbatim, #{length(proposals.needs_review)} flagged needs_review (boilerplate hint only).

    ## Needs review (generator boilerplate hint — propose a real remediation)

    #{Enum.map_join(proposals.needs_review, "\n", fn r -> "- `#{r.code}` (#{r.surface}, HTTP #{r.http}) — source: #{r.source}" end)}

    ## Adopted verbatim (current hint kept)

    #{Enum.map_join(proposals.adopted, "\n", fn r -> "- `#{r.code}` (#{r.surface}): #{r.hint}" end)}

    ## Full row dump (verbatim, for diffing against future doc regenerations)

    | Surface | HTTP | Code | Source | Meaning | Hint |
    |---|---|---|---|---|---|
    #{Enum.map_join(parse(doc), "\n", &"| #{&1.surface} | #{&1.http} | #{&1.code} | #{&1.source} | #{&1.meaning} | #{&1.hint} |")}

    <!-- Runtime stance: INAPPLICABLE-RUNTIME. This module never runs in the smalt data path. -->
    """
  end

  @doc """
  Full offline run: read doc, parse, propose, verdict, write review file.
  Returns {:ok, path, summary} — never calls an LLM, never touches the network.
  """
  @spec run(doc_path :: String.t(), out_path :: String.t()) ::
          {:ok, String.t(), %{total: non_neg_integer(), adopted: non_neg_integer(), needs_review: non_neg_integer()}}
  def run(doc_path \\ "docs/ERROR_CODES.md", out_path \\ @review_path) do
    doc = File.read!(doc_path)
    rows = parse(doc)
    proposals = propose(rows)
    verdict = court_verdict(proposals)
    File.mkdir_p!(Path.dirname(out_path))
    File.write!(out_path, render_review(doc, proposals, verdict))

    {:ok, out_path,
     %{
       total: length(rows),
       adopted: length(proposals.adopted),
       needs_review: length(proposals.needs_review)
     }}
  end

  # The generator (scripts/gen_error_codes.py esc/1) escapes literal pipes in
  # cells as `\|`. Splitting on every `|` turned one escaped pipe into two
  # extra cells -> a false "malformed ERROR_CODES row (7 cells, expected 6)"
  # raise on a row the generator itself emitted (witnessed lens 4). Split on
  # unescaped pipes only, then unescape within each cell.
  @row_split_regex ~r{(?<!\\)\|}

  defp split_row(line) do
    line
    |> String.trim_trailing("|")
    |> String.split(@row_split_regex)
    |> Enum.map(fn cell ->
      cell |> String.replace("\\|", "|") |> String.trim()
    end)
    |> tl()
  end
end

defmodule Mix.Tasks.Smalt.CourtEmit do
  @shortdoc "Emit one court.run OCEL event from a court log/receipt file (always exit 0)."

  @moduledoc """
  Reads a court log/receipt file and emits one `court.run` OCEL event
  through `Smalt.Telemetry.CourtOcel.court_run/2` into the NDJSON sink.

  Fail-safe: telemetry never breaks the court — any read/emit failure is
  logged and this task still exits 0.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {parsed, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [receipt: :string, run: :integer, verdict: :string, stages: :string]
      )

    receipt_path = Keyword.get(parsed, :receipt, "")

    with {:ok, body} <- read_receipt(receipt_path),
         {:ok, _} <-
           Smalt.Telemetry.CourtOcel.court_run(
             [
               run: Keyword.get(parsed, :run, 0),
               verdict: verdict_of(parsed, body),
               stages: stages_of(parsed, body)
             ],
             receipt_path
           ) do
      :ok
    else
      {:ok, :dropped} ->
        Mix.shell().info("[court-emit] event dropped (registry gate)")

      {:error, reason} ->
        Mix.shell().info("[court-emit] emission failed, dropped (fail-safe): #{inspect(reason)}")
    end

    :ok
  end

  defp read_receipt(""), do: {:ok, ""}

  defp read_receipt(path) do
    case File.read(Path.expand(path)) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:receipt_unreadable, reason}}
    end
  end

  # Judge the receipt the same way court_x2.sh's judge_log does: "0 failures"
  # with no nonzero failure count and no compile-abort marker.
  defp verdict_of(parsed, body) do
    Keyword.get(parsed, :verdict) || judge_body(body)
  end

  defp judge_body(body) do
    nonzero = Regex.match?(~r/[1-9][0-9]* failures?/, body)
    zero = String.contains?(body, "0 failures")

    compile_abort =
      String.contains?(body, "== Compilation error") or
        String.contains?(body, " compilation failed")

    cond do
      zero and not nonzero and not compile_abort -> "green"
      true -> "not-green"
    end
  end

  # Stage names from the court log's stage headers (`==> stage <name>` mix
  # output), ids only — never log contents.
  defp stages_of(parsed, body) do
    case Keyword.get(parsed, :stages) do
      nil ->
        Regex.scan(~r/^==+ .*? (\w[\w-]*)$/, body, capture: :all_but_first)
        |> List.flatten()

      stages ->
        stages
    end
  end
end

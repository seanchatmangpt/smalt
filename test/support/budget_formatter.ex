defmodule SmaltTest.BudgetFormatter do
  @moduledoc """
  Per-test timing exporter for the test-budget gate
  (docs/jira/v26.10.18/rewrite-drafts/budget-gate.md). Exports one TSV line
  per finished test to
  $SMALT_BUDGET_EXPORT (default tmp/test-budget-export.tsv):

      file:line\\tduration_ms\\tCase.name

  Durations come from ExUnit's own `time` field (microseconds) on the
  {:test_finished, %ExUnit.Test{}} event — no timing of our own. Lines are
  flushed per event; :suite_finished closes the file, so a crashed run
  yields a truncated (hence gate-failing) export, not a missing one.

  Usage:

      SMALT_BUDGET_EXPORT=tmp/x.tsv mix test --formatter SmaltTest.BudgetFormatter

  Per the draft's land-lane note, this is export-only (no CLIFormatter
  delegation — the delegation seam proved brittle across ExUnit versions,
  and the gate consumes the file, not the console).
  """

  use GenServer

  @impl true
  def init(config) do
    path = System.get_env("SMALT_BUDGET_EXPORT") || "tmp/test-budget-export.tsv"
    File.mkdir_p!(Path.dirname(path))
    io = File.open!(path, [:write, :utf8])
    {:ok, %{io: io, path: path}}
  end

  @impl true
  def handle_event({:test_finished, %ExUnit.Test{} = test}, _config, %{io: io} = state) do
    ms = div(test.time || 0, 100)
    tid = "#{test.case}.#{test.name}"

    line =
      case test.tags do
        %{file: f, line: l} -> "#{f}:#{l}"
        _ -> "unknown:0"
      end

    IO.write(io, "#{line}\t#{ms}\t#{tid}\n")
    {:noreply, state}
  end

  @impl true
  def handle_event({:suite_finished, _, _}, _config, %{io: io, path: path} = state) do
    File.close(io)
    IO.puts("== budget export written: #{path}")
    {:noreply, state}
  end

  @impl true
  def handle_event(_event, _config, state), do: {:noreply, state}
end

defmodule SmaltTest.BudgetFormatter do
  @moduledoc """
  Per-test timing exporter for the test-budget gate
  (docs/jira/v26.10.18/rewrite-drafts/budget-gate.md).

  ExUnit formatters are GenServers that receive events via handle_cast in
  the shape {event_name, payload} (see ExUnit.CLIFormatter). This formatter
  tees {:test_finished, %ExUnit.Test{}} events to a TSV export:

      file:line\tduration_ms\tCase.test_name

  Durations come from ExUnit's own `time` field (microseconds) — no timing
  of our own. Written per-event, synchronously, so a crashed run yields a
  truncated (hence gate-failing) export, not a missing one. Export-only
  (no console formatter), per the draft's land-lane note.
  """

  use GenServer

  def init(config) do
    path = System.get_env("SMALT_BUDGET_EXPORT") || "tmp/test-budget-export.tsv"
    File.mkdir_p!(Path.dirname(path))
    io = File.open!(path, [:write, :utf8])
    {:ok, %{io: io, path: path}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, st) do
    ms = div(test.time || 0, 1000)
    tid = "#{test.case}.#{test.name}"

    loc =
      case test.tags do
        %{file: f, line: l} -> "#{f}:#{l}"
        _ -> "unknown:0"
      end

    IO.write(st.io, "#{loc}\t#{ms}\t#{tid}\n")
    {:noreply, st}
  end

  def handle_cast({:suite_finished, _times}, st) do
    File.close(st.io)
    IO.puts("== budget export written: #{st.path}")
    {:noreply, st}
  end

  def handle_cast(_event, st), do: {:noreply, st}
end

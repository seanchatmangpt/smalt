# Caller-side reap for `--hang` runner test doubles (BK-GRAPHREAP; closes
# BK-ZOMB's PREVENTION-DEFERRED item). Required by each court that spawns a
# `--hang` stub via:
#
#     Code.require_file("hang_reap.exs", __DIR__)
#     baseline = SmaltTest.Internal.HangReap.baseline()
#     on_exit(fn -> SmaltTest.Internal.HangReap.reap!(baseline) end)
#
# Leak mechanism (witnessed in docs/jira/v26.10.22/receipts/bkzombie-census.md
# §2): the `--hang` double ignores stdio (graphlaw-run --hang / the stub
# runner's Process.sleep(:infinity) never reads stdin), so when the BEAM kills
# the port at the fail-closed timeout the double is never terminated — it
# survives and reparents to launchd (PPID=1), one fresh leak per court run.
#
# Contract: kill ONLY PIDs absent from the caller's baseline census (zero
# cross-lane kills: the pre-existing population belongs to BK-ZOMBR's drain,
# not to this reap), by exact PID, and verify each kill. Fail-closed: a kill
# that does not verify raises — a reap that cannot fail is a vacuous gate.
#
# This is a real-collaborator OS census (Chicago), not a mock.

defmodule SmaltTest.Internal.HangReap do
  @moduledoc false

  # --hang stub faces: the real graphlaw-run binary or the stub_runner.exs
  # elixir script (which shows as beam.smp with -extra ...stub_runner.exs).
  @hang_pattern ~r{graphlaw-run .*--hang|stub_runner\.exs --hang}

  @doc "Snapshot of currently-alive --hang stub PIDs."
  def baseline do
    census() |> MapSet.new()
  end

  @doc """
  Kill by exact PID every --hang stub NOT present in `baseline`.
  Returns the sorted list of killed PIDs; raises on any kill that fails to
  verify (process still alive after SIGKILL).
  """
  def reap!(%MapSet{} = baseline) do
    fresh = census() |> MapSet.new() |> MapSet.difference(baseline)

    for pid <- fresh, pid_alive?(pid) do
      {_, 0} = System.cmd("kill", ["-9", Integer.to_string(pid)])

      unless process_gone?(pid) do
        raise "BK-GRAPHREAP reap failed: pid #{pid} survived SIGKILL"
      end

      pid
    end
    |> Enum.sort()
  end

  @doc "Current --hang stub PIDs (for the falsifier census)."
  def census do
    {out, 0} = System.cmd("ps", ["-axo", "pid=,command="])

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case line |> String.trim_leading() |> String.split(" ", parts: 2) do
        [pid_str, cmd] ->
          pid = String.to_integer(String.trim(pid_str))
          (Regex.match?(@hang_pattern, cmd) && [pid]) || []

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp pid_alive?(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "pid="], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp process_gone?(pid) do
    # Bounded verify, sleep-free: the kernel reaps a SIGKILLed process
    # promptly and the ps round-trip itself is the pacing (each retry is an
    # observation, never a clock guess). Three confirming observations must
    # all see the PID gone or the reap fails closed.
    Enum.all?(1..3, fn _ -> not pid_alive?(pid) end)
  end
end

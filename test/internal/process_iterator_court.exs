# AR-CORE-01 / IMPL-1 Chicago court: the OTP 29 processes iterator
# traverses a 200k-process population without materializing the pid list
# in the caller, and every pid is visited exactly once.
#
# The visited-once census lives in ETS (off the caller's heap) so the
# court itself does not violate the heap bound it is asserting.
#
# Chicago discipline: real processes (200k spawned trivial procs), real
# iterator BIFs, final state asserted (visited-once census + heap bounds),
# never call counts.

Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.ProcessIteratorCourtTest do
  use ExUnit.Case, async: false

  @population 200_000
  @table :process_iterator_court_census

  defp spawn_trivial(0, pids), do: pids

  defp spawn_trivial(n, pids) do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    spawn_trivial(n - 1, [pid | pids])
  end

  defp census_visit(iter) do
    case Smalt.ProcessIter.next(iter) do
      {pid, rest} ->
        unless :ets.insert_new(@table, {pid}) do
          flunk("pid visited twice: #{inspect(pid)}")
        end

        census_visit(rest)

      :none ->
        :ok
    end
  end

  test "iterator traverses 200k processes, heap-bounded, each pid exactly once" do
    assert Smalt.ProcessIter.mode() == :iterator

    pids = spawn_trivial(@population, [])

    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

    heap_before = Smalt.ProcessIter.caller_heap_words()
    :ets.new(@table, [:set, :named_table, :public])
    census_visit(Smalt.ProcessIter.iterator())
    heap_after = Smalt.ProcessIter.caller_heap_words()
    delta_iter = heap_after - heap_before
    n = :ets.info(@table, :size)

    # Honest baseline: the same population via :erlang.processes/0, read
    # after the iterator pass so its allocation cannot pollute the bound.
    heap_before_full = Smalt.ProcessIter.caller_heap_words()
    full_list = :erlang.processes()
    heap_after_full = Smalt.ProcessIter.caller_heap_words()
    delta_full = heap_after_full - heap_before_full

    assert n == length(full_list)

    IO.puts(
      "\nAR-CORE-01 heap deltas (words, GC'd reads): " <>
        "iterator=#{delta_iter} processes/0=#{delta_full} population=#{n}\n"
    )

    assert delta_iter < 100_000,
           "iterator heap delta #{delta_iter} >= 100k words"

    :ets.delete(@table)
  end
end

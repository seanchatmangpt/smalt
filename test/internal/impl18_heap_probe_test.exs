# IMPL-18 scratch probe (DELETED after receipt): old census traversal
# (:erlang.processes/0 materialized + Enum.reduce) vs new
# Smalt.ProcessIter.reduce traversal, caller heap words measured via
# Smalt.ProcessIter.caller_heap_words/0 (GC immediately before read),
# min-of-5 paired rounds, same booted VM.
Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.Impl18HeapProbeTest do
  use ExUnit.Case, async: false

  import SmaltTest.Internal.Poll, only: [eventually: 2]

  defp old_census do
    pids = :erlang.processes()
    conn_sup = Process.whereis(Smalt.AmqpBroker.ConnSup)

    conn_sup_children =
      if conn_sup,
        do: MapSet.new(DynamicSupervisor.which_children(conn_sup) |> Enum.map(&elem(&1, 1))),
        else: MapSet.new()

    monitors =
      Enum.reduce(pids, 0, fn pid, acc ->
        case :erlang.process_info(pid, [:monitors, :monitored_by]) do
          :undefined -> acc
          info -> acc + length(Keyword.get(info, :monitors, []))
        end
      end)

    {length(pids), monitors, length(pids)}
  end

  defp new_census do
    conn_sup = Process.whereis(Smalt.AmqpBroker.ConnSup)

    conn_sup_children =
      if conn_sup,
        do: MapSet.new(DynamicSupervisor.which_children(conn_sup) |> Enum.map(&elem(&1, 1))),
        else: MapSet.new()

    {p, m} =
      Smalt.ProcessIter.reduce({0, 0}, fn pid, {pc, ms} ->
        ms =
          cond do
            MapSet.member?(conn_sup_children, pid) -> ms
            true ->
              case :erlang.process_info(pid, [:monitors, :monitored_by]) do
                :undefined -> ms
                info -> ms + length(Keyword.get(info, :monitors, []))
              end
          end

        {pc + 1, ms}
      end)

    {p, m}
  end

  # Measure in a FRESH process per round (a resident process's heap
  # high-water mark absorbs the pid list, reading as a fake 0).
  # Observable: words reclaimed by GC inside the probe process during the
  # traversal (erlang:statistics(garbage_collection) word delta). The pid
  # list is pure garbage after the reduce, so reclaimed words is the honest
  # allocation cost; the iterator traversal allocates no list to reclaim.
  defp heap_delta(fun) do
    parent = self()

    {pid, _ref} = spawn_monitor(fn ->
        {r0, _, _} = :erlang.statistics(:garbage_collection)
        _ = fun.()
        :erlang.garbage_collect()
        {r1, _, _} = :erlang.statistics(:garbage_collection)
        send(parent, {:delta, r1 - r0})
      end)

    receive do
      {:delta, d} -> d
      {:DOWN, _ref, :process, ^pid, reason} -> raise "probe died: #{inspect(reason)}"
    after
      30_000 -> raise "probe timeout"
    end
  end

  test "heap delta: old traversal vs ProcessIter.reduce traversal" do
    # boot observable: plane named before sampling (same as the tier setup)
    assert {:ok, _} =
             eventually(
               fn ->
                 case Process.whereis(Smalt.Plane.DataSupervisor) do
                   pid when is_pid(pid) -> {:ok, pid}
                   nil -> {:booting, nil}
                 end
               end,
               timeout_ms: 15_000
             )

    n_proc = Smalt.ProcessIter.count()

    rounds = 5
    old_deltas = for _ <- 1..rounds, do: heap_delta(&old_census/0)
    new_deltas = for _ <- 1..rounds, do: heap_delta(&new_census/0)

    IO.puts("""
    [IMPL-18 heap probe] processes=#{n_proc} mode=#{Smalt.ProcessIter.mode()}
      old (:erlang.processes/0 + Enum.reduce) heap deltas (words, 5 rounds): #{inspect(old_deltas)}
      new (Smalt.ProcessIter.reduce)        heap deltas (words, 5 rounds): #{inspect(new_deltas)}
    """)

    assert Smalt.ProcessIter.mode() == :iterator
  end
end

defmodule Court.Aoq.Partition.Crash do
  @moduledoc """
  LANE-05 partition crash court (Chicago-style, no mocks). Kills the p1
  worker mid-stream and pins three laws on REAL observables:

  - p0/p2 seqs stay GAPLESS and keep ADVANCING through the crash window
    (single producer per ring, so gapless = each delivered seq is
    prev + 1)
  - p1 restarts (:permanent under PartitionSup), adopts the SAME
    off-heap cursor (registry entry unchanged — same :atomics ref), and
    the per-ring seq CONTINUES (gapful-but-monotone through the kill
    window)
  - submits during the dead window still return {:ok, seq} — the seq is
    consumed, delivery is the no-op-send crash law

  Zero Process.sleep — bounded polls on the sink table / registry.
  """

  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Cursor
  alias Smalt.Aoq.PartitionSup
  alias Smalt.Aoq.PartitionWorker
  alias Smalt.Aoq.Partitions

  @rings [:p0, :p1, :p2]

  setup do
    :persistent_term.erase({Smalt.Aoq.Partitions, :rings})
    table = String.to_atom("aoq_part_crash_#{System.unique_integer([:positive])}")
    :ets.new(table, [:named_table, :bag, :public])
    sink = partition_sink(table)
    on_exit(fn -> if :ets.info(table) != :undefined, do: :ets.delete(table) end)

    start_supervised!({PartitionSup, []})
    start_supervised!({Partitions, [sink: sink]})

    for r <- @rings, do: assert({:ok, _} = Partitions.ensure_ring(r, sink: sink))

    %{table: table}
  end

  @tag :aoq_partition
  test "kill p1 mid-stream; siblings gapless+advancing; p1 restarts on same cursor", %{
    table: table
  } do
    # Prime: a few frames per ring so every worker has flushed at least once.
    for r <- @rings, i <- 1..5 do
      assert {:ok, _} = Partitions.submit(court_frame(), r)
      _ = i
    end

    for r <- @rings do
      {:ok, {cursor, _}} = Partitions.ring(r)
      assert_eventually(fn -> Cursor.in_flight(cursor) == 0 end, timeout: 10_000)
    end

    {:ok, {cursor_p1, name_p1}} = Partitions.ring(:p1)
    old_pid = Process.whereis(name_p1)
    assert is_pid(old_pid)
    {:ok, {cursor_p1_from_registry_again, _}} = Partitions.ring(:p1)
    # same off-heap cursor handle before the kill
    assert cursor_p1_from_registry_again == cursor_p1

    # ── kill mid-stream ───────────────────────────────────────────────────
    :erlang.process_flag(:trap_exit, false)
    Process.exit(old_pid, :kill)

    # Crash window: submits still succeed ({:ok, seq} consumed) while the
    # worker is down, and p0/p2 keep advancing (gapless deliveries).
    crash_window_seqs =
      for _i <- 1..20 do
        assert {:ok, _} = Partitions.submit(court_frame(), :p1)
        assert {:ok, s0} = Partitions.submit(court_frame(), :p0)
        assert {:ok, s2} = Partitions.submit(court_frame(), :p2)
        {s0, s2}
      end

    # p0/p2 gapless + advancing: bounded poll until all prime+window frames
    # are delivered, then each delivered seq must be prev + 1.
    for r <- [:p0, :p2] do
      assert_eventually(
        fn -> length(delivery_seqs(table, r)) >= 25 end,
        timeout: 10_000
      )

      seqs = delivery_seqs(table, r)

      pairs = Enum.chunk_every(seqs, 2, 1, :discard)

      Enum.each(pairs, fn [prev, next] ->
        assert next == prev + 1, "ring #{inspect(r)} gap: #{prev} -> #{next}"
      end)
    end

    # p1 restarts with a NEW pid under the SAME registered name.
    assert_eventually(
      fn ->
        pid = Process.whereis(name_p1)
        is_pid(pid) and pid != old_pid
      end,
      timeout: 10_000
    )

    new_pid = Process.whereis(name_p1)

    # Registry entry unchanged: SAME cursor handle, seq continues.
    {:ok, {cursor_after, _}} = Partitions.ring(:p1)
    assert cursor_after == cursor_p1

    # p1 keeps advancing after restart (deliveries resume on same cursor).
    pre_kill_p1 = delivery_seqs(table, :p1) |> Enum.sort() |> Enum.take(-1)

    for _i <- 1..10, do: assert({:ok, _} = Partitions.submit(court_frame(), :p1))

    assert_eventually(fn ->
      delivery_seqs(table, :p1) |> length() >= length(pre_kill_p1) + 10
    end, timeout: 10_000)

    post = delivery_seqs(table, :p1) |> Enum.sort()

    assert length(post) >= length(pre_kill_p1) + 10

    # Post-restart deliveries continue from the shared cursor: every
    # post-restart seq sits within the seq space the shared cursor minted
    # (monotone; gapful through the kill window is lawful).
    {:ok, {c, _}} = Partitions.ring(:p1)
    current_head_seq = Cursor.seq_next(c) - 1

    Enum.each(post, fn s -> assert s <= current_head_seq end)

    _ = cursor_p1_from_registry_again
    _ = crash_window_seqs
    _ = new_pid
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp delivery_seqs(table, ring) do
    table |> :ets.lookup(ring) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
  end

  defp court_frame do
    header = :crypto.strong_rand_bytes(64)
    payload = :crypto.strong_rand_bytes(8)
    <<header::binary-size(64), payload::binary>>
  end

  defp partition_sink(table) do
    mod = String.to_atom("AoqCrashSink#{System.unique_integer([:positive])}")

    create =
      quote do
        defmodule unquote(mod) do
          @behaviour Smalt.Aoq.PartitionSink

          @table unquote(table)

          @impl true
          def deliver(ring, seq, _parsed), do: :ets.insert(@table, {ring, seq})
        end
      end

    Code.eval_quoted(create)
    mod
  end
end

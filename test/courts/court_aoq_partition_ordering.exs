defmodule Court.Aoq.Partition.Ordering do
  @moduledoc """
  LANE-05 ordering court (Chicago-style: real workers, real submits, no
  mocks). 4 producers × 2000 frames × 4 partitions, interleaved. The
  oracle is `Smalt.Aoq.Cursor.seq_before?/2` (never `a < b`): for every
  producer, its per-partition seq subsequence must be strictly
  increasing in submission order. Cross-partition ordering is
  unconstrained (nothing asserted). Zero Process.sleep — bounded polls
  on real observables.
  """

  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias Smalt.Aoq.Cursor
  alias Smalt.Aoq.PartitionSup
  alias Smalt.Aoq.Partitions

  @rings 4
  @producers 4
  @frames_per_producer 2000
  @total @producers * @frames_per_producer

  setup do
    :persistent_term.erase({Smalt.Aoq.Partitions, :rings})
    table = String.to_atom("aoq_part_ordering_#{System.unique_integer([:positive])}")
    :ets.new(table, [:named_table, :bag, :public])
    sink = partition_sink(table)
    on_exit(fn -> if :ets.info(table) != :undefined, do: :ets.delete(table) end)

    start_supervised!({PartitionSup, []})
    start_supervised!({Partitions, [sink: sink]})

    for r <- 0..(@rings - 1), do: assert({:ok, _} = Partitions.ensure_ring(r, sink: sink))

    %{table: table}
  end

  @tag :aoq_partition
  test "per-producer per-partition seqs strictly increase in submission order", %{table: table} do
    producer_pid = self()

    producers =
      for p <- 1..@producers do
        spawn_link(fn ->
          per_partition =
            for frame_idx <- 0..(@frames_per_producer - 1) do
              ring = rem(frame_idx, @rings)
              frame = court_frame()
              {:ok, seq} = Partitions.submit(frame, ring)
              {ring, seq}
            end

          send(producer_pid, {:done, p, per_partition})
        end)
      end

    results =
      for _ <- 1..@producers do
        receive do
          {:done, _p, per_partition} -> per_partition
        end
      end

    # Drain: every submitted frame is delivered by its worker (bounded poll
    # on the real sink table, never a sleep).
    for ring <- 0..(@rings - 1) do
      {:ok, {cursor, _name}} = Partitions.ring(ring)
      assert_eventually(fn -> Cursor.in_flight(cursor) == 0 end, timeout: 30_000, interval: 20)
    end

    # Real observable: the sink delivered every submitted frame exactly once.
    deliveries = for ring <- 0..(@rings - 1), do: delivery_seqs(table, ring)

    assert Enum.sum(Enum.map(deliveries, &length/1)) == @total

    # Oracle: per producer, per partition, strictly increasing seqs.
    for {per_partition, p} <- Enum.with_index(results, 1) do
      by_ring = Enum.group_by(per_partition, &elem(&1, 0), &elem(&1, 1))

      assert map_size(by_ring) == @rings

      for {ring, seqs} <- by_ring do
        assert length(seqs) == div(@frames_per_producer, @rings)
        pairs = Enum.chunk_every(seqs, 2, 1, :discard)

        Enum.each(pairs, fn [prev, next] ->
          assert Cursor.seq_before?(prev, next),
                 "producer #{p} ring #{ring}: #{prev} not before #{next}"
        end)

        # Per-ring seqs are unique (one atomic counter per ring).
        assert length(Enum.uniq(seqs)) == length(seqs)
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp delivery_seqs(table, ring) do
    table
    |> :ets.lookup(ring)
    |> Enum.map(&elem(&1, 1))
  end

  defp court_frame do
    header = :crypto.strong_rand_bytes(64)
    payload = :crypto.strong_rand_bytes(16)
    <<header::binary-size(64), payload::binary>>
  end

  defp partition_sink(table) do
    mod = String.to_atom("AoqCourtSink#{System.unique_integer([:positive])}")

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

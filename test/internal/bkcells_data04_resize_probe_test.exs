defmodule Smalt.Internal.BkcellsData04ResizeProbeTest do
  # BK-CELLS — AR-DATA-04 re-witness at HEAD: PartitionSupervisor.resize!/2
  # semantics probe on a real PartitionSupervisor (Elixir 1.20.4), no mocks.
  # Re-witnesses the cell's evidence: resize works within [0, configured];
  # resize beyond the configured bound is refused; returns the PREVIOUS count,
  # not :ok. Children are unnamed DynamicSupervisors (the child_spec template
  # has no :name — Registry children demand a fixed :name, which
  # PartitionSupervisor does not rewrite per partition, so a named Registry
  # template collides at partition 1; typed in the receipt as a probe note).
  use ExUnit.Case, async: false

  @tag :bkcells
  test "resize within bound: 4->2->4, previous count returned; beyond bound refused" do
    {:ok, _sup} =
      PartitionSupervisor.start_link(
        child_spec: {DynamicSupervisor, strategy: :one_for_one},
        name: __MODULE__.PSup,
        partitions: 4,
        max_partitions: 4
      )

    prev2 = PartitionSupervisor.resize!(__MODULE__.PSup, 2)
    assert prev2 == 4, "resize!/2 must return the previous count, got #{inspect(prev2)}"
    assert PartitionSupervisor.partitions(__MODULE__.PSup) == 2

    prev4 = PartitionSupervisor.resize!(__MODULE__.PSup, 4)
    assert prev4 == 2
    assert PartitionSupervisor.partitions(__MODULE__.PSup) == 4

    assert_raise ArgumentError, ~r/between 0 and 4, got: 8/, fn ->
      resize_beyond(__MODULE__.PSup)
    end

    assert PartitionSupervisor.partitions(__MODULE__.PSup) == 4

    IO.puts(
      "[BKCELLS DATA-04] 4->2->4 ok; resize returned prev count (4, then 2); " <>
        "resize to 8 raised with the max_partitions bound message; state preserved at 4"
    )
  end

  defp resize_beyond(sup) do
    PartitionSupervisor.resize!(sup, 8)
  end
end

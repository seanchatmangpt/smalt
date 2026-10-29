defmodule Smalt.Powl2.DecompositionTest do
  use ExUnit.Case, async: true

  alias Smalt.PetriNet
  alias Smalt.Powl2.Decomposition

  # Hand-constructed free-choice WF-nets (Chicago: real structs, real
  # algorithm runs, assertions on the returned partitions).

  # Sequence: src -> a -> p1 -> b -> snk
  defp sequence_net do
    PetriNet.new(
      arcs: [
        {:place, :src, :a},
        {:transition, :a, :p1},
        {:place, :p1, :b},
        {:transition, :b, :snk}
      ],
      source: :src,
      sink: :snk
    )
  end

  # Exclusive choice: XOR-split place :src branches to a / b, XOR-join
  # place :snk.
  defp choice_net do
    PetriNet.new(
      arcs: [
        {:place, :src, :a},
        {:place, :src, :b},
        {:transition, :a, :snk},
        {:transition, :b, :snk}
      ],
      source: :src,
      sink: :snk
    )
  end

  # Parallel diamond (free-choice AND): split -> p1 -> a -> pj; split
  # -> p2 -> b -> pj; pj -> join. The AND-join is place :pj (two input
  # transitions), consumed by the join transition.
  defp parallel_net do
    PetriNet.new(
      arcs: [
        {:place, :src, :split},
        {:transition, :split, :p1},
        {:transition, :split, :p2},
        {:place, :p1, :a},
        {:place, :p2, :b},
        {:transition, :a, :pj},
        {:transition, :b, :pj},
        {:place, :pj, :join},
        {:transition, :join, :snk}
      ],
      source: :src,
      sink: :snk
    )
  end

  # Net with both constructs: XOR choice {xa, xb} at :src, then a
  # parallel diamond split -> (pa | pb) -> pj -> join -> snk.
  defp both_net do
    PetriNet.new(
      arcs: [
        {:place, :src, :xa},
        {:place, :src, :xb},
        {:transition, :xa, :m},
        {:transition, :xb, :m},
        {:place, :m, :split},
        {:transition, :split, :p1},
        {:transition, :split, :p2},
        {:place, :p1, :pa},
        {:place, :p2, :pb},
        {:transition, :pa, :pj},
        {:transition, :pb, :pj},
        {:place, :pj, :join},
        {:transition, :join, :snk}
      ],
      source: :src,
      sink: :snk
    )
  end

  defp groups_of({:ok, groups}), do: groups

  defp group_of(groups, size) do
    Enum.find(groups, &(MapSet.size(&1) == size))
  end

  describe "partition_mg/1 (Algorithm 1, conflict-hiding)" do
    test "groups the exclusive-choice pair into one module" do
      assert choice_net() |> Decomposition.partition_mg() |> groups_of() == [
               MapSet.new([:a, :b])
             ]
    end

    test "sequence net yields singleton groups (nothing to hide)" do
      groups = sequence_net() |> Decomposition.partition_mg() |> groups_of()
      assert groups == [MapSet.new([:a]), MapSet.new([:b])]
    end

    test "parallel net has no conflicts: four singleton groups" do
      groups = parallel_net() |> Decomposition.partition_mg() |> groups_of()
      assert length(groups) == 4
      assert Enum.all?(groups, &(MapSet.size(&1) == 1))
      assert Enum.reduce(groups, MapSet.new(), &MapSet.union/2) |> MapSet.equal?(MapSet.new([:split, :a, :b, :join]))
    end

    test "both net: only the choice pair merges" do
      groups = both_net() |> Decomposition.partition_mg() |> groups_of()
      assert length(groups) == 5
      assert MapSet.equal?(group_of(groups, 2), MapSet.new([:xa, :xb]))
    end

    test "refuses a non-well-formed net (unreachable transition b)" do
      broken =
        PetriNet.new(
          arcs: [{:place, :src, :a}, {:transition, :a, :snk}, {:transition, :b, :snk}],
          source: :src,
          sink: :snk
        )

      assert {:error, :not_well_formed} = Decomposition.partition_mg(broken)
    end
  end

  describe "partition_sm/1 (Algorithm 2, concurrency-hiding)" do
    test "groups the whole parallel diamond into one module" do
      groups = parallel_net() |> Decomposition.partition_sm() |> groups_of()
      assert groups == [MapSet.new([:a, :b, :join, :split])]
    end

    test "sequence net yields singleton groups" do
      groups = sequence_net() |> Decomposition.partition_sm() |> groups_of()
      assert groups == [MapSet.new([:a]), MapSet.new([:b])]
    end

    test "choice net yields singleton groups (no concurrency to hide)" do
      groups = choice_net() |> Decomposition.partition_sm() |> groups_of()
      assert length(groups) == 2
      assert Enum.all?(groups, &(MapSet.size(&1) == 1))
    end

    test "both net: diamond merges, choice pair does not" do
      groups = both_net() |> Decomposition.partition_sm() |> groups_of()
      assert length(groups) == 3
      assert MapSet.equal?(group_of(groups, 4), MapSet.new([:split, :pa, :pb, :join]))
    end

    test "refuses a non-well-formed net" do
      broken =
        PetriNet.new(
          arcs: [{:place, :src, :a}, {:transition, :a, :snk}, {:transition, :b, :snk}],
          source: :src,
          sink: :snk
        )

      assert {:error, :not_well_formed} = Decomposition.partition_sm(broken)
    end
  end

  describe "validators (Defs 4.1 / 4.4, entry/exit place equivalence)" do
    test "partition_mg result is conflict-hiding on every net" do
      for net <- [sequence_net(), choice_net(), parallel_net(), both_net()] do
        assert Decomposition.conflict_hiding?(net, Decomposition.partition_mg(net))
      end
    end

    test "partition_sm result is concurrency-hiding on every net" do
      for net <- [sequence_net(), choice_net(), parallel_net(), both_net()] do
        assert Decomposition.concurrency_hiding?(net, Decomposition.partition_sm(net))
      end
    end

    test "conflict_hiding? is false when a conflict pair crosses groups" do
      net = choice_net()
      refute Decomposition.conflict_hiding?(net, [MapSet.new([:a]), MapSet.new([:b])])
    end

    test "concurrency_hiding? is false when a concurrent pair crosses groups" do
      net = parallel_net()

      groups = [MapSet.new([:split]), MapSet.new([:a]), MapSet.new([:b]), MapSet.new([:join])]

      refute Decomposition.concurrency_hiding?(net, groups)
    end

    test "a group with two exit places is not a block" do
      net = parallel_net()
      refute Decomposition.block_group?(net, MapSet.new([:split]))
    end

    test "a sequential group is a block" do
      net = sequence_net()
      assert Decomposition.block_group?(net, MapSet.new([:a, :b]))
    end

    test "conflict_hiding? rejects a partition whose group breaks block structure" do
      net = both_net()
      # {xa, xb, split} merges the choice with the split: still covers
      # all conflict pairs but the induced subnet has two entries.
      refute Decomposition.conflict_hiding?(net, [
               MapSet.new([:xa, :xb, :split]),
               MapSet.new([:split]),
               MapSet.new([:pa]),
               MapSet.new([:pb]),
               MapSet.new([:join])
             ])
    end

    test "validators accept the {:ok, partition} shape" do
      assert Decomposition.conflict_hiding?(choice_net(), Decomposition.partition_mg(choice_net()))
      assert Decomposition.concurrency_hiding?(parallel_net(), Decomposition.partition_sm(parallel_net()))
    end
  end

  describe "relations" do
    test "conflict_pairs finds only the choice pair in the both net" do
      assert Decomposition.conflict_pairs(both_net()) == MapSet.new([{:xa, :xb}, {:xb, :xa}])
    end

    test "concurrent_pairs finds the diamond branches, not the choice pair" do
      pairs = Decomposition.concurrent_pairs(both_net())
      assert MapSet.member?(pairs, {:pa, :pb})
      assert MapSet.member?(pairs, {:pb, :pa})
      refute MapSet.member?(pairs, {:xa, :xb})
      refute MapSet.member?(pairs, {:xa, :pa})
    end
  end
end

# IMPL-7 / AR-POWL-03: GraphCompat fallback-seam court.
#
# Cross-engine equivalence over a real corpus: native OTP 29 :graph vs
# pure-Elixir seen-set DFS. On an OTP 28 host the native leg returns
# {:error, :native_graph_unavailable} and the court pins engine() ==
# :elixir loudly; on OTP 29 the legs must agree cell by cell.
#
# Chicago: real collaborators - real edge lists, real compiler pass
# (Compiler.compile/2 through the build_partial_order seam). No mocks,
# no sleeps.

defmodule Powl2GraphCompatCourt do
  use ExUnit.Case, async: true

  alias Smalt.PetriNet
  alias Smalt.Powl2.Compiler
  alias Smalt.Powl2.Decomposition
  alias Smalt.Powl2.GraphCompat

  @cyclic [{:a, :b}, {:b, :c}, {:c, :a}]

  defp corpus do
    [
      {:empty, []},
      {:single_edge, [{:a, :b}]},
      {:diamond_dag, [{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}]},
      {:three_cycle, @cyclic},
      {:two_cycle, [{:c, :d}, {:d, :c}]},
      {:self_loop, [{:x, :x}]},
      {:dag_plus_unreachable_cycle, [{:a, :b}, {:x, :y}, {:y, :x}]},
      {:dag_with_shared_leaf, [{:a, :c}, {:b, :c}, {:c, :d}]},
      {:wide_fan, for(i <- 1..50, do: {i, :sink})},
      {:wide_fan_cycle, for(i <- 1..50, do: {i, rem(i, 49) + 1})}
    ]
  end

  defp expected do
    %{
      empty: true,
      single_edge: true,
      diamond_dag: true,
      three_cycle: false,
      two_cycle: false,
      self_loop: false,
      dag_plus_unreachable_cycle: false,
      dag_with_shared_leaf: true,
      wide_fan: true,
      wide_fan_cycle: false
    }
  end

  test "engine/0 matches the host OTP release honestly" do
    otp = :erlang.list_to_integer(:erlang.system_info(:otp_release))
    expected = if otp >= 29, do: :native, else: :elixir
    assert GraphCompat.engine() == expected
  end

  test "live engine enforces the acyclic law across the corpus" do
    want = expected()

    for {name, edges} <- corpus() do
      assert GraphCompat.acyclic?(edges) == want[name],
             "engine #{inspect(GraphCompat.engine())} disagrees on #{name}"
    end
  end

  test "native and fallback legs agree cell-by-cell on the corpus" do
    for {name, edges} <- corpus() do
      elixir = GraphCompat.elixir_acyclic?(edges)
      native = GraphCompat.native_acyclic?(edges)

      case native do
        {:error, :native_graph_unavailable} ->
          # OTP 28 host: the engine pin above already asserted
          # engine() == :elixir, so the fallback result IS the court
          # result here. Loud, never a silent cross-engine claim.
          :ok

        result ->
          assert elixir == result, "engines disagree on #{name}"
      end
    end
  end

  test "compiler diamond still compiles through the seam (non-regressing)" do
    assert {:ok, %Smalt.Powl2.PartialOrder{}} = Compiler.compile(diamond_net())
  end

  test "cyclic order is refused by BOTH engines (law parity)" do
    refute GraphCompat.native_acyclic?(@cyclic) == true
    refute GraphCompat.elixir_acyclic?(@cyclic) == true
  end

  # -- IMPL-15 decomposition leg -------------------------------------------------

  # src -> a1 -> p1 -> b1 -> p2 -> a2 -> snk with groups A={a1,a2},
  # B={b1}: the induced group-order graph is A->B (a1 through p1 into
  # b1) plus B->A (b1 through p2 into a2) - a real block-order cycle.
  defp cyclic_block_net do
    PetriNet.new(
      arcs: [
        {:place, :src, :a1},
        {:transition, :a1, :p1},
        {:place, :p1, :b1},
        {:transition, :b1, :p2},
        {:place, :p2, :a2},
        {:transition, :a2, :snk}
      ],
      source: :src,
      sink: :snk
    )
  end

  @cyclic_groups [MapSet.new([:a1, :a2]), MapSet.new([:b1])]
  @acyclic_groups [MapSet.new([:a1]), MapSet.new([:b1]), MapSet.new([:a2])]

  test "decomposition: cyclic block order is refused by BOTH engines" do
    edges = Decomposition.block_order_edges(cyclic_block_net(), @cyclic_groups)
    assert Enum.sort(edges) == [{0, 1}, {1, 0}]

    refute GraphCompat.native_acyclic?(edges) == true
    refute GraphCompat.elixir_acyclic?(edges) == true
    refute Decomposition.block_order_acyclic?(cyclic_block_net(), @cyclic_groups)

    assert catch_throw(Decomposition.block_cycle_check!(cyclic_block_net(), @cyclic_groups)) ==
             {:powl2_refusal, :block_order_cycle}
  end

  test "decomposition: acyclic block order passes and engines agree" do
    net = cyclic_block_net()
    edges = Decomposition.block_order_edges(net, @acyclic_groups)
    assert edges == [{0, 1}, {1, 2}]

    assert Decomposition.block_order_acyclic?(net, @acyclic_groups)
    assert GraphCompat.elixir_acyclic?(edges)

    case GraphCompat.native_acyclic?(edges) do
      {:error, :native_graph_unavailable} -> :ok
      result -> assert result == true
    end
  end

  test "decomposition: real partitions stay acyclic (non-regressing)" do
    # Same sequence net, partitioned by the real algorithm: singleton
    # groups in chain order - the machine check admits it.
    assert {:ok, groups} = Decomposition.partition_mg(cyclic_block_net())
    assert Decomposition.block_order_acyclic?(cyclic_block_net(), groups)
  end


  defp diamond_net do
    Smalt.Powl2.net(
      [:p0, :p1, :p2, :p3, :p4, :p5],
      [:s, :t1, :t2, :j],
      [
        {:p0, :s},
        {:s, :p1},
        {:s, :p2},
        {:p1, :t1},
        {:p2, :t2},
        {:t1, :p3},
        {:t2, :p4},
        {:p3, :j},
        {:p4, :j},
        {:j, :p5}
      ]
    )
  end
end

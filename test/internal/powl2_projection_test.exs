defmodule InternalTier.Powl2ProjectionTest do
  use ExUnit.Case, async: false

  alias Smalt.PetriNet
  alias Smalt.POWL2.Projection
  alias Smalt.POWL2.Reticle.AST

  defp net(arcs), do: PetriNet.new(arcs: arcs)

  # diamond: p_in -> a -> (p_mid1 -> b | p_mid2 -> c) -> p_out
  defp diamond do
    net([
      {:place, :p_in, :a},
      {:transition, :a, :p_mid1},
      {:transition, :a, :p_mid2},
      {:place, :p_mid1, :b},
      {:place, :p_mid2, :c},
      {:transition, :b, :p_out},
      {:transition, :c, :p_out}
    ])
  end

  defp arcs_of(proj), do: MapSet.new(proj.net.arcs)

  test "project_mg preserves task set and reroutes boundary flow" do
    proj = Projection.project_mg(diamond(), [:a, :b, :c], :ps_d, :pe_d)

    assert proj.net.transitions == MapSet.new([:a, :b, :c])
    assert MapSet.subset?(MapSet.new([:ps_d, :pe_d, :p_mid1, :p_mid2]), proj.net.places)

    arcs = arcs_of(proj)
    assert MapSet.member?(arcs, {:place, :ps_d, :a})
    assert MapSet.member?(arcs, {:transition, :b, :pe_d})
    assert MapSet.member?(arcs, {:transition, :c, :pe_d})
    # internal arcs of internal places preserved
    assert MapSet.member?(arcs, {:place, :p_mid1, :b})
    assert MapSet.member?(arcs, {:place, :p_mid2, :c})
    # boundary arcs rerouted away
    refute MapSet.member?(arcs, {:place, :p_in, :a})
    refute MapSet.member?(arcs, {:transition, :b, :p_out})

    assert proj.entries == [:a]
    assert MapSet.equal?(MapSet.new(proj.exits), MapSet.new([:b, :c]))
  end

  test "project_mg refuses identical delimiters" do
    assert_raise FunctionClauseError, fn ->
      Projection.project_mg(diamond(), [:a], :same, :same)
    end
  end

  test "project_sm admits single entry and exit" do
    chain =
      net([
        {:place, :p_in, :a},
        {:transition, :a, :p_m},
        {:place, :p_m, :b},
        {:transition, :b, :p_out}
      ])

    assert {:ok, proj} = Projection.project_sm(chain, [:a, :b], :ps_s, :pe_s)
    assert proj.entries == [:a]
    assert proj.exits == [:b]
    assert proj.id == {:sm, :ps_s, :pe_s}
  end

  test "project_sm refuses multi-entry boundary" do
    assert {:error, {:not_sese, {:exit_count, 2}}} =
             Projection.project_sm(diamond(), [:a, :b, :c], :ps_m, :pe_m)
  end

  test "normalize is identity when delimiters carry no arcs" do
    proj = Projection.project_mg(diamond(), [:a, :b, :c], :ps_n, :pe_n)
    assert Projection.normalize(proj.net, :ps_n, :pe_n) == proj.net
  end
  test "normalize inserts tau only when delimiters carry arcs" do
    proj = Projection.project_mg(diamond(), [:a, :b, :c], :ps_n, :pe_n)
    tau_s = {:tau, :source, :ps_n}
    tau_k = {:tau, :sink, :pe_n}

    with_stray =
      PetriNet.new(
        arcs: MapSet.to_list(arcs_of(proj)) ++ [{:place, :p_z, :ps_n}],
        places: [:p_z],
        transitions: [],
        source: :ps_n,
        sink: :pe_n
      )

    net2 = Projection.normalize(with_stray, :ps_n, :pe_n)
    arcs2 = MapSet.new(net2.arcs)

    refute MapSet.member?(arcs2, {:place, :p_z, :ps_n})
    assert MapSet.member?(arcs2, {:place, :p_z, tau_s})
    assert MapSet.member?(arcs2, {:place, tau_s, :ps_n})
    assert MapSet.member?(net2.transitions, tau_s)

    with_stray_out =
      PetriNet.new(
        arcs: MapSet.to_list(arcs_of(proj)) ++ [{:place, :pe_n, :p_y}],
        places: [:p_y],
        transitions: [],
        source: :ps_n,
        sink: :pe_n
      )

    net3 = Projection.normalize(with_stray_out, :ps_n, :pe_n)
    arcs3 = MapSet.new(net3.arcs)

    refute MapSet.member?(arcs3, {:place, :pe_n, :p_y})
    assert MapSet.member?(arcs3, {:place, :pe_n, tau_k})
    assert MapSet.member?(arcs3, {:place, tau_k, :p_y})
    assert MapSet.member?(net3.transitions, tau_k)
  end

  test "execution_order closes transitively over delimiter overlap" do
    children = [
      %{id: :c1, ps: :d0, pe: :d1},
      %{id: :c2, ps: :d1, pe: :d2},
      %{id: :c3, ps: :d2, pe: :d3}
    ]

    got = Projection.execution_order(children, [{:c3, :c1}])

    for pair <- [{:c1, :c2}, {:c2, :c3}, {:c1, :c3}, {:c3, :c1}, {:c3, :c2}] do
      assert MapSet.member?(got, pair)
    end
  end

  test "execution_flow maps gamma edges to delimiter pairs" do
    children = [
      %{id: :x, ps: :ps_x, pe: :pe_x},
      %{id: :y, ps: :ps_y, pe: :pe_y},
      %{id: :z, ps: :ps_z, pe: :pe_z}
    ]

    cg = %AST.ChoiceGraph{
      start: :x,
      end: :z,
      children: %{},
      edges: [{:x, :y}, {:y, :z}, {:x, :z}]
    }

    got = Projection.execution_flow(cg, children)

    assert got.edges == [{:pe_x, :ps_y}, {:pe_y, :ps_z}, {:pe_x, :ps_z}]
    assert got.start == :ps_x
    assert got.finish == :pe_z
  end
end

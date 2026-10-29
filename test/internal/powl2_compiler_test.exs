# POWL-4: Algorithm 3 compiler (lib/smalt/powl2.ex + lib/smalt/powl2/compiler.ex).
#
# Provenance (lib/ read fresh, clean-room):
#   - Smalt.Powl2.Compiler.compile/2 is pure: it takes a Smalt.Powl2.Net
#     (safe WF-net: atom node ids, {src, dst} arc tuples) and returns
#     {:ok, ast} or a typed refusal.
#   - Relations come from the real reachable marking set (BFS with a
#     :max_markings cap) — the real collaborator is the net itself; no
#     mocks, no stubs, no sleeps (Chicago discipline).
#
# Runs via: MIX_BUILD_ROOT=_build-powl4 mix test test/internal/powl2_compiler_test.exs

defmodule Powl2CompilerTest do
  use ExUnit.Case, async: true

  alias Smalt.Powl2
  alias Smalt.Powl2.{ChoiceGraph, Compiler, PartialOrder, Transition}

  # -- net builders (all shapes match Smalt.Powl2.Net) ----------------------------

  defp diamond do
    # p0 -> s -> (p1,p2) ; p1 -> t1 -> p3 ; p2 -> t2 -> p4 ; (p3,p4) -> j -> p5(sink)
    Powl2.net(
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

  defp choice_loop do
    # pin -> in -> p0 ; p0 -> a -> p1 ; p1 -> b -> p2(sink) ; p1 -> c -> p0
    # (a,c): both orders possible with flow paths both ways = loop pair.
    Powl2.net(
      [:pin, :p0, :p1, :p2],
      [:in, :a, :b, :c],
      [
        {:pin, :in},
        {:in, :p0},
        {:p0, :a},
        {:a, :p1},
        {:p1, :b},
        {:p1, :c},
        {:c, :p0},
        {:b, :p2}
      ]
    )
  end

  defp pt_handle do
    # PT-handle-style cross-cut: s -> {p1, p2}; x,z CHOICE on p1 (both
    # produce into the SHARED post-place p3); y CONCURRENT with both
    # (independent p2 branch); j joins {p3, p5}.
    # y || x, y || z, x # z — concurrency and choice cut across each
    # other: neither a PartialOrder nor a ChoiceGraph can express it.
    # (BK-POWLH2: the previous drawing routed x->p3, z->p4 with a
    # three-input join {p3,p4,p5} — unsound: only one of p3/p4 is ever
    # marked, j could never fire, the sink was unreachable, and the
    # soundness gate now refuses such nets before the fallthrough.)
    Powl2.net(
      [:p0, :p1, :p2, :p3, :p5, :p6],
      [:s, :x, :z, :y, :j],
      [
        {:p0, :s},
        {:s, :p1},
        {:s, :p2},
        {:p1, :x},
        {:p1, :z},
        {:x, :p3},
        {:z, :p3},
        {:p2, :y},
        {:y, :p5},
        {:p3, :j},
        {:p5, :j},
        {:j, :p6}
      ]
    )
  end

  # -- tests ----------------------------------------------------------------------

  test "single-transition net compiles to a leaf Transition" do
    net = Powl2.net([:p0, :p1], [:only], [{:p0, :only}, {:only, :p1}])
    assert {:ok, %Transition{label: :only}} = Compiler.compile(net)
  end

  test "concurrent diamond compiles to a PartialOrder" do
    assert {:ok, %PartialOrder{} = po} = Compiler.compile(diamond())

    # blocks: {s} -> {t1,t2} (co cluster) -> {j}; strict edges through the chain.
    assert length(po.children) == 3

    inner = Enum.find(po.children, &match?(%PartialOrder{}, &1))
    assert %PartialOrder{order: []} = inner
    assert for(c <- inner.children, do: c.label) |> Enum.sort() == [:t1, :t2]

    # index-agnostic: every order edge must point from earlier to later
    # block in the strict chain s -> {t1,t2} -> j, and all three edges exist.
    by_idx = children_by_labels(po.children)
    expected = [{{[:s], [:t1, :t2]}, [:s, :t1, :t2]}, {{[:s], [:j]}, [:s, :j]}, {{[:t1, :t2], [:j]}, [:t1, :t2, :j]}]

    assert Enum.count(po.order) == 3

    Enum.each(po.order, fn {i, j} ->
      assert {_, labels_i} = Enum.find(by_idx, fn {idx, _} -> idx == i end)
      assert {_, labels_j} = Enum.find(by_idx, fn {idx, _} -> idx == j end)
      assert Enum.any?(expected, fn {{a, b}, _} -> a == labels_i and b == labels_j end)
    end)
  end

  test "choice+loop net compiles to a ChoiceGraph with the loop face" do
    assert {:ok, %ChoiceGraph{} = top} = Compiler.compile(choice_loop())

    # SM blocks: {in} + {a,b,c}; the loop body block is a nested flat
    # ChoiceGraph over [a, b, c] with the a<->c loop face.
    in_idx = Enum.find_index(top.children, &match?(%Transition{label: :in}, &1))

    body_idx = Enum.find_index(top.children, &match?(%ChoiceGraph{}, &1))

    assert in_idx != nil and body_idx != nil
    assert {in_idx, body_idx} in MapSet.to_list(top.edges)

    body = Enum.at(top.children, body_idx)
    assert %ChoiceGraph{} = body
    assert for(c <- body.children, do: c.label) == [:a, :b, :c]

    # can-follow edges: a->b, a<->c (loop face), c->b
    assert MapSet.equal?(body.edges, MapSet.new([{0, 1}, {0, 2}, {2, 0}, {2, 1}]))
  end

  test "PT/TP-handle net is a typed non_separable_fallthrough" do
    assert {:error, :non_separable_fallthrough} = Compiler.compile(pt_handle())
  end

  test "malformed net (two sources) is a typed not_a_wf_net" do
    net = Powl2.net([:p0, :p1, :p2], [:only], [{:p0, :only}, {:only, :p2}, {:p1, :only}])
    assert {:error, :not_a_wf_net} = Compiler.compile(net)
  end

  test "empty transition set is a typed empty_net" do
    net = Powl2.net([:p0], [], [])
    assert {:error, :empty_net} = Compiler.compile(net)
  end

  test "structural_progress? refuses whole-fragment blocks" do
    refute Compiler.structural_progress?([:a, :b], [[:a, :b]])
    assert Compiler.structural_progress?([:a, :b], [[:a], [:b]])
  end

  test "relations classify diamond pairs (lt/co/conflict)" do
    net = diamond()
    rels = Compiler.relations(net, [:s, :t1, :t2, :j], [])

    assert rels[{:t1, :t2}] == :co
    assert rels[{:s, :t1}] == :lt
    assert rels[{:t1, :j}] == :lt
    assert rels[{:j, :s}] == :gt
  end

  test "loop_pair? detects the a<->c loop face in the choice+loop net" do
    net = choice_loop()
    rels = Compiler.relations(net, [:a, :b, :c], [])

    assert Compiler.loop_pair?(net, :a, :c, rels)
    refute Compiler.loop_pair?(net, :b, :c, rels)
  end

  defp children_by_labels(children) do
    Enum.with_index(children, fn child, idx ->
      labels =
        case child do
          %Transition{label: l} -> [l]
          %{children: ch} -> Enum.map(ch, & &1.label) |> Enum.sort()
        end

      {idx, labels}
    end)
  end
end

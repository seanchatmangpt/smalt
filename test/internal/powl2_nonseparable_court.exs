defmodule Smalt.Powl2NonseparableCourtTest do
  @moduledoc """
  POWLSK2 skeptic re-court (WO: v26.10.21 skeptic re-craft, HIGH-1/HIGH-2).

  The two adversarial nets from `docs/jira/v26.10.20/receipts/powl2-wave-skeptic.md`
  (HIGH-1 non-separable cross-cut admitted; HIGH-2 loop face erased), re-run
  against the landed POWL-4 compiler. Witnesses:

    - HIGH-1: the non-separable net (t3 concurrent with choice {t1,t2};
      t1/t2 conflict) must compile to `{:error, :non_separable_fallthrough}`.
    - HIGH-2: the well-formed loop WF-net (`t0; (a; b)*` via loop-back arc
      `b->i`, so a->b->a is truly possible) must compile to a ChoiceGraph
      whose {a, b} block CARRIES the loop face (bidirectional can-follow
      edges {0,1}+{1,0}) — never an empty edge set.

  Both were REFUTED against the ancestor compiler; this court pins the
  landed behavior. 5x repetition guards against reachability-order
  nondeterminism (the receipt runs were 5x-identical).
  """

  use ExUnit.Case, async: false

  alias Smalt.Powl2
  alias Smalt.Powl2.ChoiceGraph

  # t3 concurrent with the choice {t1, t2}; t1/t2 conflict.
  # source->tf->{pa,pb}; pa->{t1,t2}->pj->sink; pb->t3->sink.
  defp non_separable_net do
    Powl2.net(
      [:source, :pa, :pb, :pj, :sink],
      [:tf, :t1, :t2, :t3],
      [
        {:source, :tf},
        {:tf, :pa},
        {:tf, :pb},
        {:pa, :t1},
        {:pa, :t2},
        {:t1, :pj},
        {:t2, :pj},
        {:pj, :sink},
        {:pb, :t3},
        {:t3, :sink}
      ]
    )
  end

  # Well-formed loop: source->t0->i; i->a->m->b; b->sink and b->i (loop back).
  # Firing sequence t0 a b a b ... a b sink reaches the sink: a->b->a possible.
  defp loop_net do
    Powl2.net(
      [:source, :i, :m, :sink],
      [:t0, :a, :b],
      [
        {:source, :t0},
        {:t0, :i},
        {:i, :a},
        {:a, :m},
        {:m, :b},
        {:b, :sink},
        {:b, :i}
      ]
    )
  end

  test "HIGH-1: non-separable cross-cut net is typed-refused, 5x deterministic" do
    net = non_separable_net()
    assert Powl2.wf_net?(net)

    results =
      for _ <- 1..5 do
        Powl2.Compiler.compile(net, [])
      end

    assert Enum.uniq(results) == [{:error, :non_separable_fallthrough}]
  end

  test "HIGH-2: loop face present (bidirectional can-follow), 5x deterministic" do
    net = loop_net()
    assert Powl2.wf_net?(net)

    rels = Powl2.Compiler.relations(net, Enum.sort(net.transitions), [])
    assert rels[{:a, :b}] == :co
    assert rels[{:b, :a}] == :co

    results =
      for _ <- 1..5 do
        Powl2.Compiler.compile(net, [])
      end

    assert length(Enum.uniq(results)) == 1

    for {:ok, %ChoiceGraph{children: [inner, %Powl2.Transition{label: :t0}], edges: outer}} <- results do
      assert %ChoiceGraph{
               children: [%Powl2.Transition{label: :a}, %Powl2.Transition{label: :b}],
               # the loop face: a can follow b AND b can follow a
               edges: loop_face
             } = inner

      assert loop_face |> MapSet.to_list() |> Enum.sort() == [{0, 1}, {1, 0}]
      assert outer == MapSet.new([{1, 0}])
    end
  end

  test "HIGH-2 non-vacuity: a CHOICE net compiles to a flat CG with NO loop face" do
    # source->{a,b}->sink: pure choice, both directions :conflict, edges empty.
    net =
      Powl2.net(
        [:source, :sink],
        [:a, :b],
        [{:source, :a}, {:source, :b}, {:a, :sink}, {:b, :sink}]
      )

    assert Powl2.wf_net?(net)

    assert {:ok, %ChoiceGraph{children: [%Powl2.Transition{label: :a}, %Powl2.Transition{label: :b}], edges: edges}} =
             Powl2.Compiler.compile(net, [])

    assert MapSet.size(edges) == 0
  end

  # BK-POWLH2 (HIGH-2 close-out): the BK-REWIT3 receipt's minimal "loop"
  # net is UNSOUND, not a mis-compiled loop — `a` has input places
  # {source, pl}, so `a` can never fire (it needs both tokens; `source`
  # is consumed), the sink is unreachable, and both transitions are dead.
  # Dead transitions classify :conflict and, pre-gate, compiled silently
  # to an edge-less ChoiceGraph. The soundness gate now refuses it
  # (typed :net_not_sound) while the sound loop above still carries its
  # loop face.
  defp unsound_loop_net do
    Powl2.net(
      [:source, :pb, :pl, :sink],
      [:a, :b],
      [
        {:source, :a},
        {:a, :pb},
        {:pb, :b},
        {:b, :sink},
        {:b, :pl},
        {:pl, :a}
      ]
    )
  end

  test "HIGH-2 residual: the unsound minimal loop net is typed-refused :net_not_sound, 5x deterministic" do
    net = unsound_loop_net()
    # shape-gates alone admit this net — the soundness gate does real work
    assert Powl2.wf_net?(net)

    rels = Powl2.Compiler.relations(net, Enum.sort(net.transitions), [])
    # dead transitions classify :conflict — the erased-loop-face signature
    assert rels[{:a, :b}] == :conflict
    assert rels[{:b, :a}] == :conflict

    results =
      for _ <- 1..5 do
        Powl2.Compiler.compile(net, [])
      end

    assert Enum.uniq(results) == [{:error, :net_not_sound}]
  end

  # BK-REWIT3 typed reticle drift ("2-cycle now :ok, 3-cycle refuses"):
  # NOT reproduced on the current tree — the transitive-closure cycle check
  # refuses BOTH. This leg pins the drift closed either way.
  test "reticle cycle pin: PartialOrder 2-cycle AND 3-cycle are typed-refused" do
    alias Smalt.POWL2.Reticle
    alias Smalt.POWL2.Reticle.AST

    tr = fn id -> %AST.Transition{id: id, label: id} end

    two_cycle = %AST.PartialOrder{
      children: %{:a => tr.(:a), :b => tr.(:b)},
      order: [{:a, :b}, {:b, :a}]
    }

    three_cycle = %AST.PartialOrder{
      children: %{:a => tr.(:a), :b => tr.(:b), :c => tr.(:c)},
      order: [a: :b, b: :c, c: :a]
    }

    # node named in the message follows MapSet iteration order — pin the
    # refusal class, not the node
    assert {:error, {:shacl_violation, msg2}} = Reticle.admit(two_cycle)
    assert msg2 =~ "cycle in partial order through"
    assert {:error, {:shacl_violation, msg3}} = Reticle.admit(three_cycle)
    assert msg3 =~ "cycle in partial order through"
  end

  # BK-1SAFE gate-scope boundary, typed: 1-safeness is NOT machine-checked.
  # The classic not-1-safe shape (place p fed by two producers that CAN both
  # fire, p drained once to the sink) passes the soundness gate and compiles
  # :ok — deliberately. The reachability engine is set-semantics by
  # representation (markings are MapSets; fire/3 collapses multiplicity), and
  # the runtime executor is a token-agnostic topology walk over the AST, so a
  # multiset token-game gate would only refuse the canonical redo-loop nets
  # the HIGH-2 leg above pins as the loop representation. This leg pins the
  # boundary as DOCUMENTED behavior (not a silent gap): a not-1-safe net
  # compiles deterministically under set semantics, and its relations are
  # total over the transition set.
  defp two_unsafe_net do
    Powl2.net(
      [:source, :m, :p, :sink],
      [:t0, :t1, :t2, :t3],
      [
        {:source, :t0},
        {:t0, :m},
        # and-split: t1 and t2 can BOTH fire from {m} — under multiset
        # semantics p accumulates 2 tokens => the net is not 1-safe.
        {:m, :t1},
        {:m, :t2},
        {:t1, :p},
        {:t2, :p},
        {:p, :t3},
        {:t3, :sink}
      ]
    )
  end

  test "BK-1SAFE: a not-1-safe net compiles :ok (typed set-semantics boundary), 5x deterministic" do
    net = two_unsafe_net()
    assert Powl2.wf_net?(net)

    # relations are total over all ordered transition pairs — the set-semantics
    # analysis is well-defined for this net (no nil cells, no blowup refusal)
    ts = Enum.sort(net.transitions)

    rels = Powl2.Compiler.relations(net, ts, [])

    assert Map.size(rels) == length(ts) * (length(ts) - 1)
    assert Enum.all?(Map.values(rels), &(&1 in [:lt, :gt, :co, :conflict]))

    results =
      for _ <- 1..5 do
        Powl2.Compiler.compile(net, [])
      end

    assert length(Enum.uniq(results)) == 1
    assert {:ok, %ChoiceGraph{}} = hd(results)
  end

  # BK-1SAFE non-vacuity: the boundary is a DELIBERATE omission, not a
  # vacuous gate. The soundness gate next to it still does real work — the
  # same and-split shape with the sink made unreachable flips to the typed
  # :net_not_sound refusal (a court that accepts the mutation exits as
  # VACUOUS).
  test "BK-1SAFE non-vacuity: soundness gate still refuses the unsafe shape when the sink is cut off" do
    net = two_unsafe_net()

    # mutate: back-edge p->t0 makes t0 need {source, p} — p is only produced
    # by t1/t2 which need m from t0, so t0 is DEAD (deadlock), nothing ever
    # fires, the sink is unreachable. wf-shape still intact (unique source,
    # unique sink, all transitions have in/out arcs) — only the soundness
    # gate catches it.
    mutated =
      Powl2.net(
        [:source, :m, :p, :sink],
        [:t0, :t1, :t2, :t3],
        [
          {:source, :t0},
          {:p, :t0},
          {:t0, :m},
          {:m, :t1},
          {:m, :t2},
          {:t1, :p},
          {:t2, :p},
          {:p, :t3},
          {:t3, :sink}
        ]
      )

    assert Powl2.wf_net?(mutated)
    assert {:error, :net_not_sound} = Powl2.Compiler.compile(mutated, [])

    # the un-mutated net compiles :ok — the pair of outcomes is the proof the
    # gate distinguishes, and that :ok for the 2-unsafe net is a typed
    # boundary, not a gate that never looks
    assert {:ok, %ChoiceGraph{}} = Powl2.Compiler.compile(net, [])
  end
end

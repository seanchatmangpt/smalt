defmodule Smalt.PetriNetTest do
  @moduledoc """
  Chicago-style tests for the WF-net struct (real nets, assert on final state).

  Diamond:   p_src -> [a] -> p_m -> [b] -> p_snk   (sequence with a middle place)
  Choice+loop: source feeds a choice; one branch loops back before the sink.
  """
  use ExUnit.Case, async: true

  alias Smalt.PetriNet

  # p_src -> a -> p_m -> b -> p_snk
  defp diamond do
    PetriNet.new(
      arcs: [
        {:place, :p_src, :a},
        {:transition, :a, :p_m},
        {:place, :p_m, :b},
        {:transition, :b, :p_snk}
      ],
      source: :p_src,
      sink: :p_snk
    )
  end

  # p_src -> c1 -> p_x -> snk_t -> p_snk   (choice arm 1, straight)
  # p_src -> c2 -> p_y -> snk_u -> p_snk   (choice arm 2, with loop)
  # p_y -> u_loop -> p_y                    (loop back on itself)
  defp choice_loop do
    PetriNet.new(
      arcs: [
        {:place, :p_src, :c1},
        {:place, :p_src, :c2},
        {:transition, :c1, :p_x},
        {:transition, :c2, :p_y},
        {:place, :p_x, :snk_t},
        {:place, :p_y, :u_loop},
        {:transition, :u_loop, :p_y},
        {:transition, :snk_t, :p_snk},
        {:place, :p_y, :snk_u},
        {:transition, :snk_u, :p_snk}
      ],
      source: :p_src,
      sink: :p_snk,
      labels: %{snk_t: "sink-t", snk_u: "sink-u"}
    )
  end

  describe "new/1" do
    test "derives places and transitions from arcs" do
      n = diamond()

      assert n.places == MapSet.new([:p_src, :p_m, :p_snk])
      assert n.transitions == MapSet.new([:a, :b])
      assert n.labels == %{a: :a, b: :b}
    end

    test "explicit places are unioned with arc-derived ones; labels override identity" do
      n = choice_loop()

      assert MapSet.subset?(MapSet.new([:p_src, :p_x, :p_y, :p_snk]), n.places)
      assert n.labels.snk_t == "sink-t"
      assert n.labels.c1 == :c1
    end
  end

  describe "preset/postset" do
    test "transition preset and postset" do
      n = diamond()

      assert PetriNet.preset(n, :a) == MapSet.new([:p_src])
      assert PetriNet.postset(n, :a) == MapSet.new([:p_m])
    end

    test "place preset and postset" do
      n = choice_loop()

      assert PetriNet.preset(n, :p_snk) == MapSet.new([:snk_t, :snk_u])
      assert PetriNet.postset(n, :p_src) == MapSet.new([:c1, :c2])
    end

    test "isolated nodes have empty adjacency" do
      n = PetriNet.new(arcs: [], places: [:lone], transitions: [:ghost], source: :lone)
      assert MapSet.size(PetriNet.preset(n, :lone)) == 0
      assert MapSet.size(PetriNet.postset(n, :ghost)) == 0
    end
  end

  describe "reachability" do
    test "diamond: both transitions reachable, closure is total" do
      assert PetriNet.reachable_transitions(diamond()) == MapSet.new([:a, :b])
    end

    test "choice+loop: all transitions reachable including the loop body" do
      ts = PetriNet.reachable_transitions(choice_loop())
      assert MapSet.subset?(MapSet.new([:c1, :c2, :u_loop, :snk_t, :snk_u]), ts)
    end

    test "negative: unreachable branch is excluded" do
      # p_src -> a -> p_m -> b -> p_snk ; dead: d -> p_dead -> e
      n = PetriNet.new(
        arcs: [
          {:place, :p_src, :a},
          {:transition, :a, :p_m},
          {:place, :p_m, :b},
          {:transition, :b, :p_snk},
          {:place, :p_dead, :d},
          {:transition, :d, :p_dead_out},
          {:transition, :e, :p_dead_out}
        ],
        source: :p_src,
        sink: :p_snk
      )

      ts = PetriNet.reachable_transitions(n)
      assert :d not in ts
      assert :e not in ts
      refute MapSet.equal?(ts, n.transitions)
    end

    test "negative: t_stop in the loop body never blocks straight-through path" do
      n = choice_loop()

      # excluding c2's arm leaves c1's arm fully reachable
      assert PetriNet.forward_restricted(n, :c2) |> MapSet.member?(:snk_t)
    end
  end

  describe "restricted reachability (Defs 4.5/4.6)" do
    test "forward: t_stop excluded and its downstream unreachable through it" do
      n = diamond()
      fwd = PetriNet.forward_restricted(n, :a)

      refute MapSet.member?(fwd, :a)
      refute MapSet.member?(fwd, :b)
    end

    test "forward: removing a middle transition still leaves earlier ones" do
      n = diamond()
      fwd = PetriNet.forward_restricted(n, :b)

      assert MapSet.member?(fwd, :a)
      refute MapSet.member?(fwd, :b)
    end

    test "backward: t_stop excluded; upstream of t_stop cannot reach sink without it" do
      n = diamond()
      bwd = PetriNet.backward_restricted(n, :b)

      refute MapSet.member?(bwd, :b)
      # strict path semantics: the sink's only outgoing (reversed) transition
      # is the stop itself, so the t_stop-free path set is empty
      assert MapSet.equal?(bwd, MapSet.new())
    end

    test "backward: arm whose sink-path runs through t_stop is excluded" do
      n = choice_loop()
      bwd = PetriNet.backward_restricted(n, :snk_u)

      # strict path semantics on the reversed net from the sink: only the
      # straight arm (snk_t, c1) reaches p_src; the reversed closure stops
      # there because p_src has no outgoing reversed arc. c2/u_loop (whose
      # only path to the sink runs through snk_u) and snk_u itself are excluded.
      assert MapSet.equal?(bwd, MapSet.new([:snk_t, :c1]))
    end

    test "restricted views compose: fwd-minus-t_stop intersect bwd-minus-t_stop" do
      n = diamond()
      fwd = PetriNet.forward_restricted(n, :a)
      bwd = PetriNet.backward_restricted(n, :a)

      assert MapSet.equal?(fwd, MapSet.new())
      # b is on a t_stop=a-free path to the sink (p_m -> b -> p_snk avoids a)
      assert MapSet.equal?(bwd, MapSet.new([:b]))
      refute MapSet.member?(PetriNet.backward_restricted(n, :b), :b)
    end
  end

  describe "interface points (Section 4.2.1)" do
    test "well-formed nets: entry = [source], exit = [sink]" do
      n = diamond()

      assert PetriNet.entry_places(n) == MapSet.new([:p_src])
      assert PetriNet.exit_places(n) == MapSet.new([:p_snk])
      assert PetriNet.well_formed?(n)
    end

    test "choice+loop net is well-formed" do
      assert PetriNet.well_formed?(choice_loop())
    end

    test "net with an extra entry place is not well-formed" do
      n = PetriNet.new(
        arcs: [
          {:place, :p_src, :a},
          {:transition, :a, :p_snk}
        ],
        places: [:p_other],
        source: :p_src,
        sink: :p_snk
      )

      assert MapSet.member?(PetriNet.entry_places(n), :p_other)
      refute PetriNet.well_formed?(n)
    end

    test "net with unreachable transition is not well-formed" do
      n = PetriNet.new(
        arcs: [
          {:place, :p_src, :a},
          {:transition, :a, :p_snk},
          {:place, :p_iso, :ghost}
        ],
        transitions: [:orphan],
        source: :p_src,
        sink: :p_snk
      )

      refute PetriNet.well_formed?(n)
    end
  end
end

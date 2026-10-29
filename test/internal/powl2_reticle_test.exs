defmodule Smalt.POWL2.ReticleTest do
  use ExUnit.Case, async: true

  alias Smalt.POWL2.Reticle
  alias Smalt.POWL2.Reticle.AST

  defp t(id, label \\ nil), do: %AST.Transition{id: id, label: label || String.upcase(to_string(id))}

  test "admits a well-formed transition" do
    assert :ok = Reticle.admit(%AST.Transition{id: :a, label: "A"})
  end

  test "refuses transition without id" do
    assert {:error, {:shacl_violation, msg}} = Reticle.admit(%AST.Transition{id: nil, label: "A"})
    assert msg =~ "id"
  end

  test "refuses transition without label" do
    assert {:error, {:shacl_violation, msg}} = Reticle.admit(%AST.Transition{id: :a, label: nil})
    assert msg =~ "label"
  end

  test "refuses non-AST terms" do
    assert {:error, {:shacl_violation, _}} = Reticle.admit(%{not: :an_ast})
    assert {:error, {:shacl_violation, _}} = Reticle.admit("just a string")
  end

  # -- PartialOrder ----------------------------------------------------------

  test "admits a well-formed partial order (diamond)" do
    po = %AST.PartialOrder{
      children: %{:a => t(:a), :b => t(:b), :c => t(:c), :d => t(:d)},
      order: [a: :b, a: :c, b: :d, c: :d]
    }

    assert :ok = Reticle.admit(po)
  end

  test "refuses order pair outside children" do
    po = %AST.PartialOrder{children: %{:a => t(:a)}, order: [a: :ghost]}

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(po)
    assert msg =~ "outside children"
  end

  test "refuses irreflexive violation" do
    po = %AST.PartialOrder{children: %{:a => t(:a)}, order: [a: :a]}

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(po)
    assert msg =~ "irreflexive"
  end

  test "refuses cyclic partial order" do
    po = %AST.PartialOrder{
      children: %{:a => t(:a), :b => t(:b), :c => t(:c)},
      order: [a: :b, b: :c, c: :a]
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(po)
    assert msg =~ "cycle"
  end

  test "refuses cycle reachable only through closure (transitive return path)" do
    po = %AST.PartialOrder{
      children: %{:a => t(:a), :b => t(:b), :c => t(:c)},
      order: [a: :b, b: :c, c: :b]
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(po)
    assert msg =~ "cycle"
  end

  test "admits transitive chain without cycle" do
    po = %AST.PartialOrder{
      children: %{:a => t(:a), :b => t(:b), :c => t(:c)},
      order: [a: :b, b: :c]
    }

    assert :ok = Reticle.admit(po)
  end

  # -- ChoiceGraph -----------------------------------------------------------

  defp diamond_graph do
    %AST.ChoiceGraph{
      children: %{:start => t(:start), :l => t(:l), :r => t(:r), :end => t(:end)},
      start: :start,
      end: :end,
      edges: [start: :l, start: :r, l: :end, r: :end]
    }
  end

  test "admits a well-formed SESE diamond" do
    assert :ok = Reticle.admit(diamond_graph())
  end

  test "refuses edge into start" do
    cg = %AST.ChoiceGraph{
      children: %{:start => t(:start), :x => t(:x), :end => t(:end)},
      start: :start,
      end: :end,
      edges: [start: :x, x: :end, end: :start]
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(cg)
    assert msg =~ "into start"
  end

  test "refuses edge out of end" do
    cg = %AST.ChoiceGraph{
      children: %{:start => t(:start), :x => t(:x), :end => t(:end)},
      start: :start,
      end: :end,
      edges: [start: :x, x: :end, end: :x]
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(cg)
    assert msg =~ "out of end"
  end

  test "refuses delimiters not present as children" do
    cg = %AST.ChoiceGraph{
      children: %{:x => t(:x)},
      start: :missing,
      end: :end,
      edges: []
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(cg)
    assert msg =~ "start"
  end

  test "refuses deadlocking choice graph with trapped node" do
    cg = %AST.ChoiceGraph{
      children: %{
        :start => t(:start),
        :on_path => t(:on_path),
        :trap => t(:trap),
        :end => t(:end)
      },
      start: :start,
      end: :end,
      edges: [start: :on_path, on_path: :end]
      # :trap has no edges at all — unreachable from start, cannot reach end
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(cg)
    assert msg =~ "trapped"
    assert msg =~ ":trap"
  end

  test "refuses node that is reachable from start but cannot reach end" do
    cg = %AST.ChoiceGraph{
      children: %{
        :start => t(:start),
        :sink => t(:sink),
        :end => t(:end)
      },
      start: :start,
      end: :end,
      edges: [start: :sink, start: :end]
      # :sink reachable from start but has no outgoing edge
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(cg)
    assert msg =~ ":sink"
  end

  # -- Nested ----------------------------------------------------------------

  test "refuses nested child violations through recursion" do
    bad_transition = %AST.Transition{id: :bad, label: nil}

    cg = %AST.ChoiceGraph{
      children: %{:start => bad_transition, :end => t(:end)},
      start: :start,
      end: :end,
      edges: [start: :end]
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(cg)
    assert msg =~ "label"
  end
end

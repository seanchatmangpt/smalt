defmodule Smalt.POWL2.ExecutorTest do
  use ExUnit.Case, async: false

  # Real collaborators: real DETS table, real Tasks, real message passing.
  # The AST module (POWL-4) has not landed in this tree yet, so tests build
  # struct-shaped maps with a literal __struct__ key — the executor's
  # dispatch is by __struct__ value, so these are indistinguishable from
  # real structs at the kernel boundary.

  @transition Smalt.POWL2.Reticle.AST.Transition
  @partial_order Smalt.POWL2.Reticle.AST.PartialOrder
  @choice_graph Smalt.POWL2.Reticle.AST.ChoiceGraph

  defp t(id, op), do: %{__struct__: @transition, id: id, label: Atom.to_string(id), op: op}

  setup do
    table = String.to_atom("powl9_receipts_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "#{table}.dets")
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path))

    on_exit(fn ->
      File.rm(path)
      :ok
    end)

    %{dets: table, caller: self()}
  end

  defp completed_receipt(dets, id) do
    assert [{{:powl2_receipt, ^id}, receipt}] = :dets.lookup(dets, {:powl2_receipt, id})
    receipt
  end

  # -- linear 3-step ---------------------------------------------------------

  test "linear 3-step workflow completes with receipt phi_lease_final=3", %{dets: dets, caller: caller} do
    model = %{
      __struct__: @partial_order,
      id: :linear,
      children: %{
        a: t(:a, fn ctx -> {:ok, Map.put(ctx, :a, 1)} end),
        b: t(:b, fn ctx -> {:ok, Map.put(ctx, :b, ctx.a + 1)} end),
        c: t(:c, fn ctx -> {:ok, Map.put(ctx, :c, ctx.b + 1)} end)
      },
      order: [a: :b, b: :c]
    }

    assert :ok =
             Smalt.POWL2.Executor.execute_admitted(:lin1, {:ok, model}, %{}, dets, caller)

    assert_received {:orchestration_completed, :lin1, ctx, receipt}
    assert ctx.c == 3
    assert receipt.status == :completed
    assert receipt.phi_lease_final == 3
    assert Enum.map(receipt.steps, & &1.node) == [:a, :b, :c]

    assert completed_receipt(dets, :lin1).phi_lease_final == 3
  end

  # -- choice graph ------------------------------------------------------------

  test "choice graph takes the :ok branch and skips the other", %{dets: dets, caller: caller} do
    model = %{
      __struct__: @choice_graph,
      id: :choice,
      start: :split,
      end: :done,
      children: %{
        split: t(:split, fn ctx -> {:ok, ctx} end),
        ok_branch: t(:ok_branch, fn ctx -> {:ok, Map.put(ctx, :took, :ok_branch), :ok} end),
        err_branch: t(:err_branch, fn _ctx -> raise "err_branch must be skipped" end),
        done: t(:done, fn ctx -> {:ok, ctx} end)
      },
      edges: [
        {:split, :ok_branch},
        {:split, :err_branch},
        {:ok_branch, :done},
        {:err_branch, :done}
      ],
      guards: %{ok_branch: :ok, err_branch: :error}
    }

    ctx = %{last_outcome: :ok}

    assert :ok = Smalt.POWL2.Executor.execute_admitted(:choice1, {:ok, model}, ctx, dets, caller)

    assert_received {:orchestration_completed, :choice1, ctx2, receipt}
    assert ctx2.took == :ok_branch
    node_ids = Enum.map(receipt.steps, & &1.node)
    assert :ok_branch in node_ids
    refute :err_branch in node_ids
    assert receipt.phi_lease_final == 2
  end

  test "choice graph falls back to :always edge when no guard matches", %{dets: dets, caller: caller} do
    model = %{
      __struct__: @choice_graph,
      id: :choice_always,
      start: :split,
      end: :done,
      children: %{
        split: t(:split, fn ctx -> {:ok, ctx} end),
        fallback: t(:fallback, fn ctx -> {:ok, Map.put(ctx, :took, :fallback)} end),
        done: t(:done, fn ctx -> {:ok, ctx} end)
      },
      edges: [
        {:split, :fallback},
        {:fallback, :done}
      ],
      guards: %{fallback: :always}
    }

    assert :ok =
             Smalt.POWL2.Executor.execute_admitted(:choice2, {:ok, model}, %{last_outcome: :weird}, dets, caller)

    assert_received {:orchestration_completed, :choice2, ctx, _receipt}
    assert ctx.took == :fallback
  end

  # -- partial order concurrency -------------------------------------------------
  test "BK-POWLH3: can-follow closure walk fires the witnessed sequential tail (t_pub once), not just the first edge's path", %{
    dets: dets,
    caller: caller
  } do
    # The BK-POWLH2-2 witnessed shape: a SOUND net whose tail is
    # sign -> pub -> join (publish BEFORE the join). The old single-edge
    # walk picked nested->join and terminated without ever firing t_pub.
    # The walk is now closure-complete: every node the can-follow closure
    # orders after the pick fires exactly once. Real collaborators: the
    # real Compiler (sound net -> ChoiceGraph) and the real executor.
    net =
      Smalt.Powl2.net(
        [:src, :p1, :p2, :p3, :p4, :sink],
        [:t_in, :t_cas, :t_retry, :t_sign, :t_pub, :t_join],
        [
          {:src, :t_in},
          {:t_in, :p1},
          {:p1, :t_cas},
          {:t_cas, :p2},
          {:p2, :t_retry},
          {:t_retry, :p1},
          {:p2, :t_sign},
          {:t_sign, :p3},
          {:p3, :t_pub},
          {:t_pub, :p4},
          {:p4, :t_join},
          {:t_join, :sink}
        ]
      )

    assert {:ok, compiled} = Smalt.Powl2.Compiler.compile(net)
    model = witnessed_projection(compiled)
    :ok = Smalt.POWL2.Reticle.admit(model)

    assert :ok =
             Smalt.POWL2.Executor.execute_admitted(
               :powlh3_tail,
               {:ok, model},
               %{},
               dets,
               caller
             )

    assert_received {:orchestration_completed, :powlh3_tail, _ctx2, receipt}
    nodes = Enum.map(receipt.steps, & &1.node)
    assert :t_pub in nodes, "t_pub must fire on the sequential tail (BK-POWLH2-2)"
    assert :t_join in nodes

    # Closure-complete, not a re-fire flood: each ordered child exactly once;
    # the loop face keeps guard-driven iteration (cas twice, retry once).
    assert Enum.count(nodes, &(&1 == :t_pub)) == 1
    assert Enum.count(nodes, &(&1 == :t_join)) == 1
    assert Enum.count(nodes, &(&1 == :t_sign)) == 1
    assert Enum.frequencies(Enum.filter(nodes, &(&1 in [:t_cas, :t_retry]))) == %{t_cas: 2, t_retry: 1}
  end

  # Court-side tau-delimited SESE projection of the compiled AST (same
  # shape as the gates court's to_reticle; declared here, in the court,
  # never faked in lib/). Guard overlays give the loop its retry face.
  defp witnessed_projection(%Smalt.Powl2.ChoiceGraph{children: children, edges: edges}) do
    n = length(children)

    shifted =
      children
      |> Enum.with_index()
      |> Map.new(fn {child, i} -> {i + 1, witness_child(child)} end)

    compiled = Enum.map(MapSet.to_list(edges), fn {i, j} -> {i + 1, j + 1} end)
    entry = for i <- 1..n, do: {0, i}
    exit_edges = for i <- 1..n, do: {i, n + 1}

    overlays = %{t_retry: :cas_conflict, t_cas: :always}

    guards =
      Enum.reduce(overlays, %{}, fn {label, g}, acc ->
        case Enum.find_index(children, fn
               %Smalt.Powl2.Transition{label: ^label} -> true
               _ -> false
             end) do
          nil -> acc
          i -> Map.put(acc, i + 1, g)
        end
      end)

    %Smalt.POWL2.Reticle.AST.ChoiceGraph{
      children:
        Map.merge(
          %{0 => tau0(), (n + 1) => tau0()},
          shifted
        ),
      start: 0,
      end: n + 1,
      edges: compiled ++ entry ++ exit_edges,
      guards: guards
    }
  end

  defp tau0, do: %Smalt.POWL2.Reticle.AST.Transition{id: :tau, label: :tau, op: fn ctx -> {:ok, ctx, :tau} end}

  defp witness_child(%Smalt.Powl2.ChoiceGraph{} = cg), do: witnessed_projection(cg)

  defp witness_child(%Smalt.Powl2.Transition{label: l}) do
    ops = %{
      t_cas: fn ctx ->
        if Map.get(ctx, :cas_n, 0) == 0,
          do: {:ok, Map.put(ctx, :cas_n, 1), :cas_conflict},
          else: {:ok, Map.put(ctx, :cas_n, 2), :cas_ok}
      end,
      t_retry: fn ctx -> {:ok, Map.update(ctx, :retries, 1, &(&1 + 1)), :retried} end,
      t_sign: fn ctx -> {:ok, Map.put(ctx, :signed, true), :signed} end,
      t_pub: fn ctx -> {:ok, Map.put(ctx, :published, true), :published} end,
      t_join: fn ctx -> {:ok, ctx, :joined} end,
      t_in: fn ctx -> {:ok, ctx, :in} end
    }

    %Smalt.POWL2.Reticle.AST.Transition{id: l, label: l, op: Map.get(ops, l, fn ctx -> {:ok, ctx, :tau} end)}
  end

  test "partial order executes frontier concurrently and merges", %{dets: dets, caller: caller} do
    # Barrier protocol: each frontier op signals {:started, id} then blocks
    # on {:release, id}. If the kernel ran the frontier serially, the first
    # op would never see its release (the test only releases after BOTH
    # starts arrive), and the run would dead-lock into the task deadline —
    # the test fails either way. No sleeps: structural sync on messages.
    parent = self()

    barrier_op = fn id ->
      fn ctx ->
        send(parent, {:powl9_started, id, self()})
        assert_receive {:powl9_release, ^id}, 10_000
        send(parent, {:powl9_released, id})
        {:ok, Map.put(ctx, id, true)}
      end
    end

    merge_op = fn ctx -> {:ok, Map.put(ctx, :merged, :both)} end

    model = %{
      __struct__: @partial_order,
      id: :po,
      children: %{
        x: t(:x, barrier_op.(:x)),
        y: t(:y, barrier_op.(:y)),
        m: t(:m, merge_op)
      },
      order: [x: :m, y: :m]
    }

    task =
      Task.async(fn ->
        Smalt.POWL2.Executor.execute_admitted(:po1, {:ok, model}, %{}, dets, caller)
      end)

    assert_receive {:powl9_started, :x, x_pid}, 10_000
    assert_receive {:powl9_started, :y, y_pid}, 10_000
    send(x_pid, {:powl9_release, :x})
    send(y_pid, {:powl9_release, :y})
    assert_receive {:powl9_released, :x}, 10_000
    assert_receive {:powl9_released, :y}, 10_000

    assert :ok = Task.await(task, 10_000)
    assert_received {:orchestration_completed, :po1, ctx, receipt}
    assert ctx.x == true
    assert ctx.y == true
    assert ctx.merged == :both
    assert receipt.phi_lease_final == 3

    # Interleaving tolerance: the two frontier steps arrive in one wave, in
    # either order; the merge step follows both.
    [first, second, third] = Enum.map(receipt.steps, & &1.node)
    assert MapSet.new([first, second]) == MapSet.new([:x, :y])
    assert third == :m
  end

  # -- refusal paths --------------------------------------------------------------

  test "non-admitted model is refused when reticle is available", %{dets: dets, caller: caller} do
    defmodule RefusingReticle do
      def admit(%{__struct__: Smalt.POWL2.Reticle.AST.Transition, id: :contraband}),
        do: {:error, {:shacl_violation, "contraband"}}

      def admit(_), do: :ok
    end

    contraband = %{__struct__: @transition, id: :contraband, label: "bad", op: fn ctx -> {:ok, ctx} end}

    assert {:error, {:shacl_violation, "contraband"}} =
             Smalt.POWL2.Executor.execute_admitted(
               :bad1,
               {:ok, contraband},
               %{},
               dets,
               caller,
               RefusingReticle
             )

    assert_received {:orchestration_refused, :bad1, {:shacl_violation, "contraband"}}
    assert [{{:powl2_refusal, :bad1}, _}] = :dets.lookup(dets, {:powl2_refusal, :bad1})
  end

  test "error verdict from the admission path is refused without reticle", %{dets: dets, caller: caller} do
    assert {:error, :not_admitted} =
             Smalt.POWL2.Executor.execute_admitted(:bad2, {:error, :not_admitted}, %{}, dets, caller)

    assert_received {:orchestration_refused, :bad2, :not_admitted}
    assert [{{:powl2_refusal, :bad2}, _}] = :dets.lookup(dets, {:powl2_refusal, :bad2})
  end

  # -- failure inside an op ---------------------------------------------------------

  test "op failure fails the run and still records the receipt", %{dets: dets, caller: caller} do
    model = %{
      __struct__: @partial_order,
      id: :failing,
      children: %{
        a: t(:a, fn _ctx -> {:error, :boom} end)
      },
      order: []
    }

    assert {:error, {:transition_failed, :a, :boom}} =
             Smalt.POWL2.Executor.execute_admitted(:fail1, {:ok, model}, %{}, dets, caller)

    assert_received {:orchestration_failed, :fail1, {:transition_failed, :a, :boom}}
    receipt = completed_receipt(dets, :fail1)
    assert receipt.status == {:error, {:transition_failed, :a, :boom}}
    assert receipt.phi_lease_final == 1
  end
end

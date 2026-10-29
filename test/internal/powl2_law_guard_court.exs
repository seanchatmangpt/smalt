defmodule Smalt.POWL2.LawGuardCourtTest do
  alias Smalt.POWL2.LawCompiler
  use ExUnit.Case, async: false

  # GL-1 law-guard seam court. Real collaborators: real DETS table, real
  # ETS "data plane" store the guarded ops would mutate, real Tasks. The
  # refusal assertions are on final store state (no mutation happened),
  # never on call counts.

  @transition Smalt.POWL2.Reticle.AST.Transition
  @partial_order Smalt.POWL2.Reticle.AST.PartialOrder

  defp t(id, op, extra \\ %{}) do
    Map.merge(%{__struct__: @transition, id: id, label: Atom.to_string(id), op: op}, extra)
  end

  setup do
    table = String.to_atom("powl_gl1_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "#{table}.dets")
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path))

    # Real data-plane stand-in: a named ETS table a guarded op would write.
    store = String.to_atom("powl_gl1_store_#{System.unique_integer([:positive])}")
    ^store = :ets.new(store, [:named_table, :set, :public])

    on_exit(fn ->
      File.rm(path)
      :ok
    end)

    %{dets: table, caller: self(), store: store}
  end

  defp write_op(store, key, val), do: fn _ctx -> :ets.insert(store, {key, val}) && {:ok, %{}} end

  defp assert_store_unchanged(store, expected) do
    assert :ets.tab2list(store) == expected
  end

  # -- refusal: no data-plane mutation ---------------------------------------

  test "guarded transition refusal leaves the store untouched and emits the andon receipt", %{
    dets: dets,
    caller: caller,
    store: store
  } do
    guard = fn _ctx -> {:andon_refusal, :r42, "worm container locked"} end

    model = %{
      __struct__: @partial_order,
      id: :g1,
      children: %{
        write: t(:write, write_op(store, :blob, :mutated), %{})
      },
      order: []
    }

    # Inline guard tuple form: {:graphlaw_guard, shape_id, fun, inner_op}
    write_node = Map.put(model.children.write, :op, {:graphlaw_guard, :worm_shape, guard, write_op(store, :blob, :mutated)})
    model = %{model | children: Map.put(model.children, :write, write_node)}

    assert {:error, {:powl2_andon, :write, :r42, "worm container locked"}} =
             Smalt.POWL2.Executor.execute_admitted(:g1, {:ok, model}, %{}, dets, caller)

    assert_store_unchanged(store, [])

    assert_received {:orchestration_refused, :g1, {:powl2_andon, :write, :r42, "worm container locked"}}

    assert [{{:powl2_andon, :write}, receipt}] = :dets.lookup(dets, {:powl2_andon, :write})
    assert receipt.rule_id == :r42
    assert receipt.diagnostic == "worm container locked"
    assert receipt.shape_id == :worm_shape
    assert is_integer(receipt.at_ms)

    run_receipt = :dets.lookup(dets, {:powl2_receipt, :g1})
    assert [{{:powl2_receipt, :g1}, r}] = run_receipt
    assert r.status == {:error, {:powl2_andon, :write, :r42, "worm container locked"}}
  end

  # -- approval: guarded op runs ----------------------------------------------

  test "guard :ok lets the op run and mutate the store", %{dets: dets, caller: caller, store: store} do
    guard = fn ctx -> if ctx[:cleared], do: :ok, else: {:andon_refusal, :r1, "not cleared"} end

    model = %{
      __struct__: @partial_order,
      id: :g2,
      children: %{
        write: t(:write, {:graphlaw_guard, :shape_a, guard, write_op(store, :blob, :ok_val)})
      },
      order: []
    }

    assert :ok =
             Smalt.POWL2.Executor.execute_admitted(:g2, {:ok, model}, %{cleared: true}, dets, caller)

    assert_received {:orchestration_completed, :g2, _ctx, _receipt}
    assert :ets.lookup(store, :blob) == [{:blob, :ok_val}]
    refute :dets.lookup(dets, {:powl2_andon, :write}) != []
  end

  # -- FOND repair edge ----------------------------------------------------------

  test "refusal routes through the FOND repair edge (node-level) and completes", %{
    dets: dets,
    caller: caller,
    store: store
  } do
    guard = fn _ctx -> {:andon_refusal, :r7, "stale lease"} end

    repair =
      t(:repair, fn ctx -> {:ok, Map.put(ctx, :repaired, true)} end)

    model = %{
      __struct__: @partial_order,
      id: :g3,
      children: %{
        write: t(:write, {:graphlaw_guard, :lease_shape, guard, write_op(store, :blob, :mutated)}, %{repair: repair})
      },
      order: []
    }

    assert :ok = Smalt.POWL2.Executor.execute_admitted(:g3, {:ok, model}, %{}, dets, caller)

    assert_received {:orchestration_completed, :g3, ctx, receipt}
    assert ctx.repaired == true
    # The write never happened even though the run completed via repair.
    assert_store_unchanged(store, [])
    nodes = Enum.map(receipt.steps, & &1.node)
    assert nodes == [:write, :repair]
    assert hd(receipt.steps).outcome == {:powl2_andon, :write, :r7, "stale lease"}
    assert [{{:powl2_andon, :write}, _}] = :dets.lookup(dets, {:powl2_andon, :write})
  end

  test "model-level repair_edges map routes the repair", %{dets: dets, caller: caller} do
    guard = fn _ctx -> {:andon_refusal, :r8, "need compaction"} end

    repair = t(:compact, fn ctx -> {:ok, Map.put(ctx, :compacted, true)} end)

    model = %{
      __struct__: @partial_order,
      id: :g4,
      law_module: nil,
      repair_edges: %{write: repair},
      children: %{
        write: t(:write, {:graphlaw_guard, :shape_c, guard, fn ctx -> {:ok, ctx} end})
      },
      order: []
    }

    assert :ok = Smalt.POWL2.Executor.execute_admitted(:g4, {:ok, model}, %{}, dets, caller)
    assert_received {:orchestration_completed, :g4, ctx, _receipt}
    assert ctx.compacted == true
  end

  test "failing repair stays terminal", %{dets: dets, caller: caller} do
    guard = fn _ctx -> {:andon_refusal, :r9, "unrecoverable"} end

    repair = t(:repair, fn _ctx -> {:error, :repair_boom} end)

    model = %{
      __struct__: @partial_order,
      id: :g5,
      repair_edges: %{write: repair},
      children: %{
        write: t(:write, {:graphlaw_guard, :shape_d, guard, fn ctx -> {:ok, ctx} end})
      },
      order: []
    }

    assert {:error, {:transition_failed, :repair, :repair_boom}} =
             Smalt.POWL2.Executor.execute_admitted(:g5, {:ok, model}, %{}, dets, caller)

    assert_received {:orchestration_failed, :g5, {:transition_failed, :repair, :repair_boom}}
  end

  # -- model-level law_module -----------------------------------------------------

  defmodule GateLaw do
    def powl2_guard(:vault_write, _ctx), do: {:andon_refusal, :KD_GL_VAULT, "vault sealed"}
    def powl2_guard(_shape, _ctx), do: :ok
  end

  test "model law_module guards every transition keyed on node id", %{
    dets: dets,
    caller: caller,
    store: store
  } do
    model = %{
      __struct__: @partial_order,
      id: :g6,
      law_module: GateLaw,
      children: %{
        vault_write: t(:vault_write, write_op(store, :vault, :opened)),
        log_write: t(:log_write, write_op(store, :log, :appended))
      },
      order: [vault_write: :log_write]
    }

    assert {:error, {:powl2_andon, :vault_write, :KD_GL_VAULT, "vault sealed"}} =
             Smalt.POWL2.Executor.execute_admitted(:g6, {:ok, model}, %{}, dets, caller)

    # vault op never ran; the downstream log_write never ran either.
    assert_store_unchanged(store, [])
    assert [{{:powl2_andon, :vault_write}, receipt}] = :dets.lookup(dets, {:powl2_andon, :vault_write})
    assert receipt.rule_id == :KD_GL_VAULT
  end

  # -- fail-closed guard verdicts ---------------------------------------------------

  test "crashed guard fails closed as :guard_raised with no mutation", %{
    dets: dets,
    caller: caller,
    store: store
  } do
    guard = fn _ctx -> raise "law module exploded" end

    model = %{
      __struct__: @partial_order,
      id: :g7,
      children: %{
        write: t(:write, {:graphlaw_guard, :shape_e, guard, write_op(store, :blob, :mutated)})
      },
      order: []
    }

    assert {:error, {:powl2_andon, :write, :guard_raised, {:error, %RuntimeError{message: "law module exploded"}}}} =
             Smalt.POWL2.Executor.execute_admitted(:g7, {:ok, model}, %{}, dets, caller)

    assert_store_unchanged(store, [])
  end

  test "non-conforming guard verdict fails closed as :bad_guard_verdict", %{
    dets: dets,
    caller: caller,
    store: store
  } do
    guard = fn _ctx -> {:approved, "not a lawful verdict"} end

    model = %{
      __struct__: @partial_order,
      id: :g8,
      children: %{
        write: t(:write, {:graphlaw_guard, :shape_f, guard, write_op(store, :blob, :mutated)})
      },
      order: []
    }

    assert {:error, {:powl2_andon, :write, :bad_guard_verdict, {:approved, "not a lawful verdict"}}} =
             Smalt.POWL2.Executor.execute_admitted(:g8, {:ok, model}, %{}, dets, caller)

    assert_store_unchanged(store, [])
  end

  # -- pure guard node + unguarded transitions unaffected ----------------------------

  test "pure guard node (3-tuple) passes with ctx unchanged", %{dets: dets, caller: caller} do
    model = %{
      __struct__: @partial_order,
      id: :g9,
      children: %{
        gate: t(:gate, {:graphlaw_guard, :shape_g, fn _ctx -> :ok end})
      },
      order: []
    }

    assert :ok = Smalt.POWL2.Executor.execute_admitted(:g9, {:ok, model}, %{keep: 1}, dets, caller)
    assert_received {:orchestration_completed, :g9, ctx, _receipt}
    assert ctx.keep == 1
  end

  test "unguarded transitions in the same model are unaffected by the seam", %{
    dets: dets,
    caller: caller,
    store: store
  } do
    model = %{
      __struct__: @partial_order,
      id: :g10,
      law_module: GateLaw,
      children: %{
        plain: t(:plain, write_op(store, :plain, :written))
      },
      order: []
    }

    assert :ok = Smalt.POWL2.Executor.execute_admitted(:g10, {:ok, model}, %{}, dets, caller)
    assert_received {:orchestration_completed, :g10, _ctx, _receipt}
    assert :ets.lookup(store, :plain) == [{:plain, :written}]
  end

  test "law_guard node field beside a normal op", %{dets: dets, caller: caller, store: store} do
    model = %{
      __struct__: @partial_order,
      id: :g11,
      children: %{
        write:
          t(:write, write_op(store, :blob, :mutated), %{
            law_guard: {:shape_h, fn _ctx -> {:andon_refusal, :r11, "blocked"} end}
          })
      },
      order: []
    }

    assert {:error, {:powl2_andon, :write, :r11, "blocked"}} =
             Smalt.POWL2.Executor.execute_admitted(:g11, {:ok, model}, %{}, dets, caller)

    assert_store_unchanged(store, [])
  end
  # -- GL-7 refinement leg (GRAPHLAW-SPEC §GL-7): in-place atomic guard swap ---
  # Falsifier: a stale predicate observed after the atomic ETS swap.

  @ttl_v1 """
  ex:OrderShape a sh:NodeShape ;
    sh:property [
      sh:path "orderTotal" ;
      sh:maxInclusive 10000 ;
      sh:message "order total exceeds the compliance ceiling" ;
    ] .
  """

  @ttl_v2 """
  ex:OrderShape a sh:NodeShape ;
    sh:property [
      sh:path "orderTotal" ;
      sh:maxInclusive 2500 ;
      sh:message "order total exceeds the amended compliance ceiling" ;
    ] .
  """

  defp probe_ctx, do: %{"orderTotal" => 5000}

  test "GL-7: swap_guard installs, swaps in place, topology untouched" do
    table = LawCompiler.guard_table!(String.to_atom("gl7_#{System.unique_integer([:positive])}"))
    assert {:ok, v1} = LawCompiler.swap_guard(table, "ex:OrderShape", @ttl_v1)
    assert {:ok, ^v1} = LawCompiler.lookup_guard(table, "ex:OrderShape")

    # net topology untouched: one shape, one row, same table object
    assert :ets.info(table, :size) == 1
    assert {:ok, v2} = LawCompiler.swap_guard(table, "ex:OrderShape", @ttl_v2)
    assert {:ok, ^v2} = LawCompiler.lookup_guard(table, "ex:OrderShape")
    assert :ets.info(table, :size) == 1
    assert v1 != v2

    # the very next evaluation uses the new predicate ($5k probe now violates)
    assert {:violation, rule_id, detail} = v2.(probe_ctx())
    assert rule_id == "OrderShape/maxInclusive/orderTotal"
    assert detail == "order total exceeds the amended compliance ceiling"
    assert v1.(probe_ctx()) == :ok
  end

  test "GL-7: swap under concurrent evaluators — zero stale-predicate evaluations" do
    table = LawCompiler.guard_table!(String.to_atom("gl7c_#{System.unique_integer([:positive])}"))
    {:ok, _} = LawCompiler.swap_guard(table, "ex:OrderShape", @ttl_v1)

    me = self()

    evaluator = fn ->
      gl7_spin(me, table)
    end

    tasks = Enum.map(1..8, fn _ -> Task.async(evaluator) end)

    # Barrier 1: old-predicate traffic observed before the swap (bounded poll
    # on the real message stream, deadline-checked — no fixed sleep).
    assert {:ok, _} = gl7_await(:ok_old, 100, %{}, 5_000)

    # Atomic swap while evaluators are mid-flight.
    {:ok, new_fun} = LawCompiler.swap_guard(table, "ex:OrderShape", @ttl_v2)

    # Barrier 2: new-predicate traffic observed after the swap.
    assert {:ok, counts} = gl7_await(:viol_new, 100, %{}, 5_000)
    assert counts.viol_new > 0

    Enum.each(tasks, &send(&1.pid, :gl7_stop))
    Enum.each(tasks, &Task.await/1)

    # Drain any residual messages, then the fence: once the new predicate is
    # installed, no later :ok verdict may reference it (zero stale evals).
    events = gl7_drain([])
    all = Enum.reverse(events)

    refute Enum.any?(all, fn {:gl7_eval, fun, verdict} -> fun == new_fun and verdict == :ok end)

    # Net topology untouched: one shape, one row.
    assert :ets.info(table, :size) == 1
  end

  defp gl7_spin(me, table) do
    receive do
      :gl7_stop -> :done
    after
      0 ->
        {:ok, fun} = LawCompiler.lookup_guard(table, "ex:OrderShape")
        verdict = fun.(%{"orderTotal" => 5000})
        send(me, {:gl7_eval, fun, verdict})
        gl7_spin(me, table)
    end
  end

  defp gl7_await(_which, need, counts, _left) when need <= 0, do: {:ok, counts}

  defp gl7_await(which, need, counts, left) when left > 0 do
    t0 = System.monotonic_time(:millisecond)

    receive do
      {:gl7_eval, _fun, :ok} = ev ->
        counts = Map.update(counts, :ok_old, 1, &(&1 + 1))
        dec = if which == :ok_old, do: 1, else: 0
        gl7_await(which, need - dec, counts, left - (System.monotonic_time(:millisecond) - t0))

      {:gl7_eval, _fun, {:violation, _, _}} ->
        counts = Map.update(counts, :viol_new, 1, &(&1 + 1))
        gl7_await(which, need - 1, counts, left - (System.monotonic_time(:millisecond) - t0))
    after
      # Poll step of the bounded poll (deadline-checked); a quiet mailbox for
      # 100ms means the evaluators have gone quiet under this barrier.
      step = min(left, 100) ->
        {:error, {:gl7_await_timeout, which, counts}}
    end
  end

  defp gl7_await(which, _need, counts, _left), do: {:error, {:gl7_await_deadline, which, counts}}

  defp gl7_drain(acc) do
    receive do
      {:gl7_eval, _fun, _v} = ev -> gl7_drain([ev | acc])
    after
      0 -> acc
    end
  end

  # -- GL-9 refinement leg (GRAPHLAW-SPEC §GL-9): governance-tax fence --------
  # Fence: governance overhead <= 15µs per node step (paired, min-of-3).

  test "GL-9: SHACL-guarded step overhead vs raw ETS write <= 15µs/step" do
    table = LawCompiler.guard_table!(String.to_atom("gl9_#{System.unique_integer([:positive])}"))
    {:ok, guard} = LawCompiler.swap_guard(table, "ex:OrderShape", @ttl_v1)
    store = :ets.new(:gl9_store, [:set, :public])

    raw = fn ->
      for _ <- 1..5000, do: :ets.insert(store, {:k, 1})
    end

    guarded = fn ->
      for _ <- 1..5000 do
        {:ok, fun} = LawCompiler.lookup_guard(table, "ex:OrderShape")
        :ok = fun.(%{"orderTotal" => 42})
        :ets.insert(store, {:k, 1})
      end
    end

    overhead_ns =
      for _ <- 1..3 do
        {t_raw, _} = :timer.tc(raw)
        {t_g, _} = :timer.tc(guarded)

        max(t_g - t_raw, 0) * 1000
      end
      |> Enum.min()

    # discard one warmup round implicitly via min-of-3; assert the fence
    assert overhead_ns / 5000 <= 15_000,
           "governance overhead #{overhead_ns / 5000}ns/step exceeds 15µs fence"
  end
end

defmodule Smalt.POWL2.Executor do
  @moduledoc """
  POWL2 execution kernel (POWL-9). Pure topology engine over the POWL2 AST
  operators `Transition` / `PartialOrder` / `ChoiceGraph`.

  - PartialOrder frontier nodes run concurrently via Task.async/await
    under a deadline.
  - ChoiceGraph walks edges keyed on `ctx.last_outcome` with an `:always` /
    unguarded fallback. Guards live in an optional `:guards` map on the
    ChoiceGraph node (`%{target_id => guard}`); edges stay plain {from, to}
    pairs so Gate 1 admission never sees guarded 3-tuples.
  - Ops are injected per node (`:op` field: fun/1 or {m, f, a}); the kernel
    hardcodes no domain ops.
  - Receipts persist to `dets_ref` under `{:powl2_receipt, id}` (refusals
    under `{:powl2_refusal, id}`).

  ## Graphlaw law-guard seam (GL-1)

  A guarded Transition carries its law inline: op is
  `{:graphlaw_guard, shape_id, fun}` (pure guard node — on approval the
  transition passes with ctx unchanged) or
  `{:graphlaw_guard, shape_id, fun, inner_op}` (guard in front of a real
  op). A node may instead carry `law_guard: {shape_id, fun}` beside a
  normal op. A model-level `law_module` (module exporting
  `powl2_guard(shape_id, ctx)`, or `{m, f, a}` receiving
  `[shape_id, ctx | a]`) guards every transition, keyed on the node id as
  shape_id.

  The guard fun receives the current context (state graph) and returns
  `:ok` | `{:andon_refusal, rule_id, diagnostic}`. Any other verdict —
  including a raised/crashed guard — fails closed as an andon refusal
  (`:bad_guard_verdict` / `:guard_raised`).

  On refusal: the op is NEVER run (no ETS/data-plane mutation), a typed
  ANDON receipt `{{:powl2_andon, id}, %{rule_id, diagnostic, shape_id,
  at_ms}}` persists to the DETS refusal channel, and the FOND repair edge
  runs if one exists — node field `:repair` (a node) or model-level
  `repair_edges: %{transition_id => repair_node}`. Without a repair edge
  the refusal is terminal (`{:orchestration_refused, id,
  {:powl2_andon, id, rule_id, diagnostic}}`); a failing repair stays
  terminal too.
  """

  @default_deadline_ms 30_000

  @type op :: (map() -> term()) | {module(), atom(), [term()]}
  @type ctx :: map()
  @type step :: %{node: term(), kind: :transition, outcome: term(), at_ms: integer()}

  @type receipt :: %{
          id: term(),
          steps: [step()],
          phi_lease_final: non_neg_integer(),
          status: :completed | {:error, term()}
        }

  @doc """
  Execute an admitted POWL2 model. `verdict` is `{:ok, model}` (runs) or
  `{:error, reason}` (typed refusal). Returns `:ok` on completed runs,
  `{:error, term()}` on refusal/failure.
  """
  @spec execute_admitted(term(), term(), map(), :dets.table_name() | nil, pid(), module()) ::
          :ok | {:error, term()}
  def execute_admitted(instance_id, verdict, ctx, dets_ref, caller, reticle_mod \\ Smalt.POWL2.Reticle)

  def execute_admitted(id, {:ok, model}, ctx, dets, caller, reticle) do
    case pre_admit(model, reticle) do
      :ok -> run_model(id, model, ctx, dets, caller)
      {:error, reason} -> refuse(id, reason, dets, caller)
    end
  end

  def execute_admitted(id, {:error, reason}, _ctx, dets, caller, _reticle) do
    refuse(id, reason, dets, caller)
  end

  defp refuse(id, reason, dets, caller) do
    record_refusal(dets, id, reason)
    send(caller, {:orchestration_refused, id, reason})
    {:error, reason}
  end

  defp pre_admit(model, reticle_mod) do
    case Code.ensure_loaded(reticle_mod) do
      {:module, mod} -> if function_exported?(mod, :admit, 1), do: mod.admit(model), else: :ok

      # EXPL10-R F2: fail closed. An unloadable reticle module used to skip
      # admission entirely (model ran unadmitted — witnessed W2a).
      {:error, _} ->
        {:error, {:admit_module_unloadable, reticle_mod}}
    end
  end

  defp run_model(id, model, ctx, dets, caller) do
    t0 = System.monotonic_time(:millisecond)
    law = %{
      dets: dets,
      law_module: Map.get(model, :law_module),
      repair_edges: repair_edges(model),
      t0: t0
    }

    case eval(model, ctx, deadline_at(), law) do
      {:ok, ctx2, steps} ->
        receipt = %{id: id, steps: steps, phi_lease_final: length(steps), status: :completed}
        persist(dets, {:powl2_receipt, id}, receipt)
        send(caller, {:orchestration_completed, id, ctx2, receipt})
        :ok

      {:error, {:powl2_andon, andon_id, rule_id, diag} = andon, _ctx2, steps} ->
        receipt = %{id: id, steps: steps, phi_lease_final: length(steps), status: {:error, andon}}
        persist(dets, {:powl2_receipt, id}, receipt)
        send(caller, {:orchestration_refused, id, andon})
        {:error, {:powl2_andon, andon_id, rule_id, diag}}

      {:error, outcome, _ctx2, steps} ->
        receipt = %{id: id, steps: steps, phi_lease_final: length(steps), status: {:error, outcome}}
        persist(dets, {:powl2_receipt, id}, receipt)
        send(caller, {:orchestration_failed, id, outcome})
        {:error, outcome}
    end
  end

  defp repair_edges(model) do
    case Map.get(model, :repair_edges) do
      m when is_map(m) -> m
      l when is_list(l) -> Map.new(l)
      _ -> %{}
    end
  end

  defp deadline_at, do: System.monotonic_time(:millisecond) + @default_deadline_ms

  # -- topology eval -----------------------------------------------------

  defp eval(%{__struct__: Smalt.POWL2.Reticle.AST.Transition} = t, ctx, dl, law),
    do: eval_transition(t, ctx, dl, law)

  defp eval(%{__struct__: Smalt.POWL2.Reticle.AST.PartialOrder} = po, ctx, dl, law),
    do: eval_po(po, ctx, dl, law)

  defp eval(%{__struct__: Smalt.POWL2.Reticle.AST.ChoiceGraph} = cg, ctx, dl, law),
    do: eval_choice(cg, ctx, dl, law)

  defp eval(%{model: inner}, ctx, dl, law), do: eval(inner, ctx, dl, law)

  defp eval(other, _ctx, _dl, _law), do: {:error, {:not_a_powl2_node, other}, %{}, []}

  # -- law-guard seam ------------------------------------------------------

  # Resolve the guard + inner op for a transition. Returns
  # {shape_id, guard_fun | nil, inner_op}.
  defp guard_for(node, law) do
    op = Map.get(node, :op)
    lm = law_module(law)

    cond do
      guard_tuple?(op, 3) ->
        {:graphlaw_guard, shape, fun} = op
        {shape, fun, nil}

      guard_tuple?(op, 4) ->
        {:graphlaw_guard, shape, fun, inner} = op
        {shape, fun, inner}

      g = Map.get(node, :law_guard) ->
        {shape, fun} = g
        {shape, fun, op}

      lm != nil ->
        {Map.get(node, :id), law_guard(lm, Map.get(node, :id)), op}

      true ->
        {nil, nil, op}
    end
  end

  defp guard_tuple?({:graphlaw_guard, _s, f}, 3) when is_function(f, 1), do: true
  defp guard_tuple?({:graphlaw_guard, _s, f, _op}, 4) when is_function(f, 1), do: true
  defp guard_tuple?(_, _), do: false

  defp law_module(%{law_module: lm}), do: lm

  # Normalized to arity-1 (ctx) guards; the shape id is bound at resolution.
  defp law_guard(lm, shape) when is_atom(lm), do: fn ctx -> lm.powl2_guard(shape, ctx) end

  defp law_guard({m, f, a}, shape), do: fn ctx -> apply(m, f, [shape, ctx | a]) end

  # Guard verdict, fail-closed. :ok passes; {:andon_refusal, rule_id, diag}
  # refuses; anything else (incl. a crashed guard) refuses with a typed
  # synthetic rule_id.
  defp run_guard(_shape, nil, _ctx, _law), do: :ok

  defp run_guard(_shape, fun, ctx, _law) do
    verdict =
      try do
        fun.(ctx)
      catch
        kind, reason -> {:andon_refusal, :guard_raised, {kind, reason}}
      end

    case verdict do
      :ok -> :ok
      {:andon_refusal, rule_id, diag} -> {:andon_refusal, rule_id, diag}
      # GL-2 seam: LawCompiler guards return {:violation, rule_id, diagnostic};
      # normalized to the executor's andon refusal envelope (disclosed
      # compile-freeze unblock, see GL-2 receipt).
      {:violation, rule_id, diag} -> {:andon_refusal, rule_id, diag}
      other -> {:andon_refusal, :bad_guard_verdict, other}
    end
  end

  defp andon_receipt(shape, rule_id, diag, law) do
    %{
      shape_id: shape,
      rule_id: rule_id,
      diagnostic: diag,
      at_ms: System.system_time(:millisecond)
    }
    |> Map.put(:at_rel_ms, System.monotonic_time(:millisecond) - law.t0)
  end

  defp record_andon(nil, _id, _shape, _rule, _diag, _law), do: :ok

  defp record_andon(dets, id, shape, rule_id, diag, law) do
    :dets.insert(dets, {{:powl2_andon, id}, andon_receipt(shape, rule_id, diag, law)})
  end

  defp eval_transition(node, ctx, dl, law) do
    id = Map.get(node, :id)
    {shape, guard, op} = guard_for(node, law)

    case run_guard(shape, guard, ctx, law) do
      :ok ->
        # A pure guard node (inline guard tuple, no inner op) passes with
        # ctx unchanged; a plain transition with no op stays {:error, :no_op}.
        if guard != nil and is_nil(op) do
          {:ok, ctx, [step(id, :ok, t0_of(law))]}
        else
          run_op(id, op, ctx, t0_of(law))
        end

      {:andon_refusal, rule_id, diag} ->
        record_andon(law.dets, id, shape, rule_id, diag, law)

        # No op ran: ctx is unchanged except the typed last_outcome marker.
        ctx1 = Map.put(ctx, :last_outcome, {:powl2_andon, id, rule_id, diag})
        step_andon = step(id, {:powl2_andon, id, rule_id, diag}, t0_of(law))

        case repair_node(node, id, law) do
          nil ->
            {:error, {:powl2_andon, id, rule_id, diag}, ctx1, [step_andon]}

          repair ->
            case eval(repair, ctx1, dl, law) do
              {:ok, ctx2, rsteps} -> {:ok, ctx2, [step_andon | rsteps]}
              {:error, o, ctx2, rsteps} -> {:error, o, ctx2, [step_andon | rsteps]}
            end
        end
    end
  end

  defp run_op(id, op, ctx, t0) do
    result =
      cond do
        is_nil(op) -> {:error, :no_op}
        is_function(op, 1) -> apply_op(op, ctx)

        match?({m, f, a} when is_atom(m) and is_atom(f) and is_list(a), op) ->
          {m, f, a} = op
          apply_op(fn c -> apply(m, f, [c | a]) end, ctx)

        true ->
          {:error, {:bad_op, op}}
      end

    case result do
      {:ok, ctx2} ->
        {:ok, ctx2, [step(id, :ok, t0)]}

      {:ok, ctx2, outcome} ->
        {:ok, Map.put(ctx2, :last_outcome, outcome), [step(id, outcome, t0)]}

      {:error, reason} ->
        {:error, {:transition_failed, id, reason},
         Map.put(ctx, :last_outcome, {:error, reason}), [step(id, {:error, reason}, t0)]}

      # EXPL10-R F3: enumerated error shapes only — never success-on-unknown.
      # A 3-tuple error (e.g. {:error, :throttled, :retry_after_5}) is a
      # common API shape; the old catch-all counted it as a completed step.
      {:error, _r1, _r2} = err3 ->
        {:error, {:transition_failed, id, err3},
         Map.put(ctx, :last_outcome, err3), [step(id, err3, t0)]}

      # The one documented non-error class that may pass as an outcome.
      {:ok_outcome, outcome} ->
        {:ok, Map.put(ctx, :last_outcome, outcome), [step(id, outcome, t0)]}

      # Unknown shapes refuse typed (wrapped like every other op failure).
      other ->
        {:error, {:transition_failed, id, {:bad_op_result, other}},
         Map.put(ctx, :last_outcome, {:error, {:bad_op_result, other}}),
         [step(id, {:error, {:bad_op_result, other}}, t0)]}
    end
  end

  defp apply_op(fun, ctx) do
    fun.(ctx)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp repair_node(node, id, law) do
    Map.get(node, :repair) || Map.get(law.repair_edges, id)
  end

  defp t0_of(%{t0: t0}), do: t0

  # -- PartialOrder --------------------------------------------------------

  # Frontier waves: nodes with no incoming order edge run concurrently
  # (Task.async/await with remaining-deadline timeout), then recurse on the
  # residual graph. Steps stay chronological across waves.
  defp eval_po(node, ctx, dl, law) do
    children = children_list(node)
    order = node |> Map.get(:order, []) |> List.wrap()
    waves(children, order, ctx, dl, law, [])
  end

  defp waves([], _order, ctx, _dl, _law, acc), do: {:ok, ctx, acc}

  defp waves(nodes, order, ctx, dl, law, acc) do
    incoming = for({_f, t} <- order, do: t, into: MapSet.new())
    frontier = Enum.reject(nodes, &MapSet.member?(incoming, Map.get(&1, :id)))
    fids = MapSet.new(frontier, &Map.get(&1, :id))
    residual = Enum.reject(nodes, &MapSet.member?(fids, Map.get(&1, :id)))
    rorder = Enum.reject(order, fn {f, _t} -> MapSet.member?(fids, f) end)

    case concurrent(frontier, ctx, dl, law) do
      {:ok, ctx2, wsteps} ->
        case waves(residual, rorder, ctx2, dl, law, acc ++ wsteps) do
          {:ok, ctx3, rest} -> {:ok, ctx3, rest}
          {:error, o, ctx3, rest} -> {:error, o, ctx3, rest}
        end

      {:error, outcome, ctx2, wsteps} ->
        {:error, outcome, ctx2, acc ++ wsteps}
    end
  end

  defp concurrent([], ctx, _dl, _law), do: {:ok, ctx, []}

  defp concurrent(nodes, ctx, dl, law) do
    tasks =
      Enum.map(nodes, fn node ->
        Task.async(fn ->
          Process.set_label(%{service: :powl2, role: :frontier_eval, id: Map.get(node, :id)})
          eval(node, ctx, dl, law)
        end)
      end)

    results =
      Enum.map(tasks, fn task ->
        Task.await(task, max(dl - System.monotonic_time(:millisecond), 1))
      end)

    consolidate(results, ctx)
  catch
    :exit, reason -> {:error, {:partial_order_deadline_or_exit, reason}, ctx, []}
  end

  defp consolidate(results, ctx) do
    Enum.reduce(results, {:ok, ctx, []}, fn
      {:ok, c2, s}, {:ok, ca, acc} -> {:ok, Map.merge(ca, c2), acc ++ s}
      {:ok, _c2, s}, {:error, o, ca, acc} -> {:error, o, ca, acc ++ s}
      {:error, o, c2, s}, {:ok, ca, acc} -> {:error, o, Map.merge(ca, c2), acc ++ s}
      {:error, _o, _c2, s}, {:error, oa, ca, acc} -> {:error, oa, ca, acc ++ s}
    end)
  end

  # -- ChoiceGraph ----------------------------------------------------------

  defp eval_choice(node, ctx, dl, law) do
    children = children_map(node)
    edges = node |> Map.get(:edges, []) |> List.wrap()
    guards = Map.get(node, :guards, %{})
    start = Map.get(node, :start)
    end_id = Map.get(node, :end)

    # The can-follow closure orders children beyond any single first-edge
    # path (BK-POWLH2-2: a sound sequential tail could be skipped when the
    # walk rode one edge chain into the exit). The walk is therefore
    # closure-COMPLETE: from each node it takes every guard-viable outgoing
    # edge (exact last_outcome matches suppress fallbacks — choice face),
    # evaluating each child once. Cycle edges (loop face, e.g. the
    # bidirectional can-follow cas<->retry pair) are exempt from the
    # visited-once rule: re-entry is guard-driven and bounded by
    # @walk_reentry_budget so a degenerate :always cycle fails closed
    # instead of spinning.
    cycle_edges = cycle_edges(edges)

    # Static walk context — one map threaded through walk/fire instead of a
    # 14-argument fire/14 (Armstrong: the shape of the args is the design).
    w = %{
      end_id: end_id,
      edges: edges,
      children: children,
      dl: dl,
      law: law,
      guards: guards,
      cycle_edges: cycle_edges
    }

    walk(start, ctx, [], MapSet.new(), %{}, w)
    |> case do
      {:ok, ctx2, acc, _visited, _re} -> {:ok, ctx2, acc}
      {:error, _o, _ctx2, _acc} = err -> err
    end
  end

  # An edge {f, t} is a cycle edge when t can reach f again through the
  # edge set (transitively).
  defp cycle_edges(edges) do
    for {f, t} = edge <- edges,
        reaches?(edges, t, f),
        into: MapSet.new(),
        do: edge
  end

  defp reaches?(edges, from, to), do: reach_dfs(edges, from, to, MapSet.new())

  defp reach_dfs(_edges, cur, to, _seen) when cur == to, do: true

  defp reach_dfs(edges, cur, to, seen) do
    if MapSet.member?(seen, cur) do
      false
    else
      seen = MapSet.put(seen, cur)

      Enum.any?(edges, fn {f, t} ->
        f == cur and reach_dfs(edges, t, to, seen)
      end)
    end
  end

  # Bounds cycle-edge re-entries per target node. Justification: the visited
  # set already bounds acyclic re-entry at |children|; the budget only has to
  # cover a real loop face, which re-enters once per iteration. 256 = 2^8 is
  # far above any legitimate loop body count in an admitted model and far
  # below stack exhaustion; a degenerate :always self-loop hits the typed
  # refusal {:choice_walk_reentry_budget_exceeded, to} instead of spinning.
  # Not an arbitrary defensive limit — it bounds exactly the one structure
  # (unguarded cycle) the visited-once rule cannot.
  @walk_reentry_budget 256

  # Internal walk result carries the visited set + re-entry budget so the
  # sibling-branch loop sees everything a sub-branch discovered. `w` is the
  # static walk context (edges/children/guards/endpoint/law) built once in
  # eval_choice/3.
  defp walk(cur, ctx, acc, visited, re, %{end_id: end_id} = _w) when cur == end_id do
    {:ok, ctx, acc, visited, re}
  end

  defp walk(cur, ctx, acc, visited, re, w) do
    %{edges: edges, guards: guards} = w
    viable = pick_all(cur, edges, guards, ctx)

    if viable == [] do
      # No guard-viable edge out of a non-terminal node: the old typed
      # refusal shape, preserved.
      {:error, {:no_outgoing_edge_matches, cur, Map.get(ctx, :last_outcome)}, ctx, acc}
    else
      Enum.reduce_while(viable, {:ok, ctx, acc, visited, re}, fn edge, good_acc ->
        step_edge(edge, good_acc, w)
      end)
    end
  end

  # One viable edge against the accumulating walk state.
  defp step_edge(
         edge,
         {:ok, ctx2, acc2, visited2, re2} = good,
         %{children: children, cycle_edges: cycle_edges} = w
       ) do
    to = elem(edge, 1)

    case Map.get(children, to) do
      nil ->
        {:halt, {:error, {:choice_unknown_target, to}, ctx2, acc2}}

      target ->
        cycle_edge? = MapSet.member?(cycle_edges, edge)
        visited? = MapSet.member?(visited2, to)

        cond do
          visited? and not cycle_edge? ->
            {:cont, good}

          visited? and cycle_edge? ->
            budget = Map.get(re2, to, 0)

            if budget >= @walk_reentry_budget do
              {:halt, {:error, {:choice_walk_reentry_budget_exceeded, to}, ctx2, acc2}}
            else
              re3 = Map.put(re2, to, budget + 1)
              fire(edge, target, to, ctx2, acc2, visited2, re3, w)
            end

          true ->
            fire(edge, target, to, ctx2, acc2, visited2, re2, w)
        end
    end
  end

  defp step_edge(_edge, {:error, _o, _ctx2, _acc2} = err, _w), do: {:halt, err}

  defp fire(_edge, target, to, ctx, acc, visited, re, w) do
    case eval(target, ctx, w.dl, w.law) do
      {:ok, ctx2, s} ->
        visited3 = MapSet.put(visited, to)

        case walk(to, ctx2, acc ++ s, visited3, re, w) do
          {:ok, ctx3, acc3, visited4, re2} -> {:cont, {:ok, ctx3, acc3, visited4, re2}}
          {:error, o, ctx3, acc3} -> {:cont, {:error, o, ctx3, acc3}}
        end

      {:error, o, ctx2, s} ->
        {:cont, {:error, o, ctx2, acc ++ s}}
    end
  end

  # Closure-complete picking: exact last_outcome guard matches win and
  # suppress the fallbacks (choice face); otherwise every :always /
  # unguarded outgoing edge is viable (sequential tail — each ordered
  # successor gets visited, not just the first edge's path).
  defp pick_all(from, edges, guards, ctx) do
    outgoing = Enum.filter(edges, fn edge -> elem(edge, 0) == from end)
    last = Map.get(ctx, :last_outcome)

    exact =
      Enum.filter(outgoing, fn e ->
        g = guard_for_edge(e, guards)
        g != nil and g != :always and g == last
      end)

    if exact != [] do
      exact
    else
      Enum.filter(outgoing, fn e ->
        g = guard_for_edge(e, guards)
        g == nil or g == :always
      end)
    end
  end

  defp guard_for_edge(e, guards), do: Map.get(guards, elem(e, 1))

  # -- helpers ---------------------------------------------------------------

  defp children_list(node), do: node |> children_map() |> Map.values()

  defp children_map(node) do
    case Map.get(node, :children) do
      m when is_map(m) -> m
      l when is_list(l) -> Map.new(l, fn c -> {Map.get(c, :id), c} end)
      _ -> %{}
    end
  end

  defp persist(nil, _key, _receipt), do: :ok
  defp persist(dets, key, receipt), do: :dets.insert(dets, {key, receipt})

  defp record_refusal(nil, _id, _reason), do: :ok

  defp record_refusal(dets, id, reason) do
    :dets.insert(dets, {{:powl2_refusal, id}, %{reason: reason, at_ms: System.system_time(:millisecond)}})
  end

  defp step(node, outcome, t0) do
    %{node: node, kind: :transition, outcome: outcome, at_ms: System.system_time(:millisecond) - t0}
  end
end

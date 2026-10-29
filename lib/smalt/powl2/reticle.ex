defmodule Smalt.POWL2.Reticle do
  @moduledoc """
  Gate-1 admission for POWL2 AST models (reticle).

  `admit/1` returns `:ok` for a well-formed model or
  `{:error, {:shacl_violation, message}}` for a typed refusal. Structural
  laws enforced here:

  - `Transition` carries a non-nil `:id` and `:label`.
  - `PartialOrder` order pairs must reference declared children, be
    irreflexive, and be acyclic — cycles are detected through the
    transitive closure (a→b, b→c, c→b is refused even though no direct
    2-cycle edge pair appears twice) using a seen-set BFS that terminates
    on cyclic input by exhaustion, never a clock.
  - `ChoiceGraph` is SESE-checked: no edge into `start`, no edge out of
    `end`, `start`/`end` declared as children, and every child must lie on
    a start→end path (reachable from start AND able to reach end);
    a violating child is named in a "trapped" refusal.

  Children are maps id→node; edges are plain `{from, to}` pairs; guards
  live in an optional `:guards` map on the ChoiceGraph, never inside
  `edges` (the SESE checks require plain pairs).

  The AST structs are defined here (`Smalt.POWL2.Reticle.AST.*`) and are
  dispatched by the executor via `__struct__` name. `Transition` carries
  an `:op` field (default `:tau`) so `Smalt.POWL2.Executor` can read the
  injected operation with `Map.get(node, :op)`.
  """

  defmodule AST do
    defmodule Transition do
      @moduledoc false

      # GL-KILL F1: the law-seam fields are declared so typed struct
      # construction (struct/2, update syntax) PRESERVES them — previously
      # struct/2 silently dropped unknown keys and a law_guard set through
      # the documented path vanished, leaving the op unguarded and mutating.
      # `law_guard` is `{shape_id, guard_fun}` (or `{m, f, a}`); `repair` is
      # the node-local repair override the executor reads via Map.get.
      defstruct [:id, :label, op: :tau, law_guard: nil, repair: nil]
    end

    defmodule PartialOrder do
      @moduledoc false

      # Model-level law surface (GL-KILL F1): `law_module` names a module (or
      # `{m, f, a}`) exporting the guard/repair lookups; `repair_edges` maps
      # transition id → repair node. Defaults keep unguarded models lawful.
      defstruct children: %{}, order: [], law_module: nil, repair_edges: %{}
    end

    defmodule ChoiceGraph do
      @moduledoc false
      defstruct children: %{}, start: nil, end: nil, edges: [], guards: %{},
                law_module: nil, repair_edges: %{}
    end
  end

  alias AST.{ChoiceGraph, PartialOrder, Transition}

  @spec admit(term()) :: :ok | {:error, {:shacl_violation, String.t()}}
  def admit(model)

  def admit(%Transition{id: nil, label: _}),
    do: {:error, {:shacl_violation, "transition missing id"}}

  def admit(%Transition{id: _, label: nil}),
    do: {:error, {:shacl_violation, "transition missing label"}}

  def admit(%Transition{id: _, label: _, op: _}), do: :ok

  def admit(%PartialOrder{} = po), do: admit_partial_order(po)

  def admit(%ChoiceGraph{} = cg), do: admit_choice_graph(cg)

  def admit(other),
    do: {:error, {:shacl_violation, "not a POWL2 AST node: #{inspect(other)}"}}

  # -- PartialOrder ----------------------------------------------------------

  defp admit_partial_order(%PartialOrder{children: children, order: order}) do
    with :ok <- admit_children(children),
         :ok <- check_order_bounds(children, order) do
      check_acyclic(children, order)
    end
  end

  defp admit_children(children) when is_map(children) do
    children
    |> Enum.reduce_while(:ok, fn {_id, node}, :ok ->
      case admit(node) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_order_bounds(children, order) do
    bad =
      Enum.find(order, fn {from, to} ->
        not Map.has_key?(children, from) or not Map.has_key?(children, to)
      end)

    case bad do
      nil -> :ok
      {from, to} -> {:error, {:shacl_violation, "order pair {#{inspect(from)}, #{inspect(to)}} outside children"}}
    end
  end

  defp check_acyclic(_children, order) do
    adj = Enum.reduce(order, %{}, fn {f, t}, acc -> Map.update(acc, f, MapSet.new([t]), &MapSet.put(&1, t)) end)

    with :ok <- check_irreflexive(order),
         :ok <- check_cycles(adj, order), do: :ok
  end

  defp check_irreflexive(order) do
    case Enum.find(order, fn {f, t} -> f == t end) do
      nil -> :ok
      {f, _} -> {:error, {:shacl_violation, "order must be irreflexive: #{inspect(f)} precedes itself"}}
    end
  end

  defp check_cycles(adj, order) do
    order
    |> Enum.map(fn {f, _} -> f end)
    |> MapSet.new()
    |> Enum.reduce_while(:ok, fn node, :ok ->
      if reaches?(adj, node, node) do
        {:halt, {:error, {:shacl_violation, "cycle in partial order through #{inspect(node)}"}}}
      else
        {:cont, :ok}
      end
    end)
  end

  # Seen-set BFS over the transitive closure: does `target` reach `target`
  # (i.e. is `node` on a cycle)? Terminates on cyclic input via the seen set.
  defp reaches?(adj, node, target), do: do_reach(adj, [node], target, MapSet.new([node]))

  defp do_reach(_adj, [], _target, _seen), do: false

  defp do_reach(adj, [h | rest], target, seen) do
    next =
      adj
      |> Map.get(h, MapSet.new())
      |> Enum.reject(&MapSet.member?(seen, &1))

    if MapSet.member?(adj |> Map.get(h, MapSet.new()), target) do
      true
    else
      do_reach(adj, rest ++ next, target, Enum.into(next, seen))
    end
  end

  # -- ChoiceGraph (SESE) ----------------------------------------------------

  defp admit_choice_graph(%ChoiceGraph{children: children, start: start, end: fin, edges: edges}) do
    with :ok <- admit_children(children),
         :ok <- check_delimiters(children, start, fin),
         :ok <- check_no_edge_into_start(edges, start),
         :ok <- check_no_edge_out_of_end(edges, fin) do
      check_all_on_path(children, start, fin, edges)
    end
  end

  defp check_delimiters(children, start, fin) do
    cond do
      not Map.has_key?(children, start) ->
        {:error, {:shacl_violation, "choice start #{inspect(start)} not present as child"}}

      not Map.has_key?(children, fin) ->
        {:error, {:shacl_violation, "choice end #{inspect(fin)} not present as child"}}

      true ->
        :ok
    end
  end

  defp check_no_edge_into_start(edges, start) do
    if Enum.any?(edges, fn {_f, t} -> t == start end) do
      {:error, {:shacl_violation, "choice graph has edge into start"}}
    else
      :ok
    end
  end

  defp check_no_edge_out_of_end(edges, fin) do
    if Enum.any?(edges, fn {f, _t} -> f == fin end) do
      {:error, {:shacl_violation, "choice graph has edge out of end"}}
    else
      :ok
    end
  end

  defp check_all_on_path(children, start, fin, edges) do
    adj = adjacency(edges)
    radj = adjacency(Enum.map(edges, fn {f, t} -> {t, f} end))

    fwd = reachable(adj, start)
    bwd = reachable(radj, fin)

    trapped =
      Enum.find(children, fn {id, _node} ->
        id != start and id != fin and not (MapSet.member?(fwd, id) and MapSet.member?(bwd, id))
      end)

    case trapped do
      nil ->
        :ok

      {id, _} ->
        {:error,
         {:shacl_violation,
          "trapped child #{inspect(id)}: not on any start→end path"}}
    end
  end

  defp adjacency(pairs) do
    Enum.reduce(pairs, %{}, fn {f, t}, acc -> Map.update(acc, f, MapSet.new([t]), &MapSet.put(&1, t)) end)
  end

  # Transitive closure from `root`; terminates on cyclic graphs via seen set.
  defp reachable(adj, root), do: closure(adj, [root], MapSet.new([root]), MapSet.new([root]))

  defp closure(_adj, [], _frontier, seen), do: seen

  defp closure(adj, [h | rest], _frontier, seen) do
    next = adj |> Map.get(h, MapSet.new()) |> Enum.reject(&MapSet.member?(seen, &1))
    seen = Enum.into(next, seen)
    closure(adj, rest ++ next, nil, seen)
  end
end

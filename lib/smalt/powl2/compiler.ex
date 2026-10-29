defmodule Smalt.Powl2.Compiler do
  @moduledoc """
  POWL 2.0 Algorithm 3 (WO POWL-4): recursive top-down conversion of a
  safe sound WF-net into the `Smalt.Powl2` AST.

  Precondition (machine-checked as of BK-POWLH2): the input is a SAFE
  SOUND WF-net — `Smalt.Powl2.wf_net?/1` shape-gates it, and soundness
  (sink reachable from the source; every transition enabled at some
  reachable marking) is enforced by the typed refusal `:net_not_sound`.
  Previously this was prose only, so an unsound "loop" net (e.g.
  `source->a->pb->b->sink, b->pl->a`, where `a` has two input places and
  can never fire) compiled silently to an edge-less ChoiceGraph — the
  HIGH-2 loop mis-compile.

  1-safeness boundary (typed as of BK-1SAFE — NOT a machine-checked
  refusal, deliberately): the reachability engine is SET-semantics by
  representation — markings are `MapSet`s of place ids, so a place
  holding 2+ tokens is unrepresentable; `fire/3` collapses multiplicity
  on union. The runtime executor (`Smalt.POWL2.Executor`) is a pure
  topology engine over the AST (ChoiceGraph walk keyed on
  `ctx.last_outcome`), token-agnostic: no token game ever runs against
  the compiled model. 1-safeness is therefore not load-bearing here, and
  a multiset token-game gate is deliberately absent: it would refuse the
  canonical loop nets the HIGH-2 court pins as the loop representation
  (a redo-loop net re-feeds the sink place each iteration, so it is not
  1-safe under multiset semantics, yet it compiles to the bidirectional
  can-follow loop face the AST is defined to carry). A net that is not
  1-safe under multiset semantics is analyzed under the engine's set
  semantics and compiles consistently with that analysis; consumers
  wanting multiset-truth semantics must pre-gate upstream. The marking
  enumeration is bounded once per `compile/2`
  with a safety cap (`:max_markings`, default 50 000) — exceeding it is
  the typed refusal `{:error, :net_not_safe}`.

  Relation matrix (`relations/3`), for distinct transitions x, y:

    - `:lt` — x can precede y, never the reverse (strict order);
    - `:gt` — the reverse;
    - `:co` — each can precede the other;
    - `:conflict` — neither can precede the other (choice).

  A `:co` pair with flow paths BOTH ways is a LOOP pair
  (`loop_pair?/4`): a partial order cannot express it (it would hide
  the loop as concurrency).

  Algorithm:

    1. single transition -> `Smalt.Powl2.Transition`;
    2. `partition_mg/3` (maximal groups: merge iff `:co` non-loop) +
       `conflict_hiding?/4` -> `Smalt.Powl2.PartialOrder` over the
       recursively compiled blocks (a residual single block is a pure
       concurrency cluster -> flat PartialOrder);
    3. else `partition_sm/3` (state-machine classes: merge on conflict,
       loop pair, or shared input place) + `concurrency_hiding?/3` ->
       `Smalt.Powl2.ChoiceGraph` (residual single block -> flat
       ChoiceGraph with can-follow edges between every ordered pair);
    4. else `{:error, :non_separable_fallthrough}` — the handle
       signature: a pair that is concurrent AND conflicting
       (cross-cutting concurrency and choice) is inexpressible.

  `structural_progress?/2` guards recursion: every block must be a
  non-empty PROPER subset of the fragment (no whole-net-isomorphic
  projection is ever recursed into).
  """

  alias Smalt.Powl2
  alias Smalt.Powl2.{ChoiceGraph, GraphCompat, PartialOrder, Transition}

  @default_max_markings 50_000

  @type relation_matrix :: %{{Powl2.node_id(), Powl2.node_id()} => Powl2.rel()}

  @type marking :: MapSet.t(Powl2.node_id())

  @type ctx :: %{
          enabled: %{marking() => [Powl2.node_id()]},
          next: %{marking() => MapSet.t(marking())},
          fired: %{Powl2.node_id() => MapSet.t(marking())}
        }

  @type compile_err ::
          :not_a_wf_net
          | :empty_net
          | :net_not_safe
          | :non_separable_fallthrough
          | :no_structural_progress
          | :order_cycle
          | :net_not_sound

  # -- entry -------------------------------------------------------------------

  @doc """
  Compiles a safe sound WF-net into the POWL 2.0 AST. Returns
  `{:ok, ast}` or `{:error, compile_err()}` (typed refusals, never
  raised exceptions on bad input).
  """
  @spec compile(Powl2.t(), keyword()) ::
          {:ok, Transition.t() | PartialOrder.t() | ChoiceGraph.t()} | {:error, compile_err()}
  def compile(%Powl2{} = net, opts \\ []) do
    with :ok <- validate(net),
         {:ok, ctx} <- reachability(net, opts),
         :ok <- soundness_gate(net, ctx) do
      ts = Enum.sort(net.transitions)

      try do
        go(net, ts, ctx)
      catch
        {:powl2_refusal, reason} -> {:error, reason}
      end
    end
  end

  defp validate(net) do
    cond do
      not Powl2.wf_net?(net) -> {:error, :not_a_wf_net}
      MapSet.size(net.transitions) == 0 -> {:error, :empty_net}
      true -> :ok
    end
  end

  # BK-POWLH2 (HIGH-2 repair): soundness was a documented-but-unenforced
  # precondition, so an unsound loop-shaped net (`source->a->pb->b->sink,
  # b->pl->a` — `a` has input places {source, pl} and can NEVER fire, the
  # sink is unreachable, both transitions are dead) classified its dead
  # transitions :conflict and compiled silently to an edge-less
  # ChoiceGraph. The gate converts that silent mis-compile into the typed
  # refusal :net_not_sound. A sound loop (the court's source->t0->i;
  # i->a->m->b; b->sink, b->i net) still compiles WITH its bidirectional
  # can-follow loop face — the loop representation itself was never broken.
  defp soundness_gate(net, ctx) do
    sink =
      Enum.find(net.places, fn p ->
        not Enum.any?(net.arcs, fn {src, _dst} -> src == p end)
      end)

    dead = MapSet.to_list(net.transitions) -- Map.keys(ctx.fired)

    cond do
      sink == nil or dead != [] or not sink_reachable?(sink, ctx) -> {:error, :net_not_sound}
      true -> :ok
    end
  end

  defp sink_reachable?(sink, ctx), do: Enum.any?(Map.keys(ctx.enabled), &MapSet.member?(&1, sink))

  defp go(_net, [t], _ctx), do: {:ok, Powl2.transition(t)}

  defp go(net, ts, ctx) do
    rels = relations(net, ts, ctx)

    blocks = partition_mg(net, ts, rels)

    if conflict_hiding?(net, ts, blocks, rels) do
      {:ok, build_partial_order(net, ts, blocks, rels, ctx)}
    else
      sm_blocks = partition_sm(net, ts, rels)

      if concurrency_hiding?(net, ts, sm_blocks, rels) do
        {:ok, build_choice_graph(net, ts, sm_blocks, rels, ctx)}
      else
        {:error, :non_separable_fallthrough}
      end
    end
  end

  # -- reachability ------------------------------------------------------------

  # BFS over the reachable marking set. Seen/enabled/next are plain maps
  # keyed by the marking itself (structs are terms; equality is by value).
  defp reachability(net, opts) do
    max = Keyword.get(opts, :max_markings, @default_max_markings)

    with {:ok, source} <- Powl2.source(net) do
      m0 = MapSet.new([source])
      bfs(net, [m0], %{m0 => nil}, %{}, %{}, max)
    end
  end

  defp bfs(net, [], _seen, enabled, next, _max) do
    fired =
      for {m, ens} <- enabled,
          t <- ens,
          reduce: %{} do
        acc ->
          Map.update(acc, t, MapSet.new([fire(net, m, t)]), &MapSet.put(&1, fire(net, m, t)))
      end

    {:ok, %{enabled: enabled, next: next, fired: fired}}
  end

  defp bfs(net, [m | rest], seen, enabled, next, max) do
    if map_size(seen) > max do
      {:error, :net_not_safe}
    else
      ens = enabled_of(net, m)
      enabled = Map.put(enabled, m, ens)
      succ = Enum.map(ens, &fire(net, m, &1))
      next = Map.put(next, m, MapSet.new(succ))

      {new, seen} =
        Enum.reduce(succ, {[], seen}, fn m2, {acc, seen} ->
          if Map.has_key?(seen, m2), do: {acc, seen}, else: {[m2 | acc], Map.put(seen, m2, nil)}
        end)

      bfs(net, rest ++ new, seen, enabled, next, max)
    end
  end

  defp enabled_of(net, m) do
    net.transitions |> Enum.sort() |> Enum.filter(&enabled?(net, m, &1))
  end

  defp enabled?(net, m, t) do
    Enum.all?(Enum.to_list(net.arcs), fn {src, dst} ->
      dst != t or MapSet.member?(m, src)
    end)
  end

  defp fire(net, m, t) do
    consume = for {src, dst} <- Enum.to_list(net.arcs), dst == t, do: src
    produce = for {src, dst} <- Enum.to_list(net.arcs), src == t, do: dst

    m
    |> MapSet.difference(MapSet.new(consume))
    |> MapSet.union(MapSet.new(produce))
  end

  # -- relation matrix -----------------------------------------------------------

  @doc "Ordering-relation matrix over the sorted transition list `ts` (ctx prebuilt)."
  @spec relations(Powl2.t(), [Powl2.node_id()], ctx()) :: relation_matrix()
  def relations(_net, ts, ctx) when is_map(ctx) do
    for x <- ts, y <- ts, x != y, into: %{} do
      {{x, y}, classify(x, y, ctx)}
    end
  end

  # Ordering-relation matrix built fresh from the reachability ctx
  # (`opts` are the `compile/2` options, e.g. `:max_markings`).
  def relations(net, ts, opts) when is_list(opts) do
    with {:ok, ctx} <- reachability(net, opts) do
      relations(net, ts, ctx)
    end
  end

  defp classify(x, y, ctx) do
    cond do
      can_precede(x, y, ctx) and can_precede(y, x, ctx) -> :co
      can_precede(x, y, ctx) -> :lt
      can_precede(y, x, ctx) -> :gt
      true -> :conflict
    end
  end

  # x can precede y: y is enabled at some marking reachable from any
  # exact post-x firing marking.
  defp can_precede(x, y, %{fired: fired, enabled: enabled, next: next}) do
    front = Map.get(fired, x, MapSet.new()) |> MapSet.to_list()

    front
    |> reach_enables(y, next, enabled, MapSet.new())
  end

  defp reach_enables([], _y, _next, _enabled, _visited), do: false

  defp reach_enables(front, y, next, enabled, visited) do
    if Enum.any?(front, fn m -> y in Map.get(enabled, m, []) end) do
      true
    else
      nxt =
        front
        |> Enum.flat_map(&MapSet.to_list(Map.get(next, &1, MapSet.new())))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(visited, &1))

      case nxt do
        [] -> false
        _ -> reach_enables(nxt, y, next, enabled, Enum.reduce(nxt, visited, &MapSet.put(&2, &1)))
      end
    end
  end

  # -- flow paths / loop pairs ---------------------------------------------------

  @doc "Flow path from transition x to transition y in the arc digraph."
  @spec flow_path?(Powl2.t(), Powl2.node_id(), Powl2.node_id()) :: boolean()
  def flow_path?(net, x, y), do: flow_bfs(net, [x], y, MapSet.new([x]))

  defp flow_bfs(_net, [], _y, _visited), do: false

  defp flow_bfs(net, front, y, visited) do
    arcs = Enum.to_list(net.arcs)

    nxt =
      for n <- front, {s, d} <- arcs, s == n, d != y, not MapSet.member?(visited, d) do
        d
      end

    hit? = Enum.any?(front, fn n -> Enum.any?(arcs, fn {s, d} -> s == n and d == y end) end)

    cond do
      hit? -> true
      nxt == [] -> false

      true ->
        visited = Enum.reduce(nxt, visited, &MapSet.put(&2, &1))
        flow_bfs(net, Enum.uniq(nxt), y, visited)
    end
  end

  @doc """
  A `:co` pair with flow paths BOTH ways: not plain concurrency — a
  loop (which a PartialOrder cannot express) or a handle (which nothing
  in the AST can express).
  """
  @spec loop_pair?(Powl2.t(), Powl2.node_id(), Powl2.node_id(), relation_matrix()) :: boolean()
  def loop_pair?(net, x, y, rels) do
    Map.get(rels, {x, y}) == :co and flow_path?(net, x, y) and flow_path?(net, y, x)
  end

  # -- partitions and gates -------------------------------------------------------

  @doc """
  Maximal-group partition: merges x, y iff they are `:co` and NOT a
  loop pair. Blocks are sorted id lists, deterministically ordered.
  """
  @spec partition_mg(Powl2.t(), [Powl2.node_id()], relation_matrix()) :: [[Powl2.node_id()]]
  def partition_mg(net, ts, rels) do
    pairs =
      for x <- ts,
          y <- ts,
          x < y,
          Map.get(rels, {x, y}) == :co and not loop_pair?(net, x, y, rels),
          do: {x, y}

    union_find(ts, pairs)
  end

  @doc """
  Conflict-hiding gate for the MG partition: REFUSES when (a) a loop
  pair exists anywhere in the fragment (a PartialOrder would hide the
  loop as concurrency), (b) a conflict pair spans two blocks (PO edge
  semantics would leave the children unordered == concurrent, hiding
  the choice), or (c) a conflict pair hides inside one multi-member
  block (a co-cluster child can never express concurrent-yet-conflicting
  — the handle signature).
  """
  @spec conflict_hiding?(Powl2.t(), [Powl2.node_id()], [[Powl2.node_id()]], relation_matrix()) ::
          boolean()
  def conflict_hiding?(net, ts, blocks, rels) do
    loop_free? =
      not Enum.any?(ts, fn x -> Enum.any?(ts, fn y -> x < y and loop_pair?(net, x, y, rels) end) end)

    conflict_free? =
      not Enum.any?(ts, fn x ->
        Enum.any?(ts, fn y ->
          x < y and Map.get(rels, {x, y}) == :conflict and
            not (same_block?(blocks, x, y) and length(block_of(blocks, x)) == 1)
        end)
      end)

    loop_free? and conflict_free?
  end

  @doc """
  State-machine partition: merges x, y on conflict, on a loop pair, or
  on a shared input place (choice class).
  """
  @spec partition_sm(Powl2.t(), [Powl2.node_id()], relation_matrix()) :: [[Powl2.node_id()]]
  def partition_sm(net, ts, rels) do
    pairs =
      for x <- ts,
          y <- ts,
          x < y,
          Map.get(rels, {x, y}) == :conflict or
            loop_pair?(net, x, y, rels) or
            shared_input?(net, x, y),
          do: {x, y}

    union_find(ts, pairs)
  end

  @doc """
  Concurrency-hiding gate for the SM partition: REFUSES when a TRUE
  concurrency pair (`:co`, non-loop) exists anywhere in the fragment —
  inside one block it would be modeled as choice, across blocks it
  would be sequenced by a can-follow edge; a ChoiceGraph expresses
  neither, so both are hiding.
  """
  @spec concurrency_hiding?(Powl2.t(), [Powl2.node_id()], [[Powl2.node_id()]], relation_matrix()) ::
          boolean()
  def concurrency_hiding?(net, ts, _blocks, rels) do
    not Enum.any?(ts, fn x ->
      Enum.any?(ts, fn y ->
        x < y and Map.get(rels, {x, y}) == :co and not loop_pair?(net, x, y, rels)
      end)
    end)
  end

  @doc """
  Structural-progress guard: every block is a non-empty PROPER subset of
  the parent fragment — no whole-net-isomorphic projection is recursed.
  """
  @spec structural_progress?([Powl2.node_id()], [[Powl2.node_id()]]) :: boolean()
  def structural_progress?(ts, blocks) do
    size = length(Enum.uniq(ts))

    blocks != [] and
      Enum.all?(blocks, fn b -> b != [] and length(Enum.uniq(b)) < size end)
  end

  # -- AST construction -------------------------------------------------------------

  defp build_partial_order(net, ts, blocks, rels, ctx) do
    if length(blocks) == 1 do
      # residual single block, gate-passed: pure concurrency cluster.
      Powl2.partial_order(Enum.map(hd(blocks), &Powl2.transition/1), [])
    else
      :ok = progress!(ts, blocks)
      children = Enum.map(blocks, &compile_block(net, &1, ctx))

      order =
        for i <- indices(blocks),
            j <- indices(blocks),
            i != j,
            any_rel?(Enum.at(blocks, i), Enum.at(blocks, j), rels, :lt),
            do: {i, j}

      order_cycle_check!(order)
      Powl2.partial_order(children, order)
    end
  end

  defp build_choice_graph(net, ts, blocks, rels, ctx) do
    if length(blocks) == 1 do
      # residual single block, gate-passed: pure choice/loop cluster —
      # flat ChoiceGraph over leaf transitions, can-follow edges between
      # every non-conflicting ordered pair.
      ids = hd(blocks)
      children = Enum.map(ids, &Powl2.transition/1)

      edges =
        for {x, i} <- Enum.with_index(ids),
            {y, j} <- Enum.with_index(ids),
            i != j,
            Map.get(rels, {x, y}) in [:lt, :co],
            do: {i, j}

      Powl2.choice_graph(children, edges)
    else
      :ok = progress!(ts, blocks)
      children = Enum.map(blocks, &compile_block(net, &1, ctx))

      edges =
        for i <- indices(blocks),
            j <- indices(blocks),
            i != j,
            can_follow?(Enum.at(blocks, i), Enum.at(blocks, j), rels),
            do: {i, j}

      Powl2.choice_graph(children, edges)
    end
  end

  defp indices(blocks), do: 0..(length(blocks) - 1)

  # AR-POWL-03 seam: the induced block order must be a DAG before it is
  # admitted as a PartialOrder. Gates make a cycle unreachable in
  # practice; this is the machine check that refuses instead of
  # building an invalid AST. Engine is GraphCompat (native :graph on
  # OTP 29, seen-set DFS fallback on OTP 28).
  defp order_cycle_check!(order) do
    if GraphCompat.acyclic?(order) do
      :ok
    else
      throw({:powl2_refusal, :order_cycle})
    end
  end

  defp progress!(ts, blocks) do
    if structural_progress?(ts, blocks) do
      :ok
    else
      throw({:powl2_refusal, :no_structural_progress})
    end
  end

  defp compile_block(_net, [t], _ctx), do: Powl2.transition(t)

  defp compile_block(net, block, ctx) do
    case go(net, Enum.sort(block), ctx) do
      {:ok, ast} -> ast
      # gate-passed blocks are co-only (PO branch) or conflict/loop-only
      # (CG branch); an internal refusal cannot be improved here.
      {:error, reason} -> throw({:powl2_refusal, reason})
    end
  end

  defp any_rel?(b1, b2, rels, rel) do
    Enum.any?(b1, fn x -> Enum.any?(b2, fn y -> Map.get(rels, {x, y}) == rel end) end)
  end

  defp can_follow?(b1, b2, rels) do
    Enum.any?(b1, fn x -> Enum.any?(b2, fn y -> Map.get(rels, {x, y}) in [:lt, :co] end) end)
  end

  # -- small union-find -------------------------------------------------------------

  defp union_find(ts, pairs) do
    parent =
      Enum.reduce(pairs, Map.new(ts, &{&1, &1}), fn {x, y}, acc ->
        rx = find(acc, x)
        ry = find(acc, y)
        if rx == ry, do: acc, else: Map.put(acc, rx, ry)
      end)

    ts
    |> Enum.group_by(&find(parent, &1))
    |> Map.values()
    |> Enum.map(&Enum.sort/1)
    |> Enum.sort()
  end

  defp find(parent, x) do
    case Map.fetch!(parent, x) do
      ^x -> x
      p -> find(parent, p)
    end
  end

  defp same_block?(blocks, x, y) do
    bx = block_of(blocks, x)
    bx != nil and Enum.member?(bx, y)
  end

  defp block_of(blocks, x), do: Enum.find(blocks, &Enum.member?(&1, x))

  defp shared_input?(net, x, y) do
    inputs = fn t ->
      MapSet.new(for {src, dst} <- Enum.to_list(net.arcs), dst == t, do: src)
    end

    not MapSet.disjoint?(inputs.(x), inputs.(y))
  end
end

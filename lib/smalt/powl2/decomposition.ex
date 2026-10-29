defmodule Smalt.Powl2.Decomposition do
  @moduledoc """
  POWL-2: block-structured decomposition of a WF-net into modules that
  hide conflict (Algorithm 1, `partition_mg/1`) or concurrency
  (Algorithm 2, `partition_sm/1`), plus the Def 4.1 / 4.4 validators.

  Relations:

  * Conflict (XOR): t1 # t2 when they share an input place - the
    XOR-split place enables at most one of them. Hidden by Alg 1.
  * Concurrency (AND): t1 || t2 when they have distinct input places
    p1 != p2 sharing a common producer transition u (a place-level
    AND-split) and they are not in conflict. Exact under sound
    free-choice WF-nets with single-input-place transitions: sequenced
    pairs share no producer at place level; a choice pair's only
    common ancestor is a branching place (XOR-split), never a
    transition.
  """
  alias Smalt.PetriNet
  alias Smalt.Powl2.GraphCompat

  @type transition :: PetriNet.transition()
  @type group :: MapSet.t(transition())
  @type partition :: [group()]
  @type relation :: MapSet.t({transition(), transition()})

  @doc "Algorithm 1: conflict-hiding partition (XOR scope analysis)."
  @spec partition_mg(PetriNet.t()) :: {:ok, partition()} | {:error, :not_well_formed}
  def partition_mg(%PetriNet{} = net) do
    if PetriNet.well_formed?(net) do
      uf = reduce_pairs(seed(net), conflict_pairs(net))
      gs = groups(uf, net)
      block_cycle_check!(net, gs)
      {:ok, gs}
    else
      {:error, :not_well_formed}
    end
  end

  @doc "Algorithm 2: concurrency-hiding partition (AND scope analysis)."
  @spec partition_sm(PetriNet.t()) :: {:ok, partition()} | {:error, :not_well_formed}
  def partition_sm(%PetriNet{} = net) do
    if PetriNet.well_formed?(net) do
      pairs = concurrent_pairs(net)
      uf = reduce_pairs(seed(net), pairs)
      uf = and_split_closure(net, uf, pairs)
      uf = and_join_closure(net, uf, pairs)
      gs = groups(uf, net)
      block_cycle_check!(net, gs)
      {:ok, gs}
    else
      {:error, :not_well_formed}
    end
  end

  defp reduce_pairs(uf, %MapSet{} = pairs) do
    pairs
    |> MapSet.to_list()
    |> Enum.reduce(uf, &union(&2, elem(&1, 0), elem(&1, 1)))
  end
  # ── Relations ──

  @doc "Conflict pairs (XOR): transitions sharing an input place. Symmetric."
  @spec conflict_pairs(PetriNet.t()) :: relation()
  def conflict_pairs(%PetriNet{} = net) do
    for p <- MapSet.to_list(net.places),
        t1 <- MapSet.to_list(PetriNet.postset(net, p)),
        t2 <- MapSet.to_list(PetriNet.postset(net, p)),
        t1 != t2 do
      {t1, t2}
    end
    |> MapSet.new()
  end

  @doc """
  Concurrency pairs (AND): distinct input places p1 != p2 sharing a
  common producer transition, not in conflict. Symmetric.
  """
  @spec concurrent_pairs(PetriNet.t()) :: relation()
  def concurrent_pairs(%PetriNet{} = net) do
    conflict = conflict_pairs(net)
    siblings = sibling_places(net)

    for t1 <- Enum.sort(MapSet.to_list(net.transitions)),
        t2 <- Enum.sort(MapSet.to_list(net.transitions)),
        t1 != t2,
        not MapSet.member?(conflict, {t1, t2}),
        Enum.any?(MapSet.to_list(PetriNet.preset(net, t1)), fn p1 ->
          Enum.any?(MapSet.to_list(PetriNet.preset(net, t2)), fn p2 ->
            MapSet.member?(siblings, {p1, p2})
          end)
        end) do
      {t1, t2}
    end
    |> MapSet.new()
  end

  # Place pairs sharing a common producer transition (AND-split mark).
  defp sibling_places(net) do
    for p1 <- MapSet.to_list(net.places),
        p2 <- MapSet.to_list(net.places),
        p1 != p2,
        not MapSet.disjoint?(PetriNet.preset(net, p1), PetriNet.preset(net, p2)) do
      {p1, p2}
    end
    |> MapSet.new()
  end
  # ── Validators (Defs 4.1 / 4.4) ──

  @doc "Def 4.1: no conflict pair crosses groups; merged groups are blocks."
  @spec conflict_hiding?(PetriNet.t(), partition() | {:ok, partition()}) :: boolean()
  def conflict_hiding?(net, {:ok, groups}), do: conflict_hiding?(net, groups)

  def conflict_hiding?(%PetriNet{} = net, groups) when is_list(groups) do
    hiding?(net, groups, conflict_pairs(net))
  end

  @doc "Def 4.4: no concurrent pair crosses groups; merged groups are blocks."
  @spec concurrency_hiding?(PetriNet.t(), partition() | {:ok, partition()}) :: boolean()
  def concurrency_hiding?(net, {:ok, groups}), do: concurrency_hiding?(net, groups)

  def concurrency_hiding?(%PetriNet{} = net, groups) when is_list(groups) do
    hiding?(net, groups, concurrent_pairs(net))
  end

  defp hiding?(net, groups, relation) do
    PetriNet.well_formed?(net) and covers_all?(net, groups) and
      pairs_covered?(relation, groups) and
      Enum.all?(Enum.reject(groups, &(MapSet.size(&1) < 2)), fn g -> block_group?(net, g) end)
  end

  defp covers_all?(net, groups) do
    groups
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.equal?(net.transitions)
  end

  defp pairs_covered?(relation, groups) do
    relation
    |> MapSet.to_list()
    |> Enum.all?(fn {t1, t2} ->
      Enum.any?(groups, fn g ->
        MapSet.member?(g, t1) and MapSet.member?(g, t2)
      end)
    end)
  end

  @doc """
  Entry/exit place equivalence for one group: the induced subnet has
  exactly one entry place (empty preset) and one exit place (empty
  postset) - the group is equivalent to a WF-net block. Singleton
  groups carry no hidden pair.
  """
  @spec block_group?(PetriNet.t(), group()) :: boolean()
  def block_group?(%PetriNet{} = net, %MapSet{} = group) do
    subnet = induced_subnet(net, group)
    MapSet.size(PetriNet.entry_places(subnet)) == 1 and
      MapSet.size(PetriNet.exit_places(subnet)) == 1
  end

  @doc """
  IMPL-15 / AR-POWL-03: the induced group-order graph. Vertices are
  group indices; edge {i, j} exists iff some arc of the net runs from a
  transition of group i, through a place, into a transition of group j
  (i != j). Blocks compose only when this quotient graph is a DAG.
  """
  @spec block_order_edges(PetriNet.t(), partition()) :: [{non_neg_integer(), non_neg_integer()}]
  def block_order_edges(%PetriNet{} = net, groups) when is_list(groups) do
    idx =
      groups
      |> Enum.with_index()
      |> Enum.flat_map(fn {g, i} -> Enum.map(MapSet.to_list(g), &{&1, i}) end)
      |> Map.new()

    for {:transition, t1, p} <- net.arcs,
        {:place, ^p, t2} <- net.arcs,
        i = Map.fetch!(idx, t1),
        j = Map.fetch!(idx, t2),
        i != j do
      {i, j}
    end
    |> Enum.uniq()
  end

  @doc """
  Machine acyclicity check on the induced group-order graph, through
  the same engine seam as the compiler (GraphCompat: native :graph on
  OTP 29, seen-set DFS fallback on OTP 28).
  """
  @spec block_order_acyclic?(PetriNet.t(), partition()) :: boolean()
  def block_order_acyclic?(%PetriNet{} = net, groups) when is_list(groups) do
    GraphCompat.acyclic?(block_order_edges(net, groups))
  end

  @doc """
  Typed refusal mirroring Compiler.order_cycle_check!/1: throws
  `{:powl2_refusal, :block_order_cycle}` when the quotient graph has a
  cycle, instead of admitting a partition whose blocks cannot compose.
  """
  @spec block_cycle_check!(PetriNet.t(), partition()) :: :ok
  def block_cycle_check!(%PetriNet{} = net, groups) when is_list(groups) do
    if block_order_acyclic?(net, groups) do
      :ok
    else
      throw({:powl2_refusal, :block_order_cycle})
    end
  end

  defp induced_subnet(net, group) do
    arcs =
      Enum.filter(net.arcs, fn
        {:place, _p, t} -> MapSet.member?(group, t)
        {:transition, t, _p} -> MapSet.member?(group, t)
      end)

    PetriNet.new(arcs: arcs)
  end
  # ── Algorithm 2 scope closures ──

  # AND-split scope: transition u with distinct output places where the
  # pair members are immediately enabled on different branches - the
  # pair's delimiting split joins the module.
  defp and_split_closure(net, uf, pairs) do
    pairs
    |> MapSet.to_list()
    |> Enum.reduce(uf, fn {t1, t2}, acc ->
      net.transitions
      |> MapSet.to_list()
      |> Enum.reduce(acc, fn u, acc2 ->
        if split_for?(net, u, t1, t2), do: union(acc2, u, t1), else: acc2
      end)
    end)
  end

  defp split_for?(net, u, t1, t2) do
    ps = MapSet.to_list(PetriNet.postset(net, u))

    Enum.any?(ps, fn p1 ->
      Enum.any?(ps, fn p2 ->
        p1 != p2 and
          MapSet.member?(PetriNet.postset(net, p1), t1) and
          MapSet.member?(PetriNet.postset(net, p2), t2)
      end)
    end)
  end

  # AND-join scope: place q with >= 2 producers that are pairwise
  # concurrent and not conflicting - merge the producers and q's
  # direct consumers into the module.
  defp and_join_closure(net, uf, pairs) do
    conflict = conflict_pairs(net)

    net.places
    |> MapSet.to_list()
    |> Enum.reduce(uf, fn q, acc ->
      ins = MapSet.to_list(PetriNet.preset(net, q))

      if join_place?(ins, pairs, conflict) do
        anchor = hd(ins)

        acc = merge_all(acc, ins)
        consumers = MapSet.to_list(PetriNet.postset(net, q))

        Enum.reduce(consumers, acc, fn consumer, acc2 ->
          union(acc2, consumer, anchor)
        end)
      else
        acc
      end
    end)
  end

  defp join_place?(ins, _pairs, _conflict) when length(ins) < 2, do: false

  defp join_place?(ins, pairs, conflict) do
    Enum.all?(ins, fn a ->
      Enum.all?(ins, fn b ->
        a == b or (MapSet.member?(pairs, {a, b}) and not MapSet.member?(conflict, {a, b}))
      end)
    end)
  end


  defp merge_all(uf, [t | rest]) do
    Enum.reduce(rest, uf, fn other, acc -> union(acc, t, other) end)
  end
  # ── Union-find (union by rank, path via recursion) ──

  defp seed(net) do
    net.transitions
    |> MapSet.to_list()
    |> Map.new(fn t -> {t, {t, 0}} end)
  end

  defp find(uf, t) do
    case Map.fetch!(uf, t) do
      {^t, _rank} -> t
      {parent, _rank} -> find(uf, parent)
    end
  end

  defp union(uf, a, b) do
    ra = find(uf, a)
    rb = find(uf, b)

    cond do
      ra == rb ->
        uf

      elem(Map.fetch!(uf, ra), 1) >= elem(Map.fetch!(uf, rb), 1) ->
        Map.put(uf, rb, {ra, elem(Map.fetch!(uf, rb), 1)})

      true ->
        Map.put(uf, ra, {rb, elem(Map.fetch!(uf, ra), 1)})
    end
  end

  defp groups(uf, net) do
    net.transitions
    |> MapSet.to_list()
    |> Enum.group_by(fn t -> find(uf, t) end)
    |> Map.values()
    |> Enum.map(&MapSet.new/1)
    |> Enum.sort_by(&MapSet.to_list/1)
  end
end

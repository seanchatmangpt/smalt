defmodule Smalt.POWL2.Projection do
  @moduledoc """
  POWL2 Petri-net projections (Defs 4.2/4.3/4.7/4.8) over `Smalt.PetriNet`.

  - Def 4.2 `project_mg/4` — subnet projection onto transition set M with
    two FRESH delimiter places ps/pe. A place x adjacent to M is internal
    iff preset(x) and postset(x) are both nonempty subsets of M; otherwise
    its arcs are rerouted: incoming `{:place, x, t}` becomes `{:place, ps, t}`
    (entry rerouting), outgoing `{:transition, t, x}` becomes
    `{:transition, t, pe}` (exit rerouting). Internal places keep their arcs.
    Subnet source is ps, sink is pe.
  - Def 4.3 `project_sm/4` — SESE projection: the project_mg subnet,
    typed-refused `{:error, {:not_sese, detail}}` unless the boundary has
    exactly one entry arc and one exit arc.
  - Def 4.7 `normalize/3` — when delimiters carry arcs (ps has incoming
    `{:place, x, ps}` or pe has outgoing `{:place, pe, y}`), insert synthetic
    tau source/sink transitions making the stray arcs silent; with no
    strays the net is returned unchanged (tau ONLY when needed).
  - Def 4.8 `execution_order/2` / `execution_flow/2` — composition edges:
    order^+ transitive closure over exit/entry delimiter overlap for
    marked-graph children; gamma choice-graph edges projected onto the
    children's delimiters.
  """

  alias Smalt.PetriNet
  alias Smalt.POWL2.Reticle.AST

  @typedoc "Projection record for one child subnet."
  @type projection :: %{
          id: term,
          net: PetriNet.t(),
          ps: PetriNet.place(),
          pe: PetriNet.place(),
          entries: [PetriNet.transition()],
          exits: [PetriNet.transition()]
        }

  @doc """
  Def 4.2: project the net onto transition set `members` with fresh
  delimiters `ps`/`pe`.
  """
  @spec project_mg(PetriNet.t(), [PetriNet.transition()] | MapSet.t(), term, term) ::
          projection()
  def project_mg(net, members, ps, pe) when ps != pe do
    members = MapSet.new(members)

    internal? = fn x ->
      pre = PetriNet.preset(net, x)
      post = PetriNet.postset(net, x)

      MapSet.size(pre) > 0 and MapSet.size(post) > 0 and
        MapSet.subset?(pre, members) and MapSet.subset?(post, members)
    end

    {arcs, entries, exits, places} =
      Enum.reduce(net.arcs, {[], [], [], MapSet.new([ps, pe])}, fn arc, acc ->
        {as, en, ex, pl} = acc

        case arc do
          {:place, x, t} ->
            if MapSet.member?(members, t) do
              if internal?.(x) do
                {[arc | as], en, ex, MapSet.put(pl, x)}
              else
                {[{:place, ps, t} | as], [t | en], ex, pl}
              end
            else
              acc
            end

          {:transition, t, x} ->
            if MapSet.member?(members, t) do
              if internal?.(x) do
                {[arc | as], en, ex, MapSet.put(pl, x)}
              else
                {[{:transition, t, pe} | as], en, [t | ex], pl}
              end
            else
              acc
            end

          _ ->
            acc
        end
      end)

    %{
      id: {:mg, ps, pe},
      net:
        PetriNet.new(
          places: MapSet.to_list(places),
          transitions: MapSet.to_list(members),
          arcs: arcs,
          source: ps,
          sink: pe
        ),
      ps: ps,
      pe: pe,
      entries: Enum.uniq(entries),
      exits: Enum.uniq(exits)
    }
  end

  @doc """
  Def 4.3: SESE projection — the project_mg subnet admitted only when the
  boundary has exactly one entry arc and one exit arc; otherwise typed
  refusal `{:error, {:not_sese, detail}}`.
  """
  @spec project_sm(PetriNet.t(), [PetriNet.transition()] | MapSet.t(), term, term) ::
          {:ok, projection()} | {:error, {:not_sese, term}}
  def project_sm(net, members, ps, pe) do
    proj = project_mg(net, members, ps, pe)

    cond do
      length(proj.entries) != 1 ->
        {:error, {:not_sese, {:entry_count, length(proj.entries)}}}

      length(proj.exits) != 1 ->
        {:error, {:not_sese, {:exit_count, length(proj.exits)}}}

      true ->
        {:ok, %{proj | id: {:sm, ps, pe}}}
    end
  end

  @doc """
  Def 4.7: normalize — synthetic tau source/sink insertion when delimiters
  carry arcs. Stray incoming `{:place, x, ps}` becomes `{:place, x, tau_s}` +
  `{:place, tau_s, ps}`; stray outgoing `{:place, pe, y}` becomes
  `{:place, pe, tau_k}` + `{:place, tau_k, y}`. With no strays the net is
  returned unchanged.
  """
  @spec normalize(PetriNet.t(), term, term) :: PetriNet.t()
  def normalize(%PetriNet{} = net, ps, pe) do
    tau_s = {:tau, :source, ps}
    tau_k = {:tau, :sink, pe}

    stray? =
      Enum.any?(net.arcs, fn
        {:place, _, ^ps} -> true
        {:place, ^pe, _} -> true
        _ -> false
      end)

    if stray? do
      arcs =
        Enum.flat_map(net.arcs, fn
          {:place, x, ^ps} -> [{:place, x, tau_s}, {:place, tau_s, ps}]
          {:place, ^pe, y} -> [{:place, pe, tau_k}, {:place, tau_k, y}]
          other -> [other]
        end)

      PetriNet.new(
        places: MapSet.to_list(net.places),
        transitions: [tau_s, tau_k] ++ MapSet.to_list(net.transitions),
        arcs: arcs,
        source: net.source,
        sink: net.sink,
        labels: net.labels
      )
    else
      net
    end
  end

  @doc """
  Def 4.8a: execution order = order^+ — the transitive closure of
  (base order pairs ∪ overlap edges), where an overlap edge i->j exists
  when child i's exit delimiter pe_i equals child j's entry delimiter ps_j
  (exit/entry place overlap for marked-graph children).
  """
  @spec execution_order([projection() | map()], [{term, term}]) :: MapSet.t()
  def execution_order(children, base_order \\ []) do
    by_pe = Map.new(children, fn c -> {c.pe, c.id} end)
    by_ps = Map.new(children, fn c -> {c.ps, c.id} end)

    overlap_edges =
      for {pe_i, id_i} <- by_pe,
          {ps_j, id_j} <- by_ps,
          pe_i == ps_j,
          id_i != id_j,
          do: {id_i, id_j}

    base_order
    |> MapSet.new()
    |> MapSet.union(MapSet.new(overlap_edges))
    |> closure()
  end

  @doc """
  Def 4.8b: execution flow — gamma choice-graph edges projected onto the
  children's delimiters: edge {a, b} becomes {exit(a), entry(b)}; the
  choice graph's `start` maps to the start child's ps; the end child's pe
  maps to the finish delimiter.
  """
  @spec execution_flow(%AST.ChoiceGraph{}, [projection() | map()]) :: %{
          edges: [{term, term}],
          start: term,
          finish: term
        }
  def execution_flow(%AST.ChoiceGraph{start: start, end: fin, edges: edges}, children) do
    by_id = Map.new(children, fn c -> {c.id, c} end)

    edges =
      for {a, b} <- edges do
        {fetch!(by_id, a).pe, fetch!(by_id, b).ps}
      end

    %{
      edges: edges,
      start: fetch!(by_id, start).ps,
      finish: fetch!(by_id, fin).pe
    }
  end

  # -- helpers ---------------------------------------------------------------

  defp fetch!(by_id, id) do
    case Map.fetch(by_id, id) do
      {:ok, c} -> c
      :error -> raise ArgumentError, "unknown choice-graph endpoint #{inspect(id)}"
    end
  end

  defp closure(seed) do
    adj =
      Enum.reduce(seed, %{}, fn {a, b}, acc ->
        Map.update(acc, a, MapSet.new([b]), &MapSet.put(&1, b))
      end)

    nodes = seed |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    closed =
      Enum.reduce(nodes, adj, fn k, adj ->
        froms = adj[k] || MapSet.new()

        Enum.reduce(nodes, adj, fn i, adj ->
          if i != k and MapSet.member?(adj[i] || MapSet.new(), k) do
            Map.update!(adj, i, fn targets -> MapSet.union(targets, froms) end)
          else
            adj
          end
        end)
      end)

    closed
    |> Enum.flat_map(fn {a, targets} -> Enum.map(targets, fn b -> {a, b} end) end)
    |> MapSet.new()
  end
end

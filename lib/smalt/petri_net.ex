defmodule Smalt.PetriNet do
  @moduledoc """
  Formal workflow net (WF-net) struct N = (P, T, F, source, sink, labels)
  per Kourani et al. (2026) DFLSS design. Pure struct functions, no process.

  * `P` — places, `T` — transitions, `F` — flow relation as
    `{:place, p, t}` / `{:transition, t, p}` arcs (adjacency derived on build).
  * `source` / `sink` — the interface places of the WF-net.
  * `labels` — map of transition => label (defaults to identity).
  """

  defstruct places: MapSet.new(),
            transitions: MapSet.new(),
            arcs: [],
            source: nil,
            sink: nil,
            labels: %{},
            # derived adjacency: post/preset of transitions and of places
            post_t: %{},
            pre_t: %{},
            post_p: %{},
            pre_p: %{}

  @type place :: term()
  @type transition :: term()
  @type arc :: {:place, place(), transition()} | {:transition, transition(), place()}

  @type t :: %__MODULE__{
          places: MapSet.t(place()),
          transitions: MapSet.t(transition()),
          arcs: [arc()],
          source: place() | nil,
          sink: place() | nil,
          labels: %{transition() => term()},
          post_t: %{transition() => MapSet.t(place())},
          pre_t: %{transition() => MapSet.t(place())},
          post_p: %{place() => MapSet.t(transition())},
          pre_p: %{place() => MapSet.t(transition())}
        }

  @doc """
  Builds a WF-net. `arcs` is the flow relation F; endpoint places/transitions
  are registered automatically. `labels` defaults to identity on transitions.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    arcs = Keyword.get(opts, :arcs, [])
    places = opts |> Keyword.get(:places, []) |> MapSet.new()
    transitions = opts |> Keyword.get(:transitions, []) |> MapSet.new()

    {places, transitions} =
      Enum.reduce(arcs, {places, transitions}, fn
        {:place, p, t}, {ps, ts} -> {MapSet.put(ps, p), MapSet.put(ts, t)}
        {:transition, t, p}, {ps, ts} -> {MapSet.put(ps, p), MapSet.put(ts, t)}
      end)

    {post_t, pre_t, post_p, pre_p} =
      Enum.reduce(arcs, {%{}, %{}, %{}, %{}}, fn arc, acc ->
        case arc do
          {:place, p, t} -> acc |> upd(1, t, p) |> upd(2, p, t)
          {:transition, t, p} -> acc |> upd(0, t, p) |> upd(3, p, t)
        end
      end)

    label_overrides = Keyword.get(opts, :labels, %{})

    labels = Map.new(transitions, fn t -> {t, Map.get(label_overrides, t, t)} end)

    %__MODULE__{
      places: places,
      transitions: transitions,
      arcs: arcs,
      source: Keyword.get(opts, :source),
      sink: Keyword.get(opts, :sink),
      labels: labels,
      post_t: post_t,
      pre_t: pre_t,
      post_p: post_p,
      pre_p: pre_p
    }
  end

  # tuple-index update: 0=post_t, 1=pre_t, 2=post_p, 3=pre_p
  defp upd({a, b, c, d}, 0, k, v),
    do: {Map.update(a, k, MapSet.new([v]), &MapSet.put(&1, v)), b, c, d}

  defp upd({a, b, c, d}, 1, k, v),
    do: {a, Map.update(b, k, MapSet.new([v]), &MapSet.put(&1, v)), c, d}

  defp upd({a, b, c, d}, 2, k, v),
    do: {a, b, Map.update(c, k, MapSet.new([v]), &MapSet.put(&1, v)), d}

  defp upd({a, b, c, d}, 3, k, v),
    do: {a, b, c, Map.update(d, k, MapSet.new([v]), &MapSet.put(&1, v))}

  @doc "Preset: for a transition, its input places; for a place, the transitions producing it."
  @spec preset(t(), place() | transition()) :: MapSet.t()
  def preset(%__MODULE__{} = n, node) do
    if MapSet.member?(n.transitions, node) do
      Map.get(n.pre_t, node, MapSet.new())
    else
      Map.get(n.pre_p, node, MapSet.new())
    end
  end

  @doc "Postset: for a transition, its output places; for a place, the transitions consuming it."
  @spec postset(t(), place() | transition()) :: MapSet.t()
  def postset(%__MODULE__{} = n, node) do
    if MapSet.member?(n.transitions, node) do
      Map.get(n.post_t, node, MapSet.new())
    else
      Map.get(n.post_p, node, MapSet.new())
    end
  end

  @doc """
  Transition reachability via positive-flow closure: BFS from the source place
  through the flow relation, collecting every transition reachable without any
  marking assumption. A transition is reachable when some reachable place
  feeds it.
  """
  @spec reachable_transitions(t()) :: MapSet.t(transition())
  def reachable_transitions(%__MODULE__{} = n), do: reachable_transitions(n, n.source)

  @doc "Positive-flow closure from an explicit start place."
  @spec reachable_transitions(t(), place() | nil) :: MapSet.t(transition())
  def reachable_transitions(%__MODULE__{} = n, start) do
    bfs_from(n, start, nil)
  end

  @doc """
  Forward restricted reachability (Def 4.5): transitions reachable from the
  source via positive-flow closure without passing through `t_stop`.
  `t_stop` itself is excluded from the result and never traversed.
  """
  @spec forward_restricted(t(), transition()) :: MapSet.t(transition())
  def forward_restricted(%__MODULE__{} = n, t_stop) do
    bfs_from(n, n.source, t_stop)
  end

  @doc """
  Backward restricted reachability (Def 4.6): transitions from which the sink
  is reachable without passing through `t_stop` — forward restricted
  reachability over the reversed flow relation.
  """
  @spec backward_restricted(t(), transition()) :: MapSet.t(transition())
  def backward_restricted(%__MODULE__{} = n, t_stop) do
    n |> reverse() |> bfs_from(n.sink, t_stop)
  end

  @doc "Reversed flow relation (source/sink preserved); used for backward closure."
  @spec reverse(t()) :: t()
  def reverse(%__MODULE__{} = n) do
    arcs =
      Enum.map(n.arcs, fn
        {:place, p, t} -> {:transition, t, p}
        {:transition, t, p} -> {:place, p, t}
      end)

    new(arcs: arcs, source: n.source, sink: n.sink)
  end

  @doc """
  Entry places (Section 4.2.1): places with an empty preset — the interface
  points where the net may start. Well-formed WF-nets have exactly one, the
  source.
  """
  @spec entry_places(t()) :: MapSet.t(place())
  def entry_places(%__MODULE__{} = n) do
    MapSet.filter(n.places, fn p -> MapSet.size(preset(n, p)) == 0 end)
  end

  @doc """
  Exit places (Section 4.2.1): places with an empty postset — the interface
  points where the net may end. Well-formed WF-nets have exactly one, the
  sink.
  """
  @spec exit_places(t()) :: MapSet.t(place())
  def exit_places(%__MODULE__{} = n) do
    MapSet.filter(n.places, fn p -> MapSet.size(postset(n, p)) == 0 end)
  end

  @doc """
  WF-net well-formedness: exactly one entry place (= declared source) and one
  exit place (= declared sink), and every transition reachable both forward
  (from source) and backward (to sink).
  """
  @spec well_formed?(t()) :: boolean()
  def well_formed?(%__MODULE__{} = n) do
    entries = entry_places(n)
    exits = exit_places(n)

    MapSet.size(entries) == 1 and MapSet.member?(entries, n.source) and
      MapSet.size(exits) == 1 and MapSet.member?(exits, n.sink) and
      MapSet.equal?(reachable_transitions(n), n.transitions) and
      MapSet.equal?(reachable_transitions(reverse(n), n.sink), n.transitions)
  end

  defp bfs_from(_n, nil, _t_stop), do: MapSet.new()

  defp bfs_from(n, start, t_stop) do
    bfs(n, [start], MapSet.new([start]), MapSet.new(), t_stop)
  end

  defp bfs(_n, [], _seen_p, seen_t, _t_stop), do: seen_t

  defp bfs(n, [p | rest], seen_p, seen_t, t_stop) do
    enabled =
      n
      |> postset(p)
      |> then(fn ts -> if t_stop, do: MapSet.delete(ts, t_stop), else: ts end)

    new_places =
      enabled
      |> Enum.flat_map(&MapSet.to_list(postset(n, &1)))
      |> Enum.reject(&MapSet.member?(seen_p, &1))
      |> Enum.uniq()

    bfs(
      n,
      rest ++ new_places,
      MapSet.union(seen_p, MapSet.new(new_places)),
      MapSet.union(seen_t, enabled),
      t_stop
    )
  end
end

defmodule Smalt.Powl2 do
  @moduledoc """
  POWL 2.0 AST surface (WO POWL-4).

  Four structs:

    - `Smalt.Powl2.Net` — a safe WF-net: `:places`/`:transitions` are
      `MapSet`s of node ids (atoms), `:arcs` is a `MapSet` of `{src, dst}`
      flow pairs. Exactly one source place (no incoming arcs) and one
      sink place (no outgoing arcs) is required by `wf_net?/1`.
    - `Smalt.Powl2.Transition` — leaf: a single labelled transition.
    - `Smalt.Powl2.PartialOrder` — concurrent children with a strict
      order edge set over child INDICES (`[{i, j}, ...]`): children i and
      j with no path between them in the edge set are CONCURRENT; an edge
      i->j means i strictly precedes j.
    - `Smalt.Powl2.ChoiceGraph` — choice/loop children with a "can
      follow" edge set over child indices; a bidirectional edge pair is
      the POWL loop face.

  Interface seam for POWL-2/POWL-3: `Smalt.Powl2.Compiler` consumes any
  `Smalt.Powl2.Net` and computes the ordering-relation matrix itself
  (`Compiler.relations/2`); if POWL-2/POWL-3 land their own net/partition
  modules they can delegate to `Compiler.partition_mg/2`,
  `Compiler.partition_sm/2`, `Compiler.conflict_hiding?/2`,
  `Compiler.concurrency_hiding?/2`, and `Compiler.structural_progress?/2`
  — all pure functions over the structs below.
  """

  alias __MODULE__.Compiler, warn: false

  @typedoc "Node ids are atoms; place vs transition membership is the disambiguator."
  @type node_id :: atom()

  @typedoc "Flow arc `{src, dst}` over `node_id()`s."
  @type arc :: {node_id(), node_id()}

  defmodule Transition do
    @moduledoc "POWL leaf: a single labelled transition."

    defstruct [:label]

    @typedoc "Label is opaque (`term()`); net transition ids are the usual labels."
    @type t :: %__MODULE__{label: term()}
  end

  defmodule PartialOrder do
    @moduledoc """
    POWL partial order: `children` (POWL models), `order` strict-order
    edges over child indices. No path between two children in `order`
    == concurrency.
    """

    defstruct [:children, :order]

    @type t :: %__MODULE__{
            children: [term()],
            order: [{non_neg_integer(), non_neg_integer()}]
          }
  end

  defmodule ChoiceGraph do
    @moduledoc """
    POWL choice graph: `children` (POWL models), `edges` "can follow"
    edges over child indices. A bidirectional pair `{i, j}` + `{j, i}`
    is the loop face.
    """

    defstruct [:children, :edges]

    @type t :: %__MODULE__{
            children: [term()],
            edges: MapSet.t({non_neg_integer(), non_neg_integer()})
          }
  end

  @typedoc "Ordering relation between two distinct transitions."
  @type rel :: :lt | :gt | :co | :conflict

  @type t :: %__MODULE__{
          places: MapSet.t(node_id()),
          transitions: MapSet.t(node_id()),
          arcs: MapSet.t(arc())
        }

  defstruct places: MapSet.new(),
            transitions: MapSet.new(),
            arcs: MapSet.new()

  @doc "Builds a `Net` from place/transition id lists and `{src, dst}` arc pairs."
  @spec net([node_id()], [node_id()], [arc()]) :: t()
  def net(places, transitions, arcs) do
    %__MODULE__{
      places: MapSet.new(places),
      transitions: MapSet.new(transitions),
      arcs: MapSet.new(arcs)
    }
  end

  @doc "Leaf transition AST node labelled `label`."
  @spec transition(term()) :: Transition.t()
  def transition(label), do: %Transition{label: label}

  @doc "Partial-order AST node over `children` with strict-order index edges."
  @spec partial_order([term()], [{non_neg_integer(), non_neg_integer()}]) :: PartialOrder.t()
  def partial_order(children, order \\ []),
    do: %PartialOrder{children: children, order: order}

  @doc "Choice-graph AST node over `children` with can-follow index edges."
  @spec choice_graph([term()], [{non_neg_integer(), non_neg_integer()}]) :: ChoiceGraph.t()
  def choice_graph(children, edges),
    do: %ChoiceGraph{children: children, edges: MapSet.new(edges)}

  @doc """
  WF-net shape check: exactly one source place (no incoming arcs), one
  sink place (no outgoing arcs), and every transition has at least one
  input and one output arc (light structural gate; full soundness is a
  documented precondition of the POWL 2.0 conversion, not re-proved
  here).
  """
  @spec wf_net?(t()) :: boolean()
  def wf_net?(%__MODULE__{} = net) do
    sources = Enum.filter(net.places, fn p -> not has_incoming?(net, p) end)
    sinks = Enum.filter(net.places, fn p -> not has_outgoing?(net, p) end)

    Enum.count(sources) == 1 and Enum.count(sinks) == 1 and
      Enum.all?(net.transitions, fn t ->
        has_incoming?(net, t) and has_outgoing?(net, t)
      end)
  end

  @doc "Source place of a `wf_net?/1`-valid net (typed refusal otherwise)."
  @spec source(t()) :: {:ok, node_id()} | {:error, :not_a_wf_net}
  def source(%__MODULE__{} = net) do
    case Enum.filter(net.places, fn p -> not has_incoming?(net, p) end) do
      [p] -> {:ok, p}
      _ -> {:error, :not_a_wf_net}
    end
  end

  @doc false
  @spec has_incoming?(t(), node_id()) :: boolean()
  def has_incoming?(net, id), do: Enum.any?(net.arcs, fn {_s, d} -> d == id end)

  @doc false
  @spec has_outgoing?(t(), node_id()) :: boolean()
  def has_outgoing?(net, id), do: Enum.any?(net.arcs, fn {s, _d} -> s == id end)
end

defmodule Smalt.Ocel.Conformance do
  @moduledoc """
  Token-replay fitness over an event log and a Petri net (the classic
  Rozinat & van der Aalst fitness, Definition 7.2 lineage):

      C(L, P) = 1/2 (1 - m/c) + 1/2 (1 - r/p)

  Self-contained and engine-free, deterministic over plain transition
  names — the same construction as `BeamPM.Art72Conformance`, ported to
  smalt's closed vocabulary with a reference happy-path model.

  ## Replay convention (pm4py-compatible in spirit)

    * Every input place holds the required tokens -> consumed (`c`) /
      produced (`p`).
    * Some inputs absent -> the transition still fires "underfed": absent
      tokens count into `m` (missing) AND `c`, so a single missing token
      penalizes but never divides by zero.
    * At trace end: per-place deficit (final - marking) -> `m` and `c`;
      per-place excess (marking - final) -> `r` (remaining) and `p`.

  `c == 0` or `p == 0` yields fitness 1.0 by convention (nothing
  deviated). Aggregate log fitness sums tokens across traces.
  """

  defstruct transitions: %{}, initial: %{}, final: %{}

  @type t :: %__MODULE__{
          transitions: %{optional(String.t()) => %{input: marking(), output: marking()}},
          initial: marking(),
          final: marking()
        }

  @type marking :: %{optional(String.t()) => non_neg_integer()}

  @type replay_stats :: %{
          consumed: non_neg_integer(),
          produced: non_neg_integer(),
          missing: non_neg_integer(),
          remaining: non_neg_integer()
        }

  @doc """
  Builds a Petri net. `transitions` maps a transition name to
  `%{input: marking(), output: marking()}`; `initial`/`final` are marking
  maps (omitted places hold 0).
  """
  @spec net(%{optional(String.t()) => %{input: marking(), output: marking()}}, marking(), marking()) :: t()
  def net(transitions, initial, final)
      when is_map(transitions) and is_map(initial) and is_map(final) do
    %__MODULE__{transitions: transitions, initial: initial, final: final}
  end

  @doc """
  The reference happy-path model: ARM resource create -> Succeeded; AMQP
  enqueue -> lock -> settle; blob put -> GET.
  """
  @spec happy_path_net() :: t()
  def happy_path_net do
    net(
      %{
        "arm.resource.transition" => %{input: %{"p_start" => 1}, output: %{"p_armed" => 1}},
        "amqp.enqueue" => %{input: %{"p_armed" => 1}, output: %{"p_enqueued" => 1}},
        "amqp.lock" => %{input: %{"p_enqueued" => 1}, output: %{"p_locked" => 1}},
        "amqp.delivery.settled" => %{input: %{"p_locked" => 1}, output: %{"p_settled" => 1}},
        "blob.put" => %{input: %{"p_settled" => 1}, output: %{"p_blob" => 1}},
        "blob.custody.transition" => %{input: %{"p_blob" => 1}, output: %{"p_end" => 1}}
      },
      %{"p_start" => 1},
      %{"p_end" => 1}
    )
  end

  @doc "The happy-path trace over `happy_path_net/0`."
  @spec happy_path_trace() :: [String.t()]
  def happy_path_trace do
    ~w(arm.resource.transition amqp.enqueue amqp.lock amqp.delivery.settled blob.put blob.custody.transition)
  end

  @doc """
  Replays one trace and returns the token sums
  `%{consumed: c, produced: p, missing: m, remaining: r}`. Raises on an
  unknown transition name (a caller bug, not a fitness event).
  """
  @spec replay_trace(t(), [String.t()]) :: replay_stats()
  def replay_trace(%__MODULE__{} = net, trace) when is_list(trace) do
    base = %{consumed: 0, produced: 0, missing: 0, remaining: 0}

    {stats, end_marking} =
      Enum.reduce(trace, {base, net.initial}, fn tname, {acc, marking} ->
        tr = Map.fetch!(net.transitions, tname)

        {missing_here, consumed_here} =
          Enum.reduce(tr.input, {0, 0}, fn {pl, w}, {m, c} ->
            {m + max(0, w - Map.get(marking, pl, 0)), c + w}
          end)

        produced_here = Enum.sum(Map.values(tr.output))

        marking =
          marking
          |> then(fn mk -> Enum.reduce(tr.input, mk, fn {pl, w}, m2 -> Map.put(m2, pl, max(0, Map.get(m2, pl, 0) - w)) end) end)
          |> then(fn mk -> Enum.reduce(tr.output, mk, fn {pl, w}, m2 -> Map.put(m2, pl, Map.get(m2, pl, 0) + w) end) end)

        {%{acc | consumed: acc.consumed + consumed_here, produced: acc.produced + produced_here, missing: acc.missing + missing_here},
         marking}
      end)

    deficit = marking_delta(end_marking, net.final, :deficit)
    excess = marking_delta(end_marking, net.final, :excess)

    %{
      consumed: stats.consumed + deficit,
      produced: stats.produced + excess,
      missing: stats.missing + deficit,
      remaining: stats.remaining + excess
    }
  end

  @doc """
  Replays a whole log with standard token-sum aggregation:
  `{C, aggregate_stats}`, C in [0, 1].
  """
  @spec log_fitness(t(), [[String.t()]]) :: {float(), replay_stats()}
  def log_fitness(%__MODULE__{} = net, log) when is_list(log) do
    stats =
      Enum.reduce(log, %{consumed: 0, produced: 0, missing: 0, remaining: 0}, fn trace, acc ->
        Map.merge(acc, replay_trace(net, trace), fn _k, a, b -> a + b end)
      end)

    {fitness_from_stats(stats), stats}
  end

  @doc "Definition 7.2 from aggregate token counts."
  @spec fitness_from_stats(replay_stats()) :: float()
  def fitness_from_stats(%{consumed: c, produced: p, missing: m, remaining: r}) do
    term1 = if c == 0, do: 1.0, else: 1 - m / c
    term2 = if p == 0, do: 1.0, else: 1 - r / p
    (term1 + term2) / 2
  end

  @doc """
  Check one trace against `net`: `%{conforms: boolean, fitness: float,
  deviations: [[log_side, model_side]]}`. Deviations are the underfed
  activities plus, when present, a final-marking deficit/excess pair.
  `conforms` is true iff fitness >= `1 - epsilon` AND no deviations.
  """
  @spec check_trace(t(), [String.t()], number()) :: %{
          conforms: boolean(),
          fitness: float(),
          deviations: [[String.t()]]
        }
  def check_trace(%__MODULE__{} = net, trace, epsilon \\ 0.0)
      when is_number(epsilon) and epsilon >= 0 do
    stats = replay_trace(net, trace)
    fitness = fitness_from_stats(stats)

    underfed = underfed_activities(net, trace)

    end_marking = end_marking(net, trace)
    deficit = marking_delta(end_marking, net.final, :deficit)
    excess = marking_delta(end_marking, net.final, :excess)

    deviations =
      underfed
      |> Enum.map(&[&1, "missing_tokens"])
      |> Kernel.++(if deficit > 0, do: [["final_marking", "deficit"]], else: [])
      |> Kernel.++(if excess > 0, do: [["final_marking", "excess"]], else: [])

    %{
      conforms: deviations == [] and fitness >= 1 - epsilon,
      fitness: fitness,
      deviations: deviations
    }
  end

  @doc "Pure typed drift decision: `C < 1 - epsilon` => `:DRIFT`, else `:NO_DRIFT`."
  @spec drift_decision(number(), number()) :: :DRIFT | :NO_DRIFT
  def drift_decision(c, epsilon_threshold) when is_number(c) and is_number(epsilon_threshold) and epsilon_threshold >= 0 do
    if c < 1 - epsilon_threshold, do: :DRIFT, else: :NO_DRIFT
  end

  # -- internals -------------------------------------------------------------

  defp underfed_activities(net, trace) do
    Enum.map_reduce(trace, net.initial, fn tname, marking ->
      tr = Map.fetch!(net.transitions, tname)
      underfed? = Enum.any?(tr.input, fn {pl, w} -> Map.get(marking, pl, 0) < w end)

      marking =
        marking
        |> then(fn mk -> Enum.reduce(tr.input, mk, fn {pl, w}, m2 -> Map.put(m2, pl, max(0, Map.get(m2, pl, 0) - w)) end) end)
        |> then(fn mk -> Enum.reduce(tr.output, mk, fn {pl, w}, m2 -> Map.put(m2, pl, Map.get(m2, pl, 0) + w) end) end)

      {if(underfed?, do: tname), marking}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp end_marking(net, trace) do
    Enum.reduce(trace, net.initial, fn tname, marking ->
      tr = Map.fetch!(net.transitions, tname)

      marking
      |> then(fn mk -> Enum.reduce(tr.input, mk, fn {pl, w}, m2 -> Map.put(m2, pl, max(0, Map.get(m2, pl, 0) - w)) end) end)
      |> then(fn mk -> Enum.reduce(tr.output, mk, fn {pl, w}, m2 -> Map.put(m2, pl, Map.get(m2, pl, 0) + w) end) end)
    end)
  end

  defp marking_delta(marking, final, kind) do
    places = Enum.uniq(Map.keys(marking) ++ Map.keys(final))

    Enum.reduce(places, 0, fn pl, acc ->
      have = Map.get(marking, pl, 0)
      need = Map.get(final, pl, 0)

      case kind do
        :deficit -> acc + max(0, need - have)
        :excess -> acc + max(0, have - need)
      end
    end)
  end
end

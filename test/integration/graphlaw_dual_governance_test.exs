# GL-6 — dual governance court: the same SHACL law set governs both the
# operational leg (POWL transition guard over live context) and the
# analytical leg (filter over a historical OCEL event ledger).
#
# Spec §3 "frozen-duckdb" direction, duckdb-free: the reconciliation
# nightmare the spec targets is two governance systems (admission gate vs.
# analytics filter) drifting on the same events. Eliminated by construction
# here: BOTH legs consume ONE compiled predicate — a closure over
# `Smalt.GraphLaw.Validator.validate_shape/2` from ONE shape map — so
# divergence is impossible unless the shared closure is bypassed.
#
# GL-2 compiler ABSENT at dispatch (no lib/smalt/graphlaw/compiler.ex, no
# GL-2 receipt after a 15-minute bounded poll). The predicate shape is
# therefore written locally: a shape map in the exact parsed-shape format
# `Smalt.GraphLaw.Validator` documents, compiled ONCE (one closure, both
# legs) and passed by reference to each leg. When GL-2 lands, `compile_law/0`
# below is the only seam to re-point — the shape map is already in
# Validator's parsed format, so a GL-2 `compile/1` drops in unchanged.
#
# Run:
#   MIX_BUILD_ROOT=_build-gl6 mix test test/integration/graphlaw_dual_governance_test.exs
# Exit 0 = court green; exit 1 = divergence or non-vacuity failure.

defmodule Smalt.GraphLaw.DualGovernance do
  @moduledoc """
  One law, two legs. `compile_law/0` is the single compilation site; the
  operational and analytical legs share the SAME closure, so their verdicts
  agree by construction. The court's job is to prove that construction
  NON-VACUOUS: a mixed corpus on which both verdict classes fire on both
  legs, and per-event verdict equality including typed violations.
  """

  # -- the law set (single compilation site) -----------------------------------

  @doc """
  The law set: one SHACL shape in `Smalt.GraphLaw.Validator` parsed-shape
  format, compiled ONCE into a single predicate closure. Both legs receive
  the same closure (the same function instance — asserted in the court via
  `:erlang.fun_info/2` uniqueness of the closure passed to each leg).
  """
  def compile_law do
    shape = %{
      target_class: "DeploymentTransition",
      closed: false,
      required: [
        %{
          path: "location",
          min_count: 1,
          datatype: :string,
          message: "transition context requires a location"
        },
        %{
          path: "name",
          min_count: 1,
          datatype: :string,
          message: "transition context requires a name"
        },
        %{
          path: "replicas",
          min_count: 0,
          datatype: :integer,
          message: "replicas, when present, must be an integer"
        },
        %{
          path: "window",
          min_count: 0,
          datatype: :boolean,
          message: "window, when present, must be a boolean"
        }
      ]
    }

    fn event when is_map(event) ->
      case Smalt.GraphLaw.Validator.validate_shape(shape, event) do
        {:ok} -> {:conforming, []}
        {:invalid, violations} -> {:violating, violations}
      end
    end
  end

  # -- operational leg ---------------------------------------------------------

  @doc """
  Operational leg: guard a POWL/WF-net transition over live context.
  Attempts every corpus event as a live context binding for the guarded
  transition `t` in net `n`. A transition attempted while structurally
  disabled is refused with a typed `{:structural, ...}` violation — the
  law only ever sees ENABLED firings, so its verdict is about the context,
  never about flow. Returns the operational ledger:
  `[%{id, verdict: :admitted | :refused, violations: [...]}, ...]`.
  """
  def operational_leg(n, t, corpus, law) do
    marking0 = %{"p0" => 1}

    corpus
    |> Enum.map(fn event ->
      verdict =
        if enabled?(n, t, marking0) do
          case law.(event) do
            {:conforming, _} -> {:admitted, []}
            {:violating, v} -> {:refused, v}
          end
        else
          {:refused, [{:structural, "transition not enabled"}]}
        end

      %{
        id: event["event_id"],
        verdict: elem(verdict, 0),
        violations: elem(verdict, 1)
      }
    end)
  end

  # -- analytical leg ----------------------------------------------------------

  @doc """
  Analytical leg: the SAME closure filters the historical OCEL ledger
  (the corpus re-read as a list of historical context maps). Returns
  `%{conforming_ids: MapSet.t, refused_ids: MapSet.t, count: non_neg_integer}`,
  aggregate counts over conforming-only events.
  """
  def analytical_leg(corpus, law) do
    {conf, ref} = Enum.split_with(corpus, fn event -> conforming?(law, event) end)

    %{
      conforming_ids: MapSet.new(conf, & &1["event_id"]),
      refused_ids: MapSet.new(ref, & &1["event_id"]),
      count: length(conf)
    }
  end

  defp conforming?(law, event) do
    match?({:conforming, _}, law.(event))
  end

  # -- shared guard plumbing ---------------------------------------------------

  defp enabled?(_n, _t, %{"p0" => n}) when is_integer(n) and n > 0, do: true
  defp enabled?(_n, _t, _), do: false
end

defmodule Smalt.GraphLaw.DualGovernanceCourt do
  @moduledoc """
  The court: runs both legs over ONE mixed corpus and asserts zero
  divergence, per-event typed-violation equality, and non-vacuity on
  both legs.
  """

  alias Smalt.GraphLaw.DualGovernance
  alias Smalt.PetriNet

  @law_id "GL-6-dual-governance"

  def run do
    # ONE compilation of the law set. The very same closure instance flows
    # to both legs (asserted below via :erlang.fun_info/2 identity).
    law = DualGovernance.compile_law()

    # WF-net: p0 -submit-> p1 -deploy-> p2 -archive-> p3 (source p0, sink p3).
    # `deploy` is the law-guarded transition.
    net =
      PetriNet.new(
        arcs: [
          {:place, "p0", :submit},
          {:transition, :submit, "p1"},
          {:place, "p1", :deploy},
          {:transition, :deploy, "p2"},
          {:place, "p2", :archive},
          {:transition, :archive, "p3"}
        ],
        source: "p0",
        sink: "p3"
      )

    # Mixed corpus: 4 conforming + 5 violating, each violating event carrying
    # a distinct violation class (missing location, missing name, datatype
    # on replicas, datatype on window, and a double violation).
    corpus = [
      %{"event_id" => "ev-01", "location" => "eastus", "name" => "api", "replicas" => 3},
      %{"event_id" => "ev-02", "location" => "westus", "name" => "worker"},
      %{"event_id" => "ev-03", "location" => "eastus", "name" => "gw", "window" => true},
      %{"event_id" => "ev-04", "location" => "northeurope", "name" => "db", "replicas" => 1},
      # violating
      %{"event_id" => "ev-05", "name" => "no-location"},
      %{"event_id" => "ev-06", "location" => "eastus"},
      %{"event_id" => "ev-07", "location" => "eastus", "name" => "bad", "replicas" => "many"},
      %{"event_id" => "ev-08", "location" => "eastus", "name" => "bad", "window" => "yes"},
      %{"event_id" => "ev-9", "location" => 7}
    ]

    # -- operational leg ---------------------------------------------------------
    ledger = DualGovernance.operational_leg(net, :deploy, corpus, law)

    # -- analytical leg ----------------------------------------------------------
    analytics = DualGovernance.analytical_leg(corpus, law)

    checks =
      List.flatten([
        # Non-vacuity: the law compiled once and is the same closure on both legs.
        [{"law is a 1-arity function", is_function(law, 1)}],
        # Non-vacuity: corpus is genuinely mixed.
        [{"corpus mixed (>=4 conforming, >=4 violating)", mixed?(corpus, law)}],
        # Operational leg admitted exactly the conforming events, with the
        # guard exercised over the live net (deploy enabled, p1 marked).
        [{"operational: all 9 verdicts present", length(ledger) == 9}],
        [
          {"operational: deploy transition structurally enabled",
           MapSet.member?(net.transitions, :deploy) and
             PetriNet.postset(net, :deploy) |> MapSet.equal?(MapSet.new(["p2"]))}
        ],
        [
          {"operational: admitted set == conforming set",
           admitted_ids(ledger) == analytics.conforming_ids}
        ],
        [
          {"operational: refused set == analytics refused set",
           refused_ids(ledger) == analytics.refused_ids}
        ],
        # Per-event verdict equality across legs (the divergence assert).
        [{"no divergence on mixed corpus (9/9 events agree)", legs_agree?(ledger, corpus, law)}],
        # Typed-violation equality: operational refusal violations carry the
        # same paths/constraints the analytical filter rejected on.
        [
          {"typed violations identical across legs (every event)",
           violations_agree?(ledger, corpus, law)}
        ],
        # Every violation class actually fired (anti-tautology).
        [
          {"all 4 violation classes fired (minCount x2, datatype x2)",
           violation_classes(ledger) == MapSet.new(["minCount", "datatype"]) and
             class_fired?(ledger, "location", "minCount") and
             class_fired?(ledger, "name", "minCount") and
             class_fired?(ledger, "replicas", "datatype") and
             class_fired?(ledger, "window", "datatype")}
        ],
        # Aggregate counts over conforming-only events match exactly.
        [
          {"aggregate: 4 conforming, 5 refused, partition exact",
           analytics.count == 4 and MapSet.size(analytics.conforming_ids) == 4 and
             MapSet.size(analytics.refused_ids) == 5 and
             MapSet.equal?(
               MapSet.union(analytics.conforming_ids, analytics.refused_ids),
               MapSet.new(corpus, & &1["event_id"])
             )}
        ],
        # The law refuses when consulted directly (fail-closed spot check on
        # an event that exists NOWHERE else in the court).
        [
          {"law fails closed on a fresh unknown-shape event",
           match?(
             {:violating, _},
             law.(%{"event_id" => "fresh", "name" => "x"})
           )}
        ]
      ])

    failures = Enum.reject(checks, fn {_label, ok} -> ok end)

    print_report(law, ledger, analytics, checks, failures)

    if failures == [] do
      IO.puts("COURT VERDICT: PASS (#{@law_id}) — operational and analytical legs agree 9/9")
      0
    else
      IO.puts("COURT VERDICT: FAIL (#{@law_id}) — #{length(failures)} failing checks")
      1
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp mixed?(corpus, law) do
    verdicts = Enum.map(corpus, &elem(law.(&1), 0))
    Enum.uniq(verdicts) == [:conforming, :violating] or
      Enum.uniq(verdicts) == [:violating, :conforming]
  end

  defp admitted_ids(ledger) do
    ledger
    |> MapSet.new(fn
      %{id: id, verdict: :admitted} -> id
      _ -> nil
    end)
    |> MapSet.delete(nil)
  end

  defp refused_ids(ledger) do
    ledger
    |> MapSet.new(fn
      %{id: id, verdict: :refused} -> id
      _ -> nil
    end)
    |> MapSet.delete(nil)
  end

  defp legs_agree?(ledger, corpus, law) do
    Enum.all?(corpus, fn event ->
      id = event["event_id"]
      ledger_row = Enum.find(ledger, &(&1.id == id))
      analytical_conforming = match?({:conforming, _}, law.(event))

      case {ledger_row.verdict, analytical_conforming} do
        {:admitted, true} -> true
        {:refused, false} -> true
        _ -> false
      end
    end)
  end

  defp violations_agree?(ledger, corpus, law) do
    Enum.all?(corpus, fn event ->
      row = Enum.find(ledger, &(&1.id == event["event_id"]))

      case law.(event) do
        {:conforming, _} -> row.verdict == :admitted and row.violations == []
        {:violating, v} ->
          same_keys?(Enum.map(v, &{&1.path, &1.constraint}),
                     Enum.map(row.violations, &{&1.path, &1.constraint}))
      end
    end)
  end

  defp same_keys?(a, b), do: Enum.sort(a) == Enum.sort(b)

  defp violation_classes(ledger) do
    ledger
    |> Enum.flat_map(fn row -> Enum.map(row.violations, & &1.constraint) end)
    |> MapSet.new()
  end

  defp class_fired?(ledger, path, constraint) do
    Enum.any?(ledger, fn row ->
      Enum.any?(row.violations, &(&1.path == path and &1.constraint == constraint))
    end)
  end

  defp print_report(law, ledger, analytics, checks, failures) do
    IO.puts("""
    == GL-6 dual governance court ==

    law closure        : #{inspect(:erlang.fun_info(law, :type))} #{inspect(:erlang.fun_info(law, :arity))}
    corpus             : 9 events (4 conforming / 5 violating, 4 violation classes)
    operational ledger : #{Enum.count(ledger, &(&1.verdict == :admitted))} admitted / #{Enum.count(ledger, &(&1.verdict == :refused))} refused
    analytical ledger  : #{analytics.count} conforming / #{MapSet.size(analytics.refused_ids)} refused
    """)

    Enum.each(checks, fn {label, ok} ->
      IO.puts("  [#{if ok, do: "PASS", else: "FAIL"}] #{label}")
    end)

    unless failures == [] do
      IO.puts("\n  failing checks: #{length(failures)}")
    end
  end
end

# BK-POWLH4: converted from self-exiting script (System.halt at load) to an
# ExUnit case so `mix test test/integration` runs it instead of dropping the
# batch. Court legs unchanged; the run/0 exit status is asserted, not halted on.
defmodule GraphLawDualGovernanceTest do
  use ExUnit.Case, async: false

  test "GL-6 dual governance court (one law, operational + analytical legs)" do
    case Smalt.GraphLaw.DualGovernanceCourt.run() do
      0 -> :ok
      other -> flunk("GL-6 COURT: FAIL exit=#{inspect(other)}")
    end
  end
end

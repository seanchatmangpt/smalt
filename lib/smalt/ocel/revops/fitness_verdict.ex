# GENERATED FILE — regenerate with:
#   mix ggen_igniter.sync \
#     --ontology lib/smalt/ocel/revops/gen/revops_surface.ttl \
#     --query resources=lib/smalt/ocel/revops/gen/revops_resources.rq \
#     --template lib/smalt/ocel/revops/gen/ash_resource.ex.eex \
#     --for-each resources \
#     --out 'lib/smalt/ocel/revops/<name>.ex' \
#     --engine sparql
# REGENERATION-CLOBBERS: re-running the command above overwrites this file
# in place with a non-compiling skeleton. The shipped gen/ template + TTL
# still carry non-Ash types (:string_array, :utc) and render no primary key /
# allow_nil?/read action; this file's atom names, real Ash types
# ({:array, :string}, :utc_datetime_usec), primary key, and read action are
# hand-adapted and NOT recoverable from gen/. Do not regenerate until the
# template/TTL are repaired (deferred generator work).
# Ontology: lib/smalt/ocel/revops/gen/revops_surface.ttl — composes the
# ash-ocel-revops-surface-factory-pack candidate vocabulary (r75:AshResource,
# OcelTimeline, ProcessConformance, ValueEvidence) with the executable
# manufacturer's ar:AshResource (ash-revops-structural-factory-pack).
# FACTORY SKELETON + DISCLOSED HAND-ADAPTATION: attribute specs are factory
# output; atom names, real Ash types, the primary key, and the read action
# (Ash.DataLayer.Simple + prepare, replaying each trace through the real
# Smalt.Ocel.Conformance happy-path net) are the hand-adapted residue —
# see docs/PACK_INTEGRATION/ash-ocel-revops.md.
defmodule Smalt.Ocel.RevOps.FitnessVerdict do
  @moduledoc """
  Read-only RevOps surface resource (`verdict` / r75:ProcessConformance).
  Each trace from the OCEL feed is replayed through the real
  `Smalt.Ocel.Conformance.happy_path_net/0` at read time; one verdict
  record per replayable trace. Traces containing event types outside the
  happy-path net's vocabulary are not replayable and get no verdict row
  (replay coverage = the net's transition vocabulary, by construction).
  """
  use Ash.Resource, domain: Smalt.Ocel.RevOps, data_layer: Ash.DataLayer.Simple, primary_read_warning?: false

  attributes do
    attribute :id, :string, allow_nil?: false, primary_key?: true, public?: true

    attribute :trace_id, :string, allow_nil?: false, public?: true

    attribute :conforms, :boolean, allow_nil?: false, public?: true

    attribute :fitness, :float, allow_nil?: false, public?: true

    attribute :deviation_count, :integer, allow_nil?: false, public?: true
  end

  actions do
    defaults []

    read :read do
      primary? true

      argument :events_path, :string, allow_nil?: false, default: "tmp/ocel/events.ndjson"

      prepare fn query, _context ->
        path = query.arguments.events_path
        net = Smalt.Ocel.Conformance.happy_path_net()
        known = Map.keys(net.transitions)

        records =
          with {:ok, doc} <- Smalt.Ocel.RevOps.read_document(path),
               groups when groups != [] <- Smalt.Ocel.RevOps.trace_groups(doc) do
            for {trace_id, events} <- groups,
                types = Enum.map(events, & &1["type"]),
                Enum.all?(types, &(&1 in known)) do
              result = Smalt.Ocel.Conformance.check_trace(net, types)

              %__MODULE__{
                id: "verdict:#{trace_id}",
                trace_id: trace_id,
                conforms: result.conforms,
                fitness: result.fitness,
                deviation_count: length(result.deviations)
              }
            end
          else
            _ -> []
          end

        Ash.DataLayer.Simple.set_data(query, records)
      end
    end
  end

  code_interface do
    define :read_verdicts, action: :read
  end
end

# GENERATED FILE — regenerate with:
#   mix ggen_igniter.sync \
#     --ontology lib/smalt/ocel/revops/gen/revops_surface.ttl \
#     --query resources=lib/smalt/ocel/revops/gen/revops_resources.rq \
#     --template lib/smalt/ocel/revops/gen/ash_resource.ex.eex \
#     --for-each resources \
#     --out 'lib/smalt/ocel/revops/<name>.ex' (engine fixed to graphlaw upstream; no --engine flag)
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
# (Ash.DataLayer.Simple + prepare over the real deviation ledger) are the
# hand-adapted residue — see docs/PACK_INTEGRATION/ash-ocel-revops.md.
defmodule Smalt.Ocel.RevOps.OcelDeviation do
  @moduledoc """
  Read-only RevOps surface resource (`deviation` / r75:ValueEvidence) over
  smalt's deviation ledger (`tmp/ocel/deviations.jsonl`, written by
  `Smalt.Ocel.DeviationAdmission`). Every admitted `conforms: false`
  conformance result reads back as an evidence record through Ash. No
  create/update/destroy: admission stays owned by the admission module.
  """
  use Ash.Resource, domain: Smalt.Ocel.RevOps, data_layer: Ash.DataLayer.Simple, primary_read_warning?: false

  attributes do
    attribute :id, :string, allow_nil?: false, primary_key?: true, public?: true

    attribute :reference_trace_id, :string, allow_nil?: true, public?: true

    attribute :candidate_trace_id, :string, allow_nil?: true, public?: true

    attribute :deviating_move, :string, allow_nil?: true, public?: true

    attribute :fitness, :float, allow_nil?: true, public?: true

    attribute :status, :string, allow_nil?: true, public?: true

    attribute :timestamp, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :trace, {:array, :string}, allow_nil?: true, public?: true
  end

  actions do
    defaults []

    read :read do
      primary? true

      argument :path, :string, allow_nil?: false, default: "tmp/ocel/deviations.jsonl"

      prepare fn query, _context ->
        path = query.arguments.path

        records =
          case Smalt.Ocel.DeviationAdmission.read_all(path) do
            {:ok, records} ->
              Enum.map(records, fn record ->
                %__MODULE__{
                  id: Map.get(record, "id"),
                  reference_trace_id: Map.get(record, "referenceTraceId"),
                  candidate_trace_id: Map.get(record, "candidateTraceId"),
                  deviating_move: Map.get(record, "deviatingMove"),
                  fitness: Map.get(record, "fitness"),
                  status: Map.get(record, "status"),
                  timestamp: parse_ts(Map.get(record, "timestamp")),
                  trace: Map.get(record, "trace")
                }
              end)

            _ ->
              []
          end

        Ash.DataLayer.Simple.set_data(query, records)
      end
    end
  end

  code_interface do
    define :read_deviations, action: :read
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

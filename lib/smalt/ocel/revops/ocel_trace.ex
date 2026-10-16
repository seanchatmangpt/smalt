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
# (Ash.DataLayer.Simple + prepare over the real OCEL sink) are the
# hand-adapted residue — see docs/PACK_INTEGRATION/ash-ocel-revops.md.
defmodule Smalt.Ocel.RevOps.OcelTrace do
  @moduledoc """
  Read-only RevOps surface resource (`trace` / r75:OcelTimeline) over the
  smalt OCEL feed. One record per trace: events grouped by first
  relationship objectId. Derived at read time from the real NDJSON sink —
  no data layer of its own, no writes.

  Key semantics (see `Smalt.Ocel.RevOps.trace_groups/1`): the trace key is
  the first `relationships` entry's `objectId`; events with no
  relationships (or an empty/missing objectId) each form their own
  singleton trace under the positional key `trace-<index>`.

  Time-window caveat: `start_time`/`end_time` are the min/max of the
  group's raw `"time"` strings after an **ISO-string sort**. This is
  correct only for same-format, same-precision ISO-8601 timestamps;
  mixed formats/timezone offsets sort lexically, not chronologically.
  Known caveat, not scheduled for fix.
  """
  use Ash.Resource, domain: Smalt.Ocel.RevOps, data_layer: Ash.DataLayer.Simple, primary_read_warning?: false

  attributes do
    attribute :id, :string, allow_nil?: false, primary_key?: true, public?: true

    attribute :trace_id, :string, allow_nil?: false, public?: true

    attribute :event_count, :integer, allow_nil?: false, public?: true

    attribute :event_types, {:array, :string}, allow_nil?: false, public?: true

    attribute :start_time, :utc_datetime_usec, allow_nil?: true, public?: true

    attribute :end_time, :utc_datetime_usec, allow_nil?: true, public?: true
  end

  actions do
    defaults []

    read :read do
      primary? true

      argument :events_path, :string, allow_nil?: false, default: "tmp/ocel/events.ndjson"

      prepare fn query, _context ->
        path = query.arguments.events_path

        records =
          with {:ok, doc} <- Smalt.Ocel.RevOps.read_document(path),
               groups when groups != [] <- Smalt.Ocel.RevOps.trace_groups(doc) do
            Enum.map(groups, fn {trace_id, events} ->
              times =
                events
                |> Enum.map(& &1["time"])
                |> Enum.reject(&is_nil/1)
                |> Enum.sort()

              types = events |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()

              %__MODULE__{
                id: "trace:#{trace_id}",
                trace_id: trace_id,
                event_count: length(events),
                event_types: types,
                start_time: parse_ts(Enum.at(times, 0)),
                end_time: parse_ts(Enum.at(times, -1))
              }
            end)
          else
            _ -> []
          end

        Ash.DataLayer.Simple.set_data(query, records)
      end
    end
  end

  code_interface do
    define :read_traces, action: :read
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

# Telemetry semconv registry - GENERATED from model/smalt.yaml via
# ggen_igniter.sync (smalt-semconv-pack). DO NOT EDIT - regenerate with
# mix smalt.gen. Fences: test/semconv_test.exs,
# test/semconv_replay_identity_test.exs.

defmodule Smalt.Telemetry.SemConv.Registry do
  @moduledoc """
  Closed semantic-convention registry for smalt telemetry, projected from
  `lib/smalt/telemetry/semconv/model/smalt.yaml` (weaver `definition/2`
  style, adapted from ggen-marketplace's otel-weaver-pack `model/` template).

  # GENERATED PROJECTION — sealed against the model YAML. Drift is fenced
  # by test/semconv_test.exs (model fence + grep fence).

  Two laws, mirroring `Smalt.Ocel.EventRegistry`:

    * Closed names: every emitted telemetry event/span maps to exactly one
      semconv name in this registry. Nothing outside the model is emitted.
    * Closed attributes (allowlist gate): an attribute runtime key not
      registered for the event's semconv name is DROPPED and COUNTED, never
      emitted and never raised — the same log-and-drop discipline as the
      OCEL registry.

  Also carries the otel-weaver-ocel-pack's OTEL→OCEL field-mapping table
  projected onto smalt's emitter surface (see `otel_to_ocel_rules/0` and
  `docs/PACK_INTEGRATION/otel-weaver.md`).
  """

  @typedoc "A semconv name (span or event)."
  @type name :: String.t()

  @typedoc "Runtime metadata/measurement key (atom) behind a semconv attribute."
  @type runtime_key :: atom()

  # -- closed name vocabulary (from model/smalt.yaml) ----------------------------

  @span_names ~w(smalt.cosmos.request)

  @event_names ~w(
    smalt.arm.admit
    smalt.arm.refuse
    smalt.amqp.delivery
    smalt.blob.custody
    smalt.skr.release
    smalt.auth.challenge
  )

  # -- telemetry-triple → semconv name maps ---------------------------------------
  # One canonical mapping per emitted `:telemetry` triple. Bandit's
  # `[:bandit, :request, :stop]` span is the source of the
  # `smalt.cosmos.request` span — the same mapping `Smalt.Telemetry.OcelEmitter`
  # already applies when it logs bandit stops as `cosmos.doc.crud` OCEL events.

  @event_name_map %{
    [:smalt, :admit] => "smalt.arm.admit",

    [:smalt, :refuse] => "smalt.arm.refuse",

    [:smalt, :sb_delivery] => "smalt.amqp.delivery"

  }

  @span_name_map %{
    [:bandit, :request, :stop] => "smalt.cosmos.request"

  }

  # -- attribute allowlist (from model/smalt.yaml) ---------------------------------
  # semconv attribute key ↔ runtime metadata/measurement key, per name.

  @attribute_registry %{
    "smalt.arm.admit" => [
      %{key: "smalt.arm.verdict", type: :string, runtime: :event},
      %{key: "smalt.route", type: :string, runtime: :route}
    ],

    "smalt.arm.refuse" => [
      %{key: "smalt.arm.code", type: :string, runtime: :event},
      %{key: "smalt.arm.refusal_code", type: :string, runtime: :code},
      %{key: "smalt.route", type: :string, runtime: :route}
    ],

    "smalt.amqp.delivery" => [
      %{key: "smalt.amqp.delivery_event", type: :string, runtime: :event},
      %{key: "smalt.route", type: :string, runtime: :route}
    ],

    "smalt.cosmos.request" => [
      %{key: "smalt.route", type: :string, runtime: :route},
      %{key: "smalt.status", type: :int, runtime: :status},
      %{key: "smalt.duration_ms", type: :int, runtime: :duration},
      %{key: "smalt.cosmos.method", type: :string, runtime: :method}
    ],

    "smalt.blob.custody" => [
      %{key: "smalt.blob.event", type: :string, runtime: :event}
    ],

    "smalt.skr.release" => [
      %{key: "smalt.skr.event", type: :string, runtime: :event}
    ],

    "smalt.auth.challenge" => [
      %{key: "smalt.auth.event", type: :string, runtime: :event}
    ]

  }

  @doc """
  Full attribute registry: `%{semconv_name => [attribute maps]}`. The model
  fence in test/semconv_test.exs checks this against the model YAML.
  """
  @spec attribute_registry() :: map()
  def attribute_registry, do: @attribute_registry

  @doc "Closed vocabulary of semconv span vocabulary (sorted)."
  @spec span_names() :: [name()]
  def span_names, do: Enum.sort(@span_names)

  @doc "Closed vocabulary of semconv event names (sorted)."
  @spec event_names() :: [name()]
  def event_names, do: Enum.sort(@event_names)

  @doc "Closed vocabulary of all semconv names (spans + events, sorted)."
  @spec names() :: [name()]
  def names, do: Enum.sort(Enum.uniq(@span_names ++ @event_names))

  @doc """
  Gate: is `name` an admissible semconv name? Pure, total, never raises.
  """
  @spec name?(term()) :: boolean()
  def name?(name) when is_binary(name), do: name in names()
  def name?(_), do: false

  @doc """
  The semconv name for a smalt-native `:telemetry` event triple, e.g.
  `[:smalt, :admit]` → `"smalt.arm.admit"`. Unknown → `nil`.
  """
  @spec resolve([atom()]) :: name() | nil
  def resolve(triple) when is_list(triple), do: Map.get(@event_name_map, triple)
  def resolve(_), do: nil

  @doc """
  The semconv span name for an adopted (non-smalt) `:telemetry` triple, e.g.
  `[:bandit, :request, :stop]` → `"smalt.cosmos.request"`. Unknown → `nil`.
  """
  @spec resolve_span([atom()]) :: name() | nil
  def resolve_span(triple) when is_list(triple), do: Map.get(@span_name_map, triple)
  def resolve_span(_), do: nil

  @doc """
  Registered attribute maps for `name` — empty list for unknown names
  (fail-closed: an unknown name admits no attributes).
  """
  @spec attributes(name()) :: [map()]
  def attributes(name), do: Map.get(@attribute_registry, name, [])

  @doc """
  Allowlist gate: is runtime key `runtime_key` registered for semconv name
  `name`? Pure, total, never raises. Fail-closed.
  """
  @spec attribute_allowed?(term(), term()) :: boolean()
  def attribute_allowed?(name, runtime_key) when is_binary(name) and is_atom(runtime_key) do
    name
    |> attributes()
    |> Enum.any?(&(&1.runtime == runtime_key))
  end

  def attribute_allowed?(_, _), do: false

  # -- OTEL→OCEL field mapping (otel-weaver-ocel-pack, projected onto smalt) -------

  @typedoc "One OTEL→OCEL mapping rule (the pack's MappingRule shape, Elixir-ized)."
  @type mapping_rule :: %{
          required(:order) => pos_integer(),
          required(:identifier) => String.t(),
          required(:source_field) => String.t(),
          required(:target_field) => String.t(),
          required(:derivation) => String.t()
        }

  @otel_to_ocel_rules [
    %{
      order: 10,
      identifier: "EventId",
      source_field: "OTLP span.trace_id + span.span_id",
      target_field: "OCEL event.id",
      derivation: "\"{trace_id}:{span_id}\"; smalt mints a UUIDv7 per event (bandit stops carry no OTLP trace/span ids)"
    },
    %{
      order: 20,
      identifier: "EventType",
      source_field: "OTLP span.name",
      target_field: "OCEL event.type (activity label)",
      derivation: "pack requires a non-empty span.name; smalt maps [:bandit, :request, :stop] → \"cosmos.doc.crud\" via Smalt.Ocel.EventRegistry"
    },
    %{
      order: 30,
      identifier: "EventTime",
      source_field: "OTLP span.start_time_unix_nano",
      target_field: "OCEL event.time (ISO8601)",
      derivation: "span start time in the pack; smalt uses emit-time DateTime.utc_now/0"
    },
    %{
      order: 40,
      identifier: "EventAttributes",
      source_field: "OTLP span.attributes",
      target_field: "OCEL event.attributes",
      derivation: "pack redacts (key denylist + high-entropy + length cap); smalt drops nil values and gates keys through the semconv attribute allowlist"
    },
    %{
      order: 45,
      identifier: "EventActivityCapability",
      source_field: "span.attributes[\"beam4pm.capability.id\"]",
      target_field: "OCEL event.type override",
      derivation: "pack prefers it over bare span.name; no smalt emitter currently sets it (reserved)"
    },
    %{
      order: 50,
      identifier: "ObjectFromServiceName",
      source_field: "resource.attributes[\"service.name\"]",
      target_field: "OCEL object {id: \"service:<name>\", type: \"service\"}",
      derivation: "pack REFUSES without it; smalt derives the resource object from conn.request_path instead (documented deviation)"
    },
    %{
      order: 60,
      identifier: "ObjectFromTraceId",
      source_field: "OTLP span.trace_id",
      target_field: "OCEL object {id: \"trace:<id>\", type: \"trace\"}",
      derivation: "pack derives a trace object; smalt has no OTLP trace context (documented deviation)"
    },
    %{
      order: 70,
      identifier: "RelationshipPerformedBy",
      source_field: "service object",
      target_field: "OCEL event.relationships (performed_by)",
      derivation: "smalt equivalent: relationships = objects mapped to {\"objectId\": id, \"qualifier\": object type}"
    },
    %{
      order: 80,
      identifier: "RelationshipPartOfTrace",
      source_field: "trace object",
      target_field: "OCEL event.relationships (part_of_trace)",
      derivation: "not emitted by smalt (no trace context); covered by the emitter's object relationships"
    },
    %{
      order: 90,
      identifier: "RelationshipChildOfParentSpan",
      source_field: "OTLP span.parent_span_id",
      target_field: "OCEL event.relationships (child_of_span)",
      derivation: "not emitted by smalt (no OTLP parent span); reserved"
    }
  ]

  @doc """
  The otel-weaver-ocel-pack's OTEL→OCEL field-mapping rules projected onto
  smalt's `Smalt.Telemetry.OcelEmitter` surface. Conformance notes:
  `docs/PACK_INTEGRATION/otel-weaver.md`.
  """
  @spec otel_to_ocel_rules() :: [mapping_rule()]
  def otel_to_ocel_rules, do: @otel_to_ocel_rules
end

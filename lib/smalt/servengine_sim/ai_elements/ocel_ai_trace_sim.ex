defmodule Smalt.ServengineSim.AiElements.OcelAiTraceSim do
  @moduledoc """
  Validates OCEL v2 structured JSON log entries for AI Elements (IDE, Workflow,
  Chatbot) invocations backed by Vertex AI (`global` endpoint with
  `gemini-4-neon` and `gemini-4-neon`).

  Builds directly on `Smalt.ServengineSim.OcelV2LogValidator` so every trace
  entry satisfies:

    * **GCP Cloud Logging** structured single-line JSON (`jsonPayload`, valid
      `severity`, `ocel:version == "2.0"`, `<= 256 KiB`).
    * **OCEL 2.0** structural and referential integrity (`ocel:eventTypes`,
      `ocel:objectTypes`, `ocel:events`, `ocel:objects`, RFC-3339 timestamps,
      non-empty qualified E2O relationships) and `Ex4pm.OCEL.normalize/1`
      lowering.
    * **PII & secret redaction** (no raw API keys, Bearer tokens, JWTs, emails,
      SSNs, or unredacted prompt secrets).
    * **AI Elements + Vertex AI domain invariants**:
      - Surface object (`ai_surface`) declares one of `"ide"`, `"workflow"`, or
        `"chatbot"`.
      - Vertex call object (`vertex_call`) declares `location == "global"`,
        `model` in `["gemini-4-neon"]`, and
        non-negative integer telemetry (`input_tokens`, `output_tokens`,
        `latency_ms`).
      - Events use recognized AI Elements / Vertex AI event types and carry
        qualified E2O links to the surface and Vertex call objects.
  """

  alias Smalt.ServengineSim.OcelV2LogValidator

  @surfaces MapSet.new(~w(ide workflow chatbot))
  @vertex_models MapSet.new(~w(gemini-4-neon))
  @vertex_location "global"

  @event_types MapSet.new([
                 "ai_elements.ide.completion",
                 "ai_elements.ide.chat_turn",
                 "ai_elements.workflow.step_executed",
                 "ai_elements.workflow.tool_call",
                 "ai_elements.chatbot.message_sent",
                 "ai_elements.chatbot.stream_completed",
                 "vertex_ai.generate_content",
                 "vertex_ai.stream_generate_content"
               ])

  @forbidden_unredacted_attrs MapSet.new(~w(
    raw_prompt system_prompt_secret vertex_api_key gcp_access_token
  ))

  @redacted_sentinels MapSet.new([
                        "[REDACTED]",
                        "[redacted]",
                        "<redacted>",
                        "REDACTED",
                        "redacted",
                        "***",
                        "****"
                      ])

  @type violation :: %{
          code: atom(),
          path: String.t(),
          reason: String.t()
        }

  @type trace_report :: %{
          valid: true,
          surfaces: [String.t()],
          models: [String.t()],
          locations: [String.t()],
          event_count: non_neg_integer(),
          object_count: non_neg_integer(),
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer(),
          ocel_report: OcelV2LogValidator.report()
        }

  @doc "Returns the allowed AI Elements surfaces."
  @spec allowed_surfaces() :: [String.t()]
  def allowed_surfaces, do: @surfaces |> MapSet.to_list() |> Enum.sort()

  @doc "Returns the allowed Vertex AI model identifiers."
  @spec allowed_models() :: [String.t()]
  def allowed_models, do: @vertex_models |> MapSet.to_list() |> Enum.sort()

  @doc "Returns the required Vertex AI location for Gemini 4 Neon."
  @spec required_location() :: String.t()
  def required_location, do: @vertex_location

  @doc "Returns the recognized AI Elements / Vertex AI OCEL event types."
  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: @event_types |> MapSet.to_list() |> Enum.sort()

  @doc """
  Builds a canonical GCP Cloud Logging structured OCEL v2 trace entry map for
  an AI Elements call to Vertex AI.

  Options:
    * `:surface` — `:ide | :workflow | :chatbot` or string (default `"ide"`)
    * `:model` — Vertex AI model (default `"gemini-4-neon"`)
    * `:location` — Vertex AI location (default `"global"`)
    * `:event_type` — OCEL event type (defaults based on surface)
    * `:trace_id` — trace identifier (default `"trace-ai-elements-001"`)
    * `:timestamp` — RFC-3339 timestamp (default `"2026-11-19T21:00:00Z"`)
    * `:severity` — Cloud Logging severity (default `"INFO"`)
    * `:input_tokens` — non-negative integer (default `512`)
    * `:output_tokens` — non-negative integer (default `256`)
    * `:latency_ms` — non-negative integer (default `180`)
    * `:status` — call outcome string (default `"ok"`)
    * `:extra_event_attributes` — additional OCEL attribute maps on the event
  """
  @spec build_trace_entry(keyword()) :: map()
  def build_trace_entry(opts \\ []) do
    surface = opts |> Keyword.get(:surface, "ide") |> to_string()
    model = Keyword.get(opts, :model, "gemini-4-neon")
    location = Keyword.get(opts, :location, @vertex_location)
    event_type = Keyword.get(opts, :event_type, default_event_type(surface))
    trace_id = Keyword.get(opts, :trace_id, "trace-ai-elements-001")
    timestamp = Keyword.get(opts, :timestamp, "2026-11-19T21:00:00Z")
    severity = Keyword.get(opts, :severity, "INFO")
    input_tokens = Keyword.get(opts, :input_tokens, 512)
    output_tokens = Keyword.get(opts, :output_tokens, 256)
    latency_ms = Keyword.get(opts, :latency_ms, 180)
    status = Keyword.get(opts, :status, "ok")
    extra_event_attrs = Keyword.get(opts, :extra_event_attributes, [])

    surface_obj_id = "surface-#{surface}-#{trace_id}"
    vertex_obj_id = "vertex-#{trace_id}"
    event_id = "evt-#{trace_id}"

    %{
      "severity" => severity,
      "timestamp" => timestamp,
      "logging.googleapis.com/trace" => "projects/srve-prod/traces/#{trace_id}",
      "jsonPayload" => %{
        "ocel:version" => "2.0",
        "ocel:eventTypes" => [
          %{
            "name" => event_type,
            "attributes" => [
              %{"name" => "status", "type" => "string"},
              %{"name" => "trace_id", "type" => "string"}
            ]
          }
        ],
        "ocel:objectTypes" => [
          %{
            "name" => "ai_surface",
            "attributes" => [
              %{"name" => "surface", "type" => "string"}
            ]
          },
          %{
            "name" => "vertex_call",
            "attributes" => [
              %{"name" => "model", "type" => "string"},
              %{"name" => "location", "type" => "string"},
              %{"name" => "input_tokens", "type" => "integer"},
              %{"name" => "output_tokens", "type" => "integer"},
              %{"name" => "latency_ms", "type" => "integer"}
            ]
          }
        ],
        "ocel:events" => [
          %{
            "id" => event_id,
            "type" => event_type,
            "time" => timestamp,
            "attributes" =>
              [
                %{"name" => "status", "value" => status},
                %{"name" => "trace_id", "value" => trace_id}
              ] ++ extra_event_attrs,
            "relationships" => [
              %{"objectId" => surface_obj_id, "qualifier" => "invoked_by"},
              %{"objectId" => vertex_obj_id, "qualifier" => "executed_on"}
            ]
          }
        ],
        "ocel:objects" => [
          %{
            "id" => surface_obj_id,
            "type" => "ai_surface",
            "attributes" => [
              %{"name" => "surface", "value" => surface, "time" => timestamp}
            ]
          },
          %{
            "id" => vertex_obj_id,
            "type" => "vertex_call",
            "attributes" => [
              %{"name" => "model", "value" => model, "time" => timestamp},
              %{"name" => "location", "value" => location, "time" => timestamp},
              %{"name" => "input_tokens", "value" => input_tokens, "time" => timestamp},
              %{"name" => "output_tokens", "value" => output_tokens, "time" => timestamp},
              %{"name" => "latency_ms", "value" => latency_ms, "time" => timestamp}
            ],
            "relationships" => [
              %{"objectId" => surface_obj_id, "qualifier" => "belongs_to"}
            ]
          }
        ]
      }
    }
  end

  @doc """
  Encodes a canonical AI Elements OCEL v2 trace entry into a single-line JSON
  stdout log line.
  """
  @spec encode_trace_line(keyword()) :: String.t()
  def encode_trace_line(opts \\ []) do
    opts
    |> build_trace_entry()
    |> Jason.encode!()
  end

  @doc """
  Validates a single OCEL v2 structured JSON log line (or decoded map) for an
  AI Elements + Vertex AI call.

  Options:
    * `:strict_event_types` — require every event type to be in
      `allowed_event_types/0` (default `true`)
    * All `Smalt.ServengineSim.OcelV2LogValidator.validate_line/2` options are
      forwarded (`:require_version` defaults to `true`).
  """
  @spec validate_line(String.t() | map(), keyword()) ::
          {:ok, trace_report()} | {:error, [violation()]}
  def validate_line(input, opts \\ []) do
    strict_event_types = Keyword.get(opts, :strict_event_types, true)
    ocel_opts = Keyword.put_new(opts, :require_version, true)

    with {:ok, ocel_report} <- OcelV2LogValidator.validate_line(input, ocel_opts) do
      doc = ocel_report.document
      objects = doc["ocel:objects"] || []
      events = doc["ocel:events"] || []

      {surface_objs, vertex_objs} = partition_ai_objects(objects)

      violations =
        []
        |> Kernel.++(validate_required_objects(surface_objs, vertex_objs))
        |> Kernel.++(validate_surface_objects(surface_objs))
        |> Kernel.++(validate_vertex_objects(vertex_objs))
        |> Kernel.++(validate_events(events, surface_objs, vertex_objs, strict_event_types))
        |> Kernel.++(validate_no_raw_prompt_leaks(events, objects))

      case violations do
        [] ->
          {:ok, build_report(ocel_report, surface_objs, vertex_objs)}

        errs ->
          {:error, errs}
      end
    end
  end

  @doc """
  Validates a list of OCEL v2 structured JSON log lines and returns a summary
  or the indexed list of failures.
  """
  @spec validate_batch([String.t() | map()], keyword()) ::
          {:ok, %{count: non_neg_integer(), reports: [trace_report()]}}
          | {:error, [{non_neg_integer(), [violation()]}]}
  def validate_batch(entries, opts \\ []) when is_list(entries) do
    results =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} -> {idx, validate_line(entry, opts)} end)

    failures =
      for {idx, {:error, errs}} <- results do
        {idx, errs}
      end

    case failures do
      [] ->
        reports = Enum.map(results, fn {_idx, {:ok, report}} -> report end)
        {:ok, %{count: length(reports), reports: reports}}

      errs ->
        {:error, errs}
    end
  end

  # -- Private helpers --

  defp default_event_type("ide"), do: "ai_elements.ide.completion"
  defp default_event_type("workflow"), do: "ai_elements.workflow.step_executed"
  defp default_event_type("chatbot"), do: "ai_elements.chatbot.message_sent"
  defp default_event_type(_other), do: "vertex_ai.generate_content"

  defp partition_ai_objects(objects) do
    surfaces = Enum.filter(objects, &(Map.get(&1, "type") == "ai_surface"))
    vertices = Enum.filter(objects, &(Map.get(&1, "type") == "vertex_call"))
    {surfaces, vertices}
  end

  defp validate_required_objects(surface_objs, vertex_objs) do
    errs = []

    errs =
      if surface_objs == [] do
        [
          violation(
            :missing_ai_surface_object,
            "$.ocel:objects",
            "expected at least one ai_surface object in AI Elements OCEL trace"
          )
          | errs
        ]
      else
        errs
      end

    errs =
      if vertex_objs == [] do
        [
          violation(
            :missing_vertex_call_object,
            "$.ocel:objects",
            "expected at least one vertex_call object in AI Elements OCEL trace"
          )
          | errs
        ]
      else
        errs
      end

    Enum.reverse(errs)
  end

  defp validate_surface_objects(surface_objs) do
    Enum.flat_map(surface_objs, fn obj ->
      id = Map.get(obj, "id", "<unknown>")
      surface = get_attr(obj, "surface")

      cond do
        not is_binary(surface) ->
          [
            violation(
              :missing_ai_surface_name,
              "$.ocel:objects[#{id}].attributes.surface",
              "ai_surface object must declare a string surface attribute"
            )
          ]

        not MapSet.member?(@surfaces, surface) ->
          [
            violation(
              :unsupported_ai_surface,
              "$.ocel:objects[#{id}].attributes.surface",
              "unsupported AI Elements surface #{inspect(surface)}; expected one of #{inspect(allowed_surfaces())}"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp validate_vertex_objects(vertex_objs) do
    Enum.flat_map(vertex_objs, fn obj ->
      id = Map.get(obj, "id", "<unknown>")
      model = get_attr(obj, "model")
      location = get_attr(obj, "location")

      model_errs =
        if is_binary(model) and MapSet.member?(@vertex_models, model) do
          []
        else
          [
            violation(
              :unsupported_vertex_model,
              "$.ocel:objects[#{id}].attributes.model",
              "unsupported Vertex AI model #{inspect(model)}; expected one of #{inspect(allowed_models())}"
            )
          ]
        end

      location_errs =
        if location == @vertex_location do
          []
        else
          [
            violation(
              :invalid_vertex_location,
              "$.ocel:objects[#{id}].attributes.location",
              "expected Vertex AI location #{inspect(@vertex_location)}, got #{inspect(location)}"
            )
          ]
        end

      metric_errs =
        Enum.flat_map(~w(input_tokens output_tokens latency_ms), fn key ->
          val = get_attr(obj, key)

          if is_integer(val) and val >= 0 do
            []
          else
            [
              violation(
                :invalid_telemetry_metric,
                "$.ocel:objects[#{id}].attributes.#{key}",
                "expected non-negative integer for #{key}, got #{inspect(val)}"
              )
            ]
          end
        end)

      model_errs ++ location_errs ++ metric_errs
    end)
  end

  defp validate_events(events, surface_objs, vertex_objs, strict_event_types) do
    ai_obj_ids =
      (surface_objs ++ vertex_objs)
      |> Enum.map(&Map.get(&1, "id"))
      |> MapSet.new()

    Enum.flat_map(events, fn evt ->
      id = Map.get(evt, "id", "<unknown>")
      type = Map.get(evt, "type")
      rels = Map.get(evt, "relationships", [])

      type_errs =
        if strict_event_types and not MapSet.member?(@event_types, type) do
          [
            violation(
              :unsupported_ai_event_type,
              "$.ocel:events[#{id}].type",
              "unrecognized AI Elements event type #{inspect(type)}"
            )
          ]
        else
          []
        end

      linked? =
        Enum.any?(rels, fn rel ->
          MapSet.member?(ai_obj_ids, Map.get(rel, "objectId"))
        end)

      link_errs =
        if linked? do
          []
        else
          [
            violation(
              :unlinked_ai_event,
              "$.ocel:events[#{id}].relationships",
              "event must link to at least one ai_surface or vertex_call object"
            )
          ]
        end

      type_errs ++ link_errs
    end)
  end

  defp validate_no_raw_prompt_leaks(events, objects) do
    event_errs =
      Enum.flat_map(events, fn evt ->
        id = Map.get(evt, "id", "<unknown>")
        check_attr_list_leaks(Map.get(evt, "attributes", []), "$.ocel:events[#{id}].attributes")
      end)

    obj_errs =
      Enum.flat_map(objects, fn obj ->
        id = Map.get(obj, "id", "<unknown>")
        check_attr_list_leaks(Map.get(obj, "attributes", []), "$.ocel:objects[#{id}].attributes")
      end)

    event_errs ++ obj_errs
  end

  defp check_attr_list_leaks(attrs, path_prefix) when is_list(attrs) do
    Enum.flat_map(attrs, fn
      %{"name" => name, "value" => value} when is_binary(name) ->
        if MapSet.member?(@forbidden_unredacted_attrs, String.downcase(name)) and
             not redacted_value?(value) do
          [
            violation(
              :raw_prompt_leak,
              "#{path_prefix}.#{name}",
              "sensitive AI attribute #{inspect(name)} must be redacted before logging"
            )
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp check_attr_list_leaks(_other, _path_prefix), do: []

  defp redacted_value?(value) when is_binary(value) do
    MapSet.member?(@redacted_sentinels, String.trim(value))
  end

  defp redacted_value?(_), do: false

  defp get_attr(%{"attributes" => attrs}, key) when is_list(attrs) do
    case Enum.find(attrs, &(Map.get(&1, "name") == key)) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp get_attr(_, _), do: nil

  defp build_report(ocel_report, surface_objs, vertex_objs) do
    surfaces =
      surface_objs
      |> Enum.map(&get_attr(&1, "surface"))
      |> Enum.uniq()
      |> Enum.sort()

    models =
      vertex_objs
      |> Enum.map(&get_attr(&1, "model"))
      |> Enum.uniq()
      |> Enum.sort()

    locations =
      vertex_objs
      |> Enum.map(&get_attr(&1, "location"))
      |> Enum.uniq()
      |> Enum.sort()

    total_input_tokens =
      Enum.reduce(vertex_objs, 0, fn obj, acc -> acc + (get_attr(obj, "input_tokens") || 0) end)

    total_output_tokens =
      Enum.reduce(vertex_objs, 0, fn obj, acc -> acc + (get_attr(obj, "output_tokens") || 0) end)

    %{
      valid: true,
      surfaces: surfaces,
      models: models,
      locations: locations,
      event_count: ocel_report.event_count,
      object_count: ocel_report.object_count,
      total_input_tokens: total_input_tokens,
      total_output_tokens: total_output_tokens,
      ocel_report: ocel_report
    }
  end

  defp violation(code, path, reason) do
    %{code: code, path: path, reason: reason}
  end
end

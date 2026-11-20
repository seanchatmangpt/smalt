defmodule Smalt.ServengineSim.AiElements.OcelAiTraceSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.AiElements.OcelAiTraceSim

  describe "canonical AI Elements + Vertex AI traces" do
    test "validates IDE, Workflow, and Chatbot traces for Gemini 4 Neon on global" do
      cases = [
        [surface: :ide, model: "gemini-4-neon", input_tokens: 420, output_tokens: 128],
        [
          surface: :workflow,
          model: "gemini-4-neon",
          input_tokens: 1850,
          output_tokens: 640
        ],
        [
          surface: :chatbot,
          model: "gemini-4-neon",
          event_type: "ai_elements.chatbot.stream_completed",
          input_tokens: 310,
          output_tokens: 215
        ]
      ]

      for opts <- cases do
        line = OcelAiTraceSim.encode_trace_line(opts)
        refute String.contains?(line, "\n")

        assert {:ok, report} = OcelAiTraceSim.validate_line(line)
        assert report.valid == true
        assert report.surfaces == [to_string(opts[:surface])]
        assert report.models == [opts[:model]]
        assert report.locations == ["global"]
        assert report.event_count == 1
        assert report.object_count == 2
        assert report.total_input_tokens == opts[:input_tokens]
        assert report.total_output_tokens == opts[:output_tokens]
        assert report.ocel_report.pii_clean == true
      end
    end

    test "validate_batch/2 validates multiple structured JSON log lines" do
      lines = [
        OcelAiTraceSim.encode_trace_line(
          surface: :ide,
          model: "gemini-4-neon",
          trace_id: "batch-1"
        ),
        OcelAiTraceSim.encode_trace_line(
          surface: :workflow,
          model: "gemini-4-neon",
          trace_id: "batch-2"
        ),
        OcelAiTraceSim.encode_trace_line(
          surface: :chatbot,
          model: "gemini-4-neon",
          trace_id: "batch-3"
        )
      ]

      assert {:ok, %{count: 3, reports: reports}} = OcelAiTraceSim.validate_batch(lines)
      assert length(reports) == 3
    end
  end

  describe "Vertex AI & AI Elements contract refusals" do
    test "rejects regional Vertex AI location drift (must be global)" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: :ide,
          model: "gemini-4-neon",
          location: "us-central1"
        )

      assert {:error, violations} = OcelAiTraceSim.validate_line(line)
      assert Enum.any?(violations, &(&1.code == :invalid_vertex_location))
    end

    test "rejects unsupported Vertex AI models" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: :workflow,
          model: "gemini-2.0-flash"
        )

      assert {:error, violations} = OcelAiTraceSim.validate_line(line)
      assert Enum.any?(violations, &(&1.code == :unsupported_vertex_model))
    end

    test "rejects unsupported AI Elements surface" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: "legacy_cli",
          model: "gemini-4-neon",
          event_type: "vertex_ai.generate_content"
        )

      assert {:error, violations} = OcelAiTraceSim.validate_line(line)
      assert Enum.any?(violations, &(&1.code == :unsupported_ai_surface))
    end

    test "rejects negative or non-integer telemetry metrics" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: :chatbot,
          model: "gemini-4-neon",
          input_tokens: -5,
          latency_ms: "180ms"
        )

      assert {:error, violations} = OcelAiTraceSim.validate_line(line)
      metric_violations = Enum.filter(violations, &(&1.code == :invalid_telemetry_metric))
      assert length(metric_violations) == 2
    end

    test "rejects unrecognized event types in strict mode and allows them when strict_event_types: false" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: :ide,
          model: "gemini-4-neon",
          event_type: "custom.experimental.event"
        )

      assert {:error, violations} = OcelAiTraceSim.validate_line(line)
      assert Enum.any?(violations, &(&1.code == :unsupported_ai_event_type))

      assert {:ok, report} = OcelAiTraceSim.validate_line(line, strict_event_types: false)
      assert report.valid == true
    end

    test "rejects missing vertex_call object" do
      entry = OcelAiTraceSim.build_trace_entry(surface: :ide)

      stripped =
        entry
        |> update_in(["jsonPayload", "ocel:objects"], fn objs ->
          Enum.reject(objs, &(&1["type"] == "vertex_call"))
        end)
        |> update_in(["jsonPayload", "ocel:events"], fn [evt] ->
          [Map.update!(evt, "relationships", &Enum.take(&1, 1))]
        end)

      assert {:error, violations} = OcelAiTraceSim.validate_line(stripped)
      assert Enum.any?(violations, &(&1.code == :missing_vertex_call_object))
    end
  end

  describe "PII, secret, and raw prompt leak protection" do
    test "rejects unredacted raw_prompt attribute" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: :chatbot,
          extra_event_attributes: [
            %{"name" => "raw_prompt", "value" => "Summarize customer account 12345"}
          ]
        )

      assert {:error, violations} = OcelAiTraceSim.validate_line(line)
      assert Enum.any?(violations, &(&1.code == :raw_prompt_leak))
    end

    test "allows explicitly redacted raw_prompt sentinel" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: :chatbot,
          extra_event_attributes: [
            %{"name" => "raw_prompt", "value" => "[REDACTED]"}
          ]
        )

      assert {:ok, report} = OcelAiTraceSim.validate_line(line)
      assert report.valid == true
    end

    test "rejects Bearer token or email PII via OcelV2LogValidator" do
      line =
        OcelAiTraceSim.encode_trace_line(
          surface: :workflow,
          extra_event_attributes: [
            %{"name" => "note", "value" => "contact alice@example.com for approval"}
          ]
        )

      assert {:error, violations} = OcelAiTraceSim.validate_line(line)
      assert violations != []
    end

    test "rejects missing ocel:version" do
      entry =
        OcelAiTraceSim.build_trace_entry(surface: :ide)
        |> update_in(["jsonPayload"], &Map.delete(&1, "ocel:version"))

      assert {:error, violations} = OcelAiTraceSim.validate_line(entry)
      assert Enum.any?(violations, &(&1.code == :missing_ocel_version))
    end
  end
end

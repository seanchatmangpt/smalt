defmodule Smalt.ServengineSim.AiElements.ChatbotSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.AiElements.ChatbotSim

  describe "defaults and /api/ai/status" do
    test "exposes canonical /ai/chatbot route and Vertex AI global defaults" do
      assert ChatbotSim.route() == "/ai/chatbot"
      assert ChatbotSim.chat_endpoint() == "/api/ai/chat"
      assert ChatbotSim.status_endpoint() == "/api/ai/status"
      assert ChatbotSim.default_location() == "global"
      assert ChatbotSim.default_model() == "gemini-4-neon"

      assert ChatbotSim.supported_models() == [
               "gemini-4-neon"
             ]

      sim = ChatbotSim.new()
      assert sim.route == "/ai/chatbot"
      assert sim.location == "global"
      assert sim.model == "gemini-4-neon"
      assert sim.messages == []
      assert sim.error == nil
      assert :ok == ChatbotSim.validate_session(sim)
    end

    test "falls back to gemini-4-neon when initial_model is unsupported" do
      sim = ChatbotSim.new(initial_model: "legacy-unsupported-model")
      assert sim.model == "gemini-4-neon"
    end

    test "fetches Vertex AI status from GET /api/ai/status" do
      sim = ChatbotSim.new(project: "servengine-live", location: "global")

      assert {:ok, status, sim} = ChatbotSim.fetch_status(sim)
      assert status.configured == true
      assert status.project == "servengine-live"
      assert status.location == "global"
      assert status.model == "gemini-4-neon"
      assert status.availableModels == ["gemini-4-neon"]

      assert [%{endpoint: "/api/ai/status", method: "GET", body: nil}] = sim.requests
      assert :ok == ChatbotSim.validate_session(sim)
    end
  end

  describe "multi-turn Vertex chat" do
    test "accumulates full conversation history across turns and forwards options" do
      sim =
        ChatbotSim.new(
          system_prompt: "You are ServEngine SLA triage assistant.",
          temperature: 0.2,
          max_output_tokens: 1024,
          context: %{workOrderId: "WO-404"}
        )

      assert {:ok, reply1, sim} = ChatbotSim.send_message(sim, "  Summarize WO-404 SLA risk  ")
      assert reply1.role == "assistant"
      assert reply1.model == "gemini-4-neon"
      assert reply1.content =~ "gemini-4-neon@global"
      assert reply1.usage.totalTokens > 0

      assert {:ok, reply2, sim} = ChatbotSim.send_message(sim, "Draft an escalation note")
      assert reply2.role == "assistant"
      assert length(sim.messages) == 4

      assert [req1, req2] = sim.requests
      assert req1.endpoint == "/api/ai/chat"
      assert req1.method == "POST"
      assert req1.body.model == "gemini-4-neon"
      assert req1.body.system == "You are ServEngine SLA triage assistant."
      assert req1.body.temperature == 0.2
      assert req1.body.maxOutputTokens == 1024
      assert req1.body.context == %{workOrderId: "WO-404"}
      assert req1.body.messages == [%{role: "user", content: "Summarize WO-404 SLA risk"}]

      assert Enum.map(req2.body.messages, & &1.role) == ["user", "assistant", "user"]
      assert List.last(req2.body.messages).content == "Draft an escalation note"
      assert :ok == ChatbotSim.validate_session(sim)
    end

    test "ignores blank or whitespace-only prompts without calling Vertex AI" do
      sim = ChatbotSim.new()

      assert {:noop, ^sim} = ChatbotSim.send_message(sim, "")
      assert {:noop, ^sim} = ChatbotSim.send_message(sim, "   \n\t  ")
      assert sim.messages == []
      assert sim.requests == []
    end
  end

  describe "model switching" do
    test "switches between gemini-4-neon while preserving history" do
      sim = ChatbotSim.new()
      assert {:ok, _reply1, sim} = ChatbotSim.send_message(sim, "Initial triage")

      assert {:ok, sim} = ChatbotSim.set_model(sim, "gemini-4-neon")
      assert sim.model == "gemini-4-neon"
      assert length(sim.messages) == 2

      assert {:ok, reply2, sim} = ChatbotSim.send_message(sim, "Deep compliance analysis")
      assert reply2.model == "gemini-4-neon"
      assert reply2.content =~ "gemini-4-neon@global"

      last_req = List.last(sim.requests)
      assert last_req.body.model == "gemini-4-neon"
      assert length(last_req.body.messages) == 3

      assert {:error, {:unsupported_model, "gpt-4o"}} = ChatbotSim.set_model(sim, "gpt-4o")
      assert :ok == ChatbotSim.validate_session(sim)
    end

    test "submit_with_model switches model inline before dispatching" do
      sim = ChatbotSim.new(initial_model: "gemini-4-neon")

      assert {:ok, reply, sim} =
               ChatbotSim.submit_with_model(
                 sim,
                 "Compare vendor bids",
                 "gemini-4-neon"
               )

      assert sim.model == "gemini-4-neon"
      assert reply.model == "gemini-4-neon"
      assert {:error, {:unsupported_model, "unknown"}, ^sim} =
               ChatbotSim.submit_with_model(sim, "hi", "unknown")
    end
  end

  describe "regenerate flow" do
    test "trims to last user message and re-dispatches with the currently active model" do
      sim = ChatbotSim.new()
      assert {:ok, _r1, sim} = ChatbotSim.send_message(sim, "Turn 1")
      assert {:ok, r2_old, sim} = ChatbotSim.send_message(sim, "Turn 2")
      assert r2_old.model == "gemini-4-neon"

      # Switch to Pro and regenerate the last assistant reply
      assert {:ok, sim} = ChatbotSim.set_model(sim, "gemini-4-neon")
      assert {:ok, r2_new, sim} = ChatbotSim.regenerate_last(sim)

      assert r2_new.id != r2_old.id
      assert r2_new.model == "gemini-4-neon"
      assert length(sim.messages) == 4
      assert Enum.map(sim.messages, & &1.role) == ["user", "assistant", "user", "assistant"]
      assert List.last(sim.messages).id == r2_new.id

      regen_req = List.last(sim.requests)
      assert regen_req.body.model == "gemini-4-neon"
      assert Enum.map(regen_req.body.messages, & &1.role) == ["user", "assistant", "user"]
      assert List.last(regen_req.body.messages).content == "Turn 2"
      assert :ok == ChatbotSim.validate_session(sim)
    end

    test "returns :noop when regenerating with no user messages" do
      empty = ChatbotSim.new()
      assert {:noop, ^empty} = ChatbotSim.regenerate_last(empty)

      system_only =
        ChatbotSim.new(
          initial_messages: [
            %{
              id: "system-1",
              role: "system",
              content: "System boot",
              timestamp: "2026-11-19T00:00:00Z"
            }
          ]
        )

      assert {:noop, ^system_only} = ChatbotSim.regenerate_last(system_only)
    end
  end

  describe "clear flow and error recovery" do
    test "clear_chat resets messages and error while preserving active model" do
      sim = ChatbotSim.new(initial_model: "gemini-4-neon", configured: false)
      assert {:error, err, sim} = ChatbotSim.send_message(sim, "Check status")
      assert is_binary(err)
      assert sim.error == err
      # User message is preserved on failure (matches useVertexChat.ts)
      assert length(sim.messages) == 1

      cleared = ChatbotSim.clear_chat(sim)
      assert cleared.messages == []
      assert cleared.error == nil
      assert cleared.is_loading == false
      assert cleared.model == "gemini-4-neon"

      # Re-enable and start a fresh conversation with no stale history
      recovered = %{cleared | configured: true}
      assert {:ok, reply, recovered} = ChatbotSim.send_message(recovered, "Fresh start")
      assert reply.model == "gemini-4-neon"
      assert List.last(recovered.requests).body.messages == [%{role: "user", content: "Fresh start"}]
      assert :ok == ChatbotSim.validate_session(recovered)
    end

    test "supports custom transport failure followed by clear_error and regenerate recovery" do
      attempts = :atomics.new(1, signed: false)

      transport = fn %{endpoint: "/api/ai/chat", body: body} ->
        attempt = :atomics.add_get(attempts, 1, 1)

        if attempt == 1 do
          {:error, "HTTP 503 Vertex AI transient error"}
        else
          {:ok,
           %{
             text: "Recovered reply on #{body.model}",
             model: body.model,
             project: "servengine-prod",
             location: "global",
             usage: %{promptTokens: 12, completionTokens: 18, totalTokens: 30}
           }}
        end
      end

      sim = ChatbotSim.new(transport: transport)
      assert {:error, "HTTP 503 Vertex AI transient error", sim} = ChatbotSim.send_message(sim, "Retry me")
      assert sim.error == "HTTP 503 Vertex AI transient error"
      assert length(sim.messages) == 1

      sim = ChatbotSim.clear_error(sim)
      assert sim.error == nil

      assert {:ok, reply, sim} = ChatbotSim.regenerate_last(sim)
      assert reply.content == "Recovered reply on gemini-4-neon"
      assert sim.error == nil
      assert length(sim.messages) == 2
      assert :ok == ChatbotSim.validate_session(sim)
    end
  end
end

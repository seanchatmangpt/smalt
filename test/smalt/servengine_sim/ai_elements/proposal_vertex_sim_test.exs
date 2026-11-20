defmodule Smalt.ServengineSim.AiElements.ProposalVertexSimTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Smalt.ServengineSim.AiElements.ProposalVertexSim

  @vertex_adapter "Xaas.ServEngine.Operations.ProposalGenerator.VertexAdapter"
  @stub_adapter "Xaas.ServEngine.Operations.ProposalGenerator.StubAdapter"
  @project "servengine-prod-gcp"

  describe "zero StubAdapter enforcement and adapter binding" do
    test "accepts ProposalGenerator.VertexAdapter as string or module atom" do
      assert :ok == ProposalVertexSim.validate_adapter_binding(@vertex_adapter)

      assert :ok ==
               ProposalVertexSim.validate_adapter_binding(
                 Xaas.ServEngine.Operations.ProposalGenerator.VertexAdapter
               )
    end

    test "refuses ProposalGenerator.StubAdapter and any other StubAdapter" do
      assert {:error, {:stub_adapter_forbidden, @stub_adapter}} ==
               ProposalVertexSim.validate_adapter_binding(@stub_adapter)

      assert {:error, {:stub_adapter_forbidden, @stub_adapter}} ==
               ProposalVertexSim.validate_adapter_binding(
                 Xaas.ServEngine.Operations.ProposalGenerator.StubAdapter
               )

      assert {:error, {:stub_adapter_forbidden, "Some.Custom.StubAdapter"}} ==
               ProposalVertexSim.validate_adapter_binding("Some.Custom.StubAdapter")
    end

    test "refuses missing or unexpected adapter bindings" do
      assert {:error, :no_generator_config} == ProposalVertexSim.validate_adapter_binding(nil)
      assert {:error, :no_generator_config} == ProposalVertexSim.validate_adapter_binding("")

      assert {:error, {:unexpected_adapter, "MyApp.FakeAdapter"}} ==
               ProposalVertexSim.validate_adapter_binding("MyApp.FakeAdapter")
    end
  end

  describe "Vertex AI config and runtime audit" do
    test "accepts global location with gemini-4-neon" do
      for model <- ["gemini-4-neon"] do
        assert :ok ==
                 ProposalVertexSim.validate_vertex_config(%{
                   project: @project,
                   location: "global",
                   model: model
                 })
      end
    end

    test "rejects non-global locations, unsupported models, and missing project" do
      assert {:error, {:invalid_vertex_location, "us-central1"}} ==
               ProposalVertexSim.validate_vertex_config(%{
                 project: @project,
                 location: "us-central1",
                 model: "gemini-4-neon"
               })

      assert {:error, {:invalid_vertex_model, "gemini-1.5-pro"}} ==
               ProposalVertexSim.validate_vertex_config(%{
                 project: @project,
                 location: "global",
                 model: "gemini-1.5-pro"
               })

      assert {:error, :missing_vertex_project} ==
               ProposalVertexSim.validate_vertex_config(%{
                 project: "",
                 location: "global",
                 model: "gemini-4-neon"
               })
    end

    test "audit_runtime_config enforces VertexAdapter + valid Vertex AI config" do
      assert :ok ==
               ProposalVertexSim.audit_runtime_config(
                 proposal_generator_adapter:
                   Xaas.ServEngine.Operations.ProposalGenerator.VertexAdapter,
                 vertex_ai: %{
                   project: @project,
                   location: "global",
                   model: "gemini-4-neon"
                 }
               )

      assert {:error, [{:stub_adapter_forbidden, @stub_adapter}]} ==
               ProposalVertexSim.audit_runtime_config(
                 proposal_generator_adapter:
                   Xaas.ServEngine.Operations.ProposalGenerator.StubAdapter,
                 vertex_ai: %{
                   project: @project,
                   location: "global",
                   model: "gemini-4-neon"
                 }
               )
    end
  end

  describe "ProposalGenerator.VertexAdapter.generate/2 contract" do
    test "generates a valid proposal body with Vertex config metadata" do
      payload = %{work_order_id: "WO-4091", trade: "HVAC", scope: "Replace RTU-2 belt"}

      assert {:ok, result} =
               ProposalVertexSim.simulate_generate(payload,
                 project: @project,
                 location: "global",
                 model: "gemini-4-neon",
                 proposal_id: "prop-001"
               )

      assert result.adapter == @vertex_adapter
      assert result.proposal_id == "prop-001"

      assert result.config == %{
               project: @project,
               location: "global",
               model: "gemini-4-neon"
             }

      assert :ok == ProposalVertexSim.validate_generated_body(result)
    end

    test "fails closed when StubAdapter is passed or Vertex AI is unconfigured" do
      payload = %{work_order_id: "WO-4092"}

      assert {:error, {:stub_adapter_forbidden, @stub_adapter}} ==
               ProposalVertexSim.simulate_generate(payload,
                 adapter: @stub_adapter,
                 project: @project
               )

      assert {:error, :vertex_ai_not_configured} ==
               ProposalVertexSim.simulate_generate(payload, configured?: false)

      assert {:error, :no_gcp_access_token} ==
               ProposalVertexSim.simulate_generate(payload,
                 project: @project,
                 vertex_fn: fn _prompt, _opts -> {:error, :no_gcp_access_token} end
               )
    end

    test "validate_generated_body rejects StubAdapter outputs" do
      bad_result = %{
        body: "Stub proposal",
        config: %{project: @project, location: "global", model: "gemini-4-neon"},
        adapter: @stub_adapter,
        generated_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      assert {:error, [{:stub_adapter_forbidden, @stub_adapter}]} ==
               ProposalVertexSim.validate_generated_body(bad_result)
    end
  end

  describe "POST /api/ai/proposal-refine HTTP contract" do
    test "refines proposal with default flash model and returns canonical data envelope" do
      body =
        Jason.encode!(%{
          "draft" => "Replace rooftop condenser fan motor.",
          "instruction" => "Add itemized labor and warranty terms."
        })

      conn =
        conn(:post, "/api/ai/proposal-refine", body)
        |> put_req_header("content-type", "application/json")
        |> ProposalVertexSim.call(
          ProposalVertexSim.init(
            project: @project,
            location: "global",
            model: "gemini-4-neon"
          )
        )

      assert conn.halted
      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert :ok == ProposalVertexSim.validate_refine_response(200, decoded)
      assert decoded["data"]["model"] == "gemini-4-neon"
      assert decoded["data"]["location"] == "global"
      assert decoded["data"]["project"] == @project
    end

    test "supports gemini-4-neon override and body/prompt parameter aliases" do
      body =
        Jason.encode!(%{
          "body" => "Annual fire sprinkler inspection.",
          "prompt" => "Format as executive summary.",
          "model" => "gemini-4-neon"
        })

      conn =
        conn(:post, "/api/ai/proposal-refine", body)
        |> put_req_header("content-type", "application/json")
        |> ProposalVertexSim.call(ProposalVertexSim.init(project: @project))

      assert conn.status == 200
      decoded = Jason.decode!(conn.resp_body)
      assert :ok == ProposalVertexSim.validate_refine_response(200, decoded)
      assert decoded["data"]["model"] == "gemini-4-neon"
    end

    test "maps Vertex AI errors to canonical GcpAiController HTTP statuses and codes" do
      cases = [
        {:vertex_ai_not_configured, 503, "vertex_ai_not_configured"},
        {:no_gcp_access_token, 503, "no_gcp_access_token"},
        {{:vertex_ai_http_error, 429, "quota"}, 429, "vertex_ai_rate_limited"},
        {{:vertex_ai_http_error, 500, "boom"}, 502, "vertex_ai_http_error"},
        {:timeout, 503, "vertex_ai_unavailable"}
      ]

      for {reason, expected_status, expected_code} <- cases do
        conn =
          conn(:post, "/api/ai/proposal-refine", Jason.encode!(%{"draft" => "test"}))
          |> put_req_header("content-type", "application/json")
          |> ProposalVertexSim.call(
            ProposalVertexSim.init(
              project: @project,
              vertex_fn: fn _prompt, _opts -> {:error, reason} end
            )
          )

        assert conn.status == expected_status
        decoded = Jason.decode!(conn.resp_body)
        assert decoded["code"] == expected_code
        assert :ok == ProposalVertexSim.validate_refine_response(expected_status, decoded)
      end
    end

    test "refuses StubAdapter binding on /api/ai/proposal-refine" do
      conn =
        conn(:post, "/api/ai/proposal-refine", Jason.encode!(%{"draft" => "test"}))
        |> put_req_header("content-type", "application/json")
        |> ProposalVertexSim.call(
          ProposalVertexSim.init(project: @project, adapter: @stub_adapter)
        )

      assert conn.status == 503
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["code"] == "stub_adapter_forbidden"
    end

    test "rejects invalid model, non-POST methods, and unknown paths" do
      bad_model_conn =
        conn(
          :post,
          "/api/ai/proposal-refine",
          Jason.encode!(%{"draft" => "test", "model" => "gemini-1.5-flash"})
        )
        |> put_req_header("content-type", "application/json")
        |> ProposalVertexSim.call(ProposalVertexSim.init(project: @project))

      assert bad_model_conn.status == 400

      get_conn =
        conn(:get, "/api/ai/proposal-refine")
        |> ProposalVertexSim.call(ProposalVertexSim.init(project: @project))

      assert get_conn.status == 405
      assert get_resp_header(get_conn, "allow") == ["POST"]

      not_found_conn =
        conn(:post, "/api/ai/unknown")
        |> ProposalVertexSim.call(ProposalVertexSim.init(project: @project))

      assert not_found_conn.status == 404
    end

    test "validate_refine_response rejects stub markers in 200 payload" do
      stub_payload = %{
        "data" => %{
          "text" => "[stub] Generated by StubAdapter",
          "model" => "gemini-4-neon",
          "project" => @project,
          "location" => "global"
        }
      }

      assert {:error, [:stub_output_detected]} ==
               ProposalVertexSim.validate_refine_response(200, stub_payload)
    end
  end
end

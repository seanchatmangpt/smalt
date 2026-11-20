defmodule Smalt.ServengineSim.AiElements.ContractProbeSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.AiElements.ContractProbeSim

  describe "live /Users/sac/srve FE<->BE contract parity" do
    test "verifies 100% route, model, router guard, envelope, and payload parity" do
      assert {:ok, report} = ContractProbeSim.probe_files()
      assert report.status == :ok
      assert report.mismatches == []

      assert %{method: "GET", path: "/api/ai/status"} in report.fe_routes
      assert %{method: "POST", path: "/api/ai/chat"} in report.fe_routes
      assert %{method: "POST", path: "/api/ai/workflow-step"} in report.fe_routes
      assert %{method: "POST", path: "/api/ai/ide-assist"} in report.fe_routes

      for route <- report.fe_routes do
        assert route in report.be_routes
      end

      assert Enum.sort(report.fe_models) == [
               "gemini-4-neon"
             ]

      assert Enum.sort(report.be_models) == Enum.sort(report.fe_models)
      assert report.be_default_model == "gemini-4-neon"

      assert report.router_checks == %{
               pipeline_order_ok?: true,
               options_preflight_ok?: true,
               mounted_before_forward?: true
             }

      assert Enum.all?(report.envelope_checks, fn {_k, v} -> v == true end)

      for endpoint <- [:chat, :workflow_step, :ide_assist] do
        check = Map.fetch!(report.payload_checks, endpoint)
        assert check.ok? == true
        assert check.missing_response_keys == []
        assert check.missing_request_params == []

        for required_key <- ["text", "model", "project", "location"] do
          assert required_key in check.fe_required_response_fields
          assert required_key in check.be_response_keys
        end
      end
    end
  end

  describe "anti-vacuity drift detection" do
    setup do
      paths = ContractProbeSim.default_paths()

      {:ok,
       vc_src: File.read!(paths.vertex_client),
       ctrl_src: File.read!(paths.controller),
       router_src: File.read!(paths.router)}
    end

    test "detects missing FE route in router.ex", %{
      vc_src: vc_src,
      ctrl_src: ctrl_src,
      router_src: router_src
    } do
      mutated_router = String.replace(router_src, ~s[post("/ai/ide-assist", AiElementsController, :ide_assist)], "")

      assert {:error, report} = ContractProbeSim.verify_parity(vc_src, ctrl_src, mutated_router)
      assert report.status == :mismatch

      assert Enum.any?(
               report.mismatches,
               &String.contains?(&1, "FE route POST /api/ai/ide-assist missing from router.ex")
             )
    end

    test "detects Vertex AI model drift between FE and BE", %{
      vc_src: vc_src,
      ctrl_src: ctrl_src,
      router_src: router_src
    } do
      mutated_ctrl = String.replace(ctrl_src, ~s("gemini-4-neon"), ~s("gemini-2.5-pro"))

      assert {:error, report} = ContractProbeSim.verify_parity(vc_src, mutated_ctrl, router_src)
      assert report.status == :mismatch
      assert Enum.any?(report.mismatches, &String.contains?(&1, "model mismatch"))
    end

    test "detects missing required FE response field in controller payload", %{
      vc_src: vc_src,
      ctrl_src: ctrl_src,
      router_src: router_src
    } do
      mutated_ctrl =
        String.replace(
          ctrl_src,
          "location: VertexAI.location()",
          "",
          global: false
        )

      assert {:error, report} = ContractProbeSim.verify_parity(vc_src, mutated_ctrl, router_src)
      assert report.status == :mismatch
      assert "location" in report.payload_checks.chat.missing_response_keys
    end

    test "detects router pipeline ordering regression", %{
      vc_src: vc_src,
      ctrl_src: ctrl_src,
      router_src: router_src
    } do
      mutated_router =
        String.replace(
          router_src,
          "pipe_through([:cors, :require_internal_api_token, :api])",
          "pipe_through([:api, :require_internal_api_token, :cors])"
        )

      assert {:error, report} = ContractProbeSim.verify_parity(vc_src, ctrl_src, mutated_router)
      assert report.status == :mismatch
      assert report.router_checks.pipeline_order_ok? == false
    end
  end
end

defmodule Smalt.ServengineSim.AiElements.VertexClientSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.AiElements.VertexClientSim

  describe "canonical constants" do
    test "exposes global host, global location, and exact model allowlist" do
      assert VertexClientSim.global_host() == "aiplatform.googleapis.com"
      assert VertexClientSim.default_location() == "global"
      assert VertexClientSim.default_model() == "gemini-4-neon"

      assert VertexClientSim.allowed_models() == [
               "gemini-4-neon"
             ]
    end
  end

  describe "locations/global host validation" do
    test "maps global location to aiplatform.googleapis.com" do
      assert {:ok, "aiplatform.googleapis.com"} = VertexClientSim.host_for_location("global")
      assert :ok = VertexClientSim.validate_location("global")
      assert :ok = VertexClientSim.validate_host("aiplatform.googleapis.com")
    end

    test "rejects regional locations and prefixed global host" do
      assert {:error, {:unsupported_location, "us-central1"}} =
               VertexClientSim.host_for_location("us-central1")

      assert {:error, {:unsupported_location, "europe-west4"}} =
               VertexClientSim.validate_location("europe-west4")

      assert {:error, {:invalid_host, "global-aiplatform.googleapis.com"}} =
               VertexClientSim.validate_host("global-aiplatform.googleapis.com")

      assert {:error, {:invalid_host, "us-central1-aiplatform.googleapis.com"}} =
               VertexClientSim.validate_host("us-central1-aiplatform.googleapis.com")
    end
  end

  describe "model allowlist validation" do
    test "admits gemini-4-neon" do
      assert :ok = VertexClientSim.validate_model("gemini-4-neon")
      assert :ok = VertexClientSim.validate_model("gemini-4-neon")
    end

    test "refuses non-allowlisted models" do
      for model <- [
            "gemini-2.0-flash",
            "gemini-1.5-pro",
            "gemini-2.5-pro",
            "gpt-4o",
            "",
            nil
          ] do
        assert {:error, {:disallowed_model, ^model}} = VertexClientSim.validate_model(model)
      end
    end
  end

  describe "build_endpoint/4" do
    test "builds canonical global Vertex AI endpoint URLs for both allowlisted models" do
      assert {:ok,
              "https://aiplatform.googleapis.com/v1/projects/servengine-prod/locations/global/publishers/google/models/gemini-4-neon:generateContent"} =
               VertexClientSim.build_endpoint("servengine-prod")

      assert {:ok,
              "https://aiplatform.googleapis.com/v1/projects/servengine-prod/locations/global/publishers/google/models/gemini-4-neon:streamGenerateContent"} =
               VertexClientSim.build_endpoint(
                 "servengine-prod",
                 "global",
                 "gemini-4-neon",
                 "streamGenerateContent"
               )
    end

    test "rejects invalid project, non-global location, disallowed model, or unsupported action" do
      assert {:error, {:invalid_project, ""}} = VertexClientSim.build_endpoint("")

      assert {:error, {:unsupported_location, "us-central1"}} =
               VertexClientSim.build_endpoint("servengine-prod", "us-central1")

      assert {:error, {:disallowed_model, "gemini-2.0-flash"}} =
               VertexClientSim.build_endpoint("servengine-prod", "global", "gemini-2.0-flash")

      assert {:error, {:unsupported_action, "predict"}} =
               VertexClientSim.build_endpoint(
                 "servengine-prod",
                 "global",
                 "gemini-4-neon",
                 "predict"
               )
    end
  end

  describe "validate_endpoint_url/1" do
    test "accepts valid https aiplatform.googleapis.com global endpoints" do
      url =
        "https://aiplatform.googleapis.com/v1/projects/srve-gcp/locations/global/publishers/google/models/gemini-4-neon:generateContent"

      assert {:ok,
              %{
                host: "aiplatform.googleapis.com",
                project: "srve-gcp",
                location: "global",
                model: "gemini-4-neon",
                action: "generateContent",
                endpoint: ^url
              }} = VertexClientSim.validate_endpoint_url(url)
    end

    test "rejects global-aiplatform.googleapis.com, regional hosts, plaintext http, and disallowed models" do
      assert {:error, {:invalid_host, "global-aiplatform.googleapis.com"}} =
               VertexClientSim.validate_endpoint_url(
                 "https://global-aiplatform.googleapis.com/v1/projects/srve-gcp/locations/global/publishers/google/models/gemini-4-neon:generateContent"
               )

      assert {:error, {:invalid_host, "us-central1-aiplatform.googleapis.com"}} =
               VertexClientSim.validate_endpoint_url(
                 "https://us-central1-aiplatform.googleapis.com/v1/projects/srve-gcp/locations/us-central1/publishers/google/models/gemini-4-neon:generateContent"
               )

      assert {:error, {:invalid_scheme, "http"}} =
               VertexClientSim.validate_endpoint_url(
                 "http://aiplatform.googleapis.com/v1/projects/srve-gcp/locations/global/publishers/google/models/gemini-4-neon:generateContent"
               )

      assert {:error, {:unsupported_location, "us-central1"}} =
               VertexClientSim.validate_endpoint_url(
                 "https://aiplatform.googleapis.com/v1/projects/srve-gcp/locations/us-central1/publishers/google/models/gemini-4-neon:generateContent"
               )

      assert {:error, {:disallowed_model, "gemini-2.0-flash"}} =
               VertexClientSim.validate_endpoint_url(
                 "https://aiplatform.googleapis.com/v1/projects/srve-gcp/locations/global/publishers/google/models/gemini-2.0-flash:generateContent"
               )
    end
  end

  describe "validate_request/1 and status_response/1" do
    test "validates request maps with atom or string keys" do
      assert {:ok, %{host: "aiplatform.googleapis.com", location: "global", model: "gemini-4-neon"}} =
               VertexClientSim.validate_request(%{project: "srve-prod"})

      assert {:ok, %{host: "aiplatform.googleapis.com", location: "global", model: "gemini-4-neon"}} =
               VertexClientSim.validate_request(%{
                 "project" => "srve-prod",
                 "location" => "global",
                 "model" => "gemini-4-neon"
               })
    end

    test "builds status_response reflecting configured state" do
      assert %{
               configured: true,
               project: "srve-prod",
               location: "global",
               model: "gemini-4-neon",
               host: "aiplatform.googleapis.com",
               available_models: ["gemini-4-neon"]
             } = VertexClientSim.status_response(project: "srve-prod")

      assert %{configured: false, host: nil} =
               VertexClientSim.status_response(project: "srve-prod", location: "us-central1")
    end
  end
end

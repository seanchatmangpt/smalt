defmodule Smalt.ServengineSim.AiElements.ErrorSanitizationSimTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Smalt.ServengineSim.AiElements.ErrorSanitizationSim

  defp post_json(path, body_params, opts \\ []) do
    conn(:post, path, "")
    |> put_req_header("content-type", "application/json")
    |> Map.put(:body_params, body_params)
    |> ErrorSanitizationSim.call(ErrorSanitizationSim.init(opts))
  end

  describe "Vertex AI alignment" do
    test "enforces global location and allowed Gemini 4 Neon model" do
      assert ErrorSanitizationSim.default_location() == "global"
      assert ErrorSanitizationSim.default_model() == "gemini-4-neon"

      assert ErrorSanitizationSim.allowed_models() == [
               "gemini-4-neon"
             ]
    end
  end

  describe "clean JSON error responses (zero raw Elixir inspect leakage)" do
    test "sanitizes every Vertex AI failure mode without leaking Elixir terms" do
      cases = [
        {:vertex_ai_not_configured, 503, "vertex_ai_not_configured"},
        {:no_gcp_access_token, 503, "no_gcp_access_token"},
        {{:vertex_ai_http_error, 429, %{"error" => %{"message" => "Quota exceeded"}}}, 429,
         "vertex_ai_http_error"},
        {{:vertex_ai_http_error, 500, %{"error" => %{"message" => "Backend failure"}}}, 502,
         "vertex_ai_http_error"},
        {{:vertex_ai_http_error, 503, %{"unexpected" => {:tuple, :leak}}}, 502,
         "vertex_ai_http_error"},
        {{:vertex_ai_request_failed, %RuntimeError{message: "econnrefused"}}, 503,
         "vertex_ai_request_failed"},
        {{:vertex_ai_request_failed, {:tls_alert, {:handshake_failure, ~c"bad"}}}, 503,
         "vertex_ai_request_failed"},
        {{:unexpected_crash, self(), make_ref(), %{secret: "token"}}, 503,
         "vertex_ai_unavailable"}
      ]

      for {reason, expected_status, expected_code} <- cases do
        backend = fn _prompt, _opts -> {:error, reason} end

        conn =
          post_json(
            "/api/ai/elements/chat",
            %{"prompt" => "hello", "model" => "gemini-4-neon"},
            backend: backend
          )

        assert conn.halted
        assert conn.status == expected_status
        assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
        assert :ok == ErrorSanitizationSim.verify_clean_json_error(conn.resp_body)

        decoded = Jason.decode!(conn.resp_body)
        assert decoded["code"] == expected_code
        assert is_binary(decoded["error"]) and decoded["error"] != ""
      end
    end

    test "upstream HTTP error preserves clean message and falls back on non-string message" do
      {429, rate_limited} =
        ErrorSanitizationSim.sanitize_error(
          {:vertex_ai_http_error, 429, %{"error" => %{"message" => "  Rate limit hit  "}}}
        )

      assert rate_limited["error"] == "Rate limit hit"
      assert rate_limited["upstream_status"] == 429

      {502, fallback} =
        ErrorSanitizationSim.sanitize_error(
          {:vertex_ai_http_error, 500, %{"error" => %{"message" => 12_345}}}
        )

      assert fallback["error"] == "Vertex AI upstream error (HTTP 500)"
      assert fallback["upstream_status"] == 500
    end

    test "detect_inspect_leakage catches structs, maps, tuples, opaque terms, and arrows" do
      assert {:error, {:inspect_leakage, tags}} =
               ErrorSanitizationSim.detect_inspect_leakage(
                 ~s({"error":"failed: %Mint.TransportError{reason: :timeout}","code":"err"})
               )

      assert :elixir_struct in tags

      assert {:error, {:inspect_leakage, tags}} =
               ErrorSanitizationSim.detect_inspect_leakage(
                 ~s({"error":"%{a => 1} {:tls_alert, :bad} #PID<0.123.0>","code":"err"})
               )

      assert :elixir_map in tags
      assert :elixir_map_arrow in tags
      assert :elixir_tuple in tags
      assert :elixir_opaque_term in tags

      assert :ok ==
               ErrorSanitizationSim.detect_inspect_leakage(
                 ~s({"error":"Vertex AI request failed","code":"vertex_ai_request_failed"})
               )
    end
  end

  describe "safe non-string param handling" do
    test "rejects non-string and unknown models with clean 400 JSON" do
      for bad_model <- [123, 3.14, true, false, %{"id" => "gemini"}, ["gemini-4-neon"], "gpt-4o"] do
        conn =
          post_json("/api/ai/elements/chat", %{"model" => bad_model, "prompt" => "hi"})

        assert conn.status == 400
        assert :ok == ErrorSanitizationSim.verify_clean_json_error(conn.resp_body)

        decoded = Jason.decode!(conn.resp_body)
        assert decoded["code"] == "invalid_model"
        assert decoded["allowed_models"] == ErrorSanitizationSim.allowed_models()
      end
    end

    test "chat endpoint safely handles non-string prompt, messages, roles, and system fields" do
      conn_bad =
        post_json("/api/ai/elements/chat", %{
          "prompt" => 42,
          "message" => %{"nested" => true},
          "messages" => [
            123,
            nil,
            %{"role" => 99, "content" => ["not", "string"]},
            %{"role" => "user", "parts" => [123, %{"text" => 456}]}
          ],
          "system" => true,
          "system_instruction" => 999
        })

      assert conn_bad.status == 400
      assert :ok == ErrorSanitizationSim.verify_clean_json_error(conn_bad.resp_body)
      assert Jason.decode!(conn_bad.resp_body)["error"] == "messages or prompt is required"

      conn_ok =
        post_json("/api/ai/elements/chat", %{
          "messages" => [
            "ignored-non-map",
            %{"role" => 404, "content" => "hello from non-string role"},
            %{"role" => "user", "parts" => [%{"text" => "part1 "}, %{"text" => 999}, %{"text" => "part2"}]}
          ],
          "system" => 123
        })

      assert conn_ok.status == 200
      decoded = Jason.decode!(conn_ok.resp_body)
      assert decoded["data"]["model"] == "gemini-4-neon"
      assert decoded["data"]["location"] == "global"
      assert decoded["data"]["text"] =~ "User: hello from non-string role"
      assert decoded["data"]["text"] =~ "User: part1 part2"
    end

    test "workflow-step endpoint safely handles non-string step, workflow, instruction, and input" do
      conn_bad =
        post_json("/api/ai/elements/workflow-step", %{
          "prompt" => 123,
          "instruction" => false,
          "input" => 456,
          "context" => true,
          "step" => ["not-string"],
          "workflow" => %{"bad" => 1}
        })

      assert conn_bad.status == 400
      assert :ok == ErrorSanitizationSim.verify_clean_json_error(conn_bad.resp_body)
      assert Jason.decode!(conn_bad.resp_body)["error"] == "prompt or input is required"

      conn_map_input =
        post_json("/api/ai/elements/workflow-step", %{
          "input" => %{"order_id" => 101},
          "step" => 999,
          "workflow" => false,
          "model" => "gemini-4-neon"
        })

      assert conn_map_input.status == 200
      decoded = Jason.decode!(conn_map_input.resp_body)
      assert decoded["data"]["step"] == "workflow_step"
      assert decoded["data"]["status"] == "completed"
      assert decoded["data"]["model"] == "gemini-4-neon"
      assert decoded["data"]["text"] =~ ~s({"order_id":101})
    end

    test "ide-assist endpoint safely handles non-string instruction, code, language, file_path, and action" do
      conn_bad =
        post_json("/api/ai/elements/ide-assist", %{
          "instruction" => 999,
          "prompt" => %{"bad" => true},
          "code" => 123,
          "language" => true,
          "file_path" => ["a.ex"],
          "action" => 42
        })

      assert conn_bad.status == 400
      assert :ok == ErrorSanitizationSim.verify_clean_json_error(conn_bad.resp_body)
      assert Jason.decode!(conn_bad.resp_body)["error"] == "instruction or prompt is required"

      conn_ok =
        post_json("/api/ai/elements/ide-assist", %{
          "instruction" => "Refactor this function",
          "code" => 123,
          "language" => false,
          "file_path" => %{"path" => "foo.ex"},
          "action" => 77
        })

      assert conn_ok.status == 200
      decoded = Jason.decode!(conn_ok.resp_body)
      assert decoded["data"]["language"] == "text"
      assert decoded["data"]["file_path"] == nil
      assert decoded["data"]["action"] == "assist"
    end

    test "validate_params safely handles non-map top-level params" do
      assert {:error, {:missing_prompt, :chat}} ==
               ErrorSanitizationSim.validate_params(:chat, "not-a-map")

      assert {:error, {:missing_prompt, :workflow_step}} ==
               ErrorSanitizationSim.validate_params(:workflow_step, 123)

      assert {:error, {:missing_prompt, :ide_assist}} ==
               ErrorSanitizationSim.validate_params(:ide_assist, nil)
    end
  end
end

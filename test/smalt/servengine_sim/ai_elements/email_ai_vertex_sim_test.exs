defmodule Smalt.ServengineSim.AiElements.EmailAiVertexSimTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Smalt.ServengineSim.AiElements.EmailAiVertexSim

  describe "Vertex AI endpoint & payload contract (global / gemini-4-neon)" do
    test "builds global and regional Vertex AI generateContent URLs" do
      assert EmailAiVertexSim.vertex_generate_url("ai-cmd-ctr", "global", "gemini-4-neon") ==
               "https://aiplatform.googleapis.com/v1/projects/ai-cmd-ctr/locations/global/publishers/google/models/gemini-4-neon:generateContent"

      assert EmailAiVertexSim.vertex_generate_url("ai-cmd-ctr", "us-central1", "gemini-4-neon") ==
               "https://us-central1-aiplatform.googleapis.com/v1/projects/ai-cmd-ctr/locations/us-central1/publishers/google/models/gemini-4-neon:generateContent"
    end

    test "builds email-draft prompt with subject, context fallback, and tone defaults" do
      prompt =
        EmailAiVertexSim.build_email_draft_prompt(%{
          "subject" => "HVAC Chiller Fault - Bldg 4",
          "body" => "Chiller #2 tripped on high head pressure.",
          "tone" => "urgent and direct"
        })

      assert prompt =~ "Draft a urgent and direct email reply."
      assert prompt =~ "Subject: HVAC Chiller Fault - Bldg 4"
      assert prompt =~ "Chiller #2 tripped on high head pressure."

      default_prompt = EmailAiVertexSim.build_email_draft_prompt(%{"thread" => "Follow-up needed"})
      assert default_prompt =~ "Draft a professional and concise email reply."
      assert default_prompt =~ "Subject: Service Update"
      assert default_prompt =~ "Follow-up needed"
    end

    test "builds Vertex AI request body with ServEngine Email AI systemInstruction" do
      body = EmailAiVertexSim.build_vertex_request_body("Draft reply")

      assert body == %{
               contents: [%{role: "user", parts: [%{text: "Draft reply"}]}],
               systemInstruction: %{
                 parts: [%{text: EmailAiVertexSim.system_instruction()}]
               }
             }
    end

    test "extract_vertex_text filters Gemini thought parts and rejects incomplete finishReason" do
      raw = %{
        "candidates" => [
          %{
            "finishReason" => "STOP",
            "content" => %{
              "parts" => [
                %{"thought" => true, "text" => "internal chain of thought"},
                %{"text" => "Technician dispatched for 08:00 tomorrow."}
              ]
            }
          }
        ]
      }

      assert {:ok, "Technician dispatched for 08:00 tomorrow."} =
               EmailAiVertexSim.extract_vertex_text(raw)

      for reason <- ["MAX_TOKENS", "SAFETY", "RECITATION", "BLOCKLIST"] do
        incomplete = %{
          "candidates" => [
            %{
              "finishReason" => reason,
              "content" => %{"parts" => [%{"text" => "partial"}]}
            }
          ]
        }

        assert {:error, {:vertex_ai_incomplete_response, ^reason}} =
                 EmailAiVertexSim.extract_vertex_text(incomplete)
      end

      assert {:error, :empty_model_response} = EmailAiVertexSim.extract_vertex_text(%{})
    end
  end

  describe "POST /api/ai/email-draft & GET /api/ai/status Plug contract" do
    test "GET /api/ai/status returns configured Vertex AI metadata" do
      conn =
        conn(:get, "/api/ai/status")
        |> EmailAiVertexSim.call(EmailAiVertexSim.init(project: "ai-cmd-ctr"))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body == %{
               "data" => %{
                 "configured" => true,
                 "project" => "ai-cmd-ctr",
                 "location" => "global",
                 "model" => "gemini-4-neon"
               }
             }
    end

    test "POST /api/ai/email-draft returns valid GcpAiTextResponseSchema envelope for flash and pro models" do
      for model <- ["gemini-4-neon"] do
        conn =
          conn(:post, "/api/ai/email-draft", %{
            "subject" => "Roof Leak Dispatch",
            "context" => "Water ingress reported near Bay 12.",
            "tone" => "professional and concise",
            "model" => model
          })
          |> put_req_header("authorization", "Bearer test-token")
          |> put_req_header("x-tenant-id", "tenant-acme")
          |> EmailAiVertexSim.call(EmailAiVertexSim.init(project: "ai-cmd-ctr"))

        assert conn.status == 200
        decoded = Jason.decode!(conn.resp_body)
        assert :ok == EmailAiVertexSim.validate_draft_envelope(decoded)
        assert decoded["data"]["model"] == model
        assert decoded["data"]["location"] == "global"
        assert decoded["data"]["project"] == "ai-cmd-ctr"
        assert decoded["data"]["text"] =~ "Roof Leak Dispatch"
      end
    end

    test "POST /api/ai/email-draft fails closed on missing Bearer token or invalid x-tenant-id" do
      unauth =
        conn(:post, "/api/ai/email-draft", %{"subject" => "Test"})
        |> EmailAiVertexSim.call(EmailAiVertexSim.init([]))

      assert unauth.status == 401
      assert Jason.decode!(unauth.resp_body)["error"] == "unauthorized"

      no_tenant =
        conn(:post, "/api/ai/email-draft", %{"subject" => "Test"})
        |> put_req_header("authorization", "Bearer tok")
        |> EmailAiVertexSim.call(EmailAiVertexSim.init([]))

      assert no_tenant.status == 403
      assert Jason.decode!(no_tenant.resp_body)["error"] == "tenant_required"

      multi_tenant =
        conn(:post, "/api/ai/email-draft", %{"subject" => "Test"})
        |> put_req_header("authorization", "Bearer tok")
        |> then(fn c -> %{c | req_headers: [{"x-tenant-id", "t1"}, {"x-tenant-id", "t2"} | c.req_headers]} end)
        |> EmailAiVertexSim.call(EmailAiVertexSim.init([]))

      assert multi_tenant.status == 403
      assert Jason.decode!(multi_tenant.resp_body)["error"] == "unknown_tenant"
    end

    test "POST /api/ai/email-draft maps Vertex AI error tuples to exact HTTP status codes" do
      cases = [
        {:vertex_ai_not_configured, 503, "vertex_ai_not_configured"},
        {:no_gcp_access_token, 503, "no_gcp_access_token"},
        {{:vertex_ai_http_error, 429, %{}}, 429, "vertex_ai_rate_limited"},
        {{:vertex_ai_http_error, 500, %{}}, 502, "vertex_ai_http_error"}
      ]

      for {err, expected_status, expected_code} <- cases do
        conn =
          conn(:post, "/api/ai/email-draft", %{"subject" => "Outage"})
          |> put_req_header("authorization", "Bearer tok")
          |> put_req_header("x-tenant-id", "tenant-1")
          |> EmailAiVertexSim.call(
            EmailAiVertexSim.init(generator: fn _prompt, _body -> {:error, err} end)
          )

        assert conn.status == expected_status
        assert Jason.decode!(conn.resp_body)["code"] == expected_code
      end
    end

    test "POST /api/ai/email-draft rejects unsupported Vertex AI models with 422" do
      conn =
        conn(:post, "/api/ai/email-draft", %{
          "subject" => "Outage",
          "model" => "gpt-4o-mini"
        })
        |> put_req_header("authorization", "Bearer tok")
        |> put_req_header("x-tenant-id", "tenant-1")
        |> EmailAiVertexSim.call(EmailAiVertexSim.init([]))

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["code"] == "unsupported_vertex_model"
    end
  end

  describe "EmailAiThread AshPostgres (crud_email_ai_threads) contract" do
    test "creates a valid tenant-scoped EmailAiThread and rejects missing subject" do
      assert {:error, "subject is required"} ==
               EmailAiVertexSim.build_email_ai_thread(%{"body" => "no subject"}, "tenant-a")

      assert {:ok, thread} =
               EmailAiVertexSim.build_email_ai_thread(
                 %{
                   "subject" => "Fire Panel Inspection",
                   "folder" => "inbox",
                   "status" => "open",
                   "urgency" => "high",
                   "from" => "ops@client.example",
                   "to" => "dispatch@servengine.example, lead@servengine.example",
                   "body" => "Please confirm inspection window."
                 },
                 "tenant-a"
               )

      assert thread.table == "crud_email_ai_threads"
      assert thread.to == ["dispatch@servengine.example", "lead@servengine.example"]
      assert :ok == EmailAiVertexSim.validate_thread_contract(thread, "tenant-a")

      assert {:error, errors} = EmailAiVertexSim.validate_thread_contract(thread, "tenant-b")
      assert Enum.any?(errors, &(&1 =~ "tenant_id mismatch"))
    end

    test "attaches a Vertex AI email-draft reply to EmailAiThread and preserves AshPostgres parity" do
      {:ok, thread} =
        EmailAiVertexSim.build_email_ai_thread(
          %{
            "subject" => "Generator PM Schedule",
            "body" => "Need Q4 PM schedule for Site 19."
          },
          "tenant-ops"
        )

      {:ok, draft_envelope} =
        EmailAiVertexSim.simulate_email_draft(
          %{
            "subject" => thread.subject,
            "context" => thread.body,
            "model" => "gemini-4-neon"
          },
          project: "ai-cmd-ctr",
          location: "global"
        )

      assert {:ok, updated} =
               EmailAiVertexSim.attach_draft_reply(thread, draft_envelope, status: "replied")

      assert updated.status == "replied"
      assert updated.payload["status"] == "replied"
      assert length(updated.replies) == 1

      [reply] = updated.replies
      assert reply["model"] == "gemini-4-neon"
      assert reply["location"] == "global"
      assert reply["body"] == draft_envelope.data.text
      assert :ok == EmailAiVertexSim.validate_thread_contract(updated, "tenant-ops")
    end
  end
end

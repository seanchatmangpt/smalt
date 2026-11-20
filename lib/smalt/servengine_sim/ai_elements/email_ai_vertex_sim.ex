defmodule Smalt.ServengineSim.AiElements.EmailAiVertexSim do
  @moduledoc """
  ServEngine Email AI (`/api/ai/email-draft`) + Vertex AI (`global` /
  `gemini-4-neon`) + `EmailAiThread`
  AshPostgres (`crud_email_ai_threads`) contract simulator and validator.

  Mirrors the production `/Users/sac/srve` contracts:
    * `Xaas.AI.VertexAI` — global & regional endpoint URL construction,
      `systemInstruction` payload, thought-part filtering, and `finishReason`
      rejection (`MAX_TOKENS`, `SAFETY`, `RECITATION`, `BLOCKLIST`).
    * `XaasWeb.GcpAiController.email_draft/2` — `POST /api/ai/email-draft`
      prompt construction, `GcpAiTextResponseSchema` response envelope, and
      error-to-HTTP-status mapping (`503`, `429`, `502`).
    * `XaasWeb.CrudC04EmailAiController` + `Xaas.ServEngine.Crud.EmailAiThread`
      — AshPostgres `crud_email_ai_threads` schema, allowed folder/status/urgency
      enums, fail-closed Bearer + `x-tenant-id` isolation, and draft-to-thread
      reply persistence.
  """

  @behaviour Plug

  import Plug.Conn

  @default_location "global"
  @default_model "gemini-4-neon"
  @supported_models ["gemini-4-neon"]
  @default_project "ai-cmd-ctr"
  @default_tone "professional and concise"
  @default_subject "Service Update"
  @system_instruction "You are ServEngine Email AI. Write clear, actionable facilities operations emails."
  @incomplete_finish_reasons ["MAX_TOKENS", "SAFETY", "RECITATION", "BLOCKLIST"]

  @ash_table "crud_email_ai_threads"
  @allowed_folders ~w(inbox sent sentitems drafts draft deleted deleteditems junk junkemail)
  @allowed_statuses ~w(open resolved archived draft replied)
  @allowed_urgencies ~w(low normal high critical)

  @type draft_result :: {:ok, map()} | {:error, term()}
  @type thread_record :: map()

  # --- Public Contract Metadata ---

  @spec default_location() :: String.t()
  def default_location, do: @default_location

  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @spec supported_models() :: [String.t()]
  def supported_models, do: @supported_models

  @spec system_instruction() :: String.t()
  def system_instruction, do: @system_instruction

  @spec ash_table() :: String.t()
  def ash_table, do: @ash_table

  @spec allowed_folders() :: [String.t()]
  def allowed_folders, do: @allowed_folders

  @spec allowed_statuses() :: [String.t()]
  def allowed_statuses, do: @allowed_statuses

  @spec allowed_urgencies() :: [String.t()]
  def allowed_urgencies, do: @allowed_urgencies

  # --- Vertex AI Endpoint & Payload Contract ---

  @doc """
  Builds the canonical Vertex AI `:generateContent` endpoint URL.

  Uses `aiplatform.googleapis.com` for `"global"` and
  `"<location>-aiplatform.googleapis.com"` for regional locations.
  """
  @spec vertex_generate_url(String.t(), String.t(), String.t()) :: String.t()
  def vertex_generate_url(project, location \\ @default_location, model \\ @default_model)
      when is_binary(project) and is_binary(location) and is_binary(model) do
    host =
      if location == "global" do
        "aiplatform.googleapis.com"
      else
        "#{location}-aiplatform.googleapis.com"
      end

    "https://#{host}/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{model}:generateContent"
  end

  @doc """
  Builds the prompt string for `POST /api/ai/email-draft` matching
  `XaasWeb.GcpAiController.email_draft/2`.
  """
  @spec build_email_draft_prompt(map()) :: String.t()
  def build_email_draft_prompt(params) when is_map(params) do
    subject = param_str(params["subject"]) || @default_subject

    context =
      param_str(params["context"]) ||
        param_str(params["body"]) ||
        param_str(params["thread"]) ||
        ""

    tone = param_str(params["tone"]) || @default_tone

    """
    Draft a #{tone} email reply.
    Subject: #{subject}
    Context:
    #{context}
    """
  end

  @doc """
  Builds the Vertex AI `:generateContent` JSON request body with the
  ServEngine Email AI `systemInstruction`.
  """
  @spec build_vertex_request_body(String.t(), keyword()) :: map()
  def build_vertex_request_body(prompt, opts \\ []) when is_binary(prompt) do
    system_instruction = Keyword.get(opts, :system_instruction, @system_instruction)

    body = %{
      contents: [
        %{
          role: "user",
          parts: [%{text: prompt}]
        }
      ]
    }

    if is_binary(system_instruction) and system_instruction != "" do
      Map.put(body, :systemInstruction, %{parts: [%{text: system_instruction}]})
    else
      body
    end
  end

  @doc """
  Extracts generated text from a Vertex AI `:generateContent` response,
  filtering out Gemini thinking parts (`"thought" => true`) and rejecting
  incomplete `finishReason` values.
  """
  @spec extract_vertex_text(map()) :: {:ok, String.t()} | {:error, term()}
  def extract_vertex_text(%{"candidates" => [candidate | _]}) when is_map(candidate) do
    finish_reason = Map.get(candidate, "finishReason")

    parts =
      candidate
      |> get_in(["content", "parts"])
      |> List.wrap()

    text =
      parts
      |> Enum.reject(&Map.get(&1, "thought", false))
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.filter(&is_binary/1)
      |> Enum.join("")
      |> String.trim()

    cond do
      text != "" and finish_reason not in @incomplete_finish_reasons ->
        {:ok, text}

      finish_reason in @incomplete_finish_reasons ->
        {:error, {:vertex_ai_incomplete_response, finish_reason}}

      true ->
        {:error, :empty_model_response}
    end
  end

  def extract_vertex_text(_), do: {:error, :empty_model_response}

  # --- Email Draft Simulation & Validation ---

  @doc """
  Simulates `POST /api/ai/email-draft` end-to-end and returns the
  `GcpAiTextResponseSchema`-compliant envelope or typed Vertex AI error.
  """
  @spec simulate_email_draft(map(), keyword()) :: draft_result()
  def simulate_email_draft(params, opts \\ []) when is_map(params) do
    project = Keyword.get(opts, :project, @default_project)
    location = Keyword.get(opts, :location, @default_location)
    model = param_str(params["model"]) || Keyword.get(opts, :model, @default_model)
    generator = Keyword.get(opts, :generator)

    cond do
      not is_binary(project) or String.trim(project) == "" ->
        {:error, :vertex_ai_not_configured}

      model not in @supported_models ->
        {:error, {:unsupported_vertex_model, model}}

      is_function(generator, 2) ->
        prompt = build_email_draft_prompt(params)
        req_body = build_vertex_request_body(prompt, opts)

        case generator.(prompt, req_body) do
          {:ok, text} when is_binary(text) ->
            {:ok, draft_envelope(text, model, project, location)}

          {:ok, %{"candidates" => _} = raw_resp} ->
            with {:ok, text} <- extract_vertex_text(raw_resp) do
              {:ok, draft_envelope(text, model, project, location)}
            end

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        subject = param_str(params["subject"]) || @default_subject
        tone = param_str(params["tone"]) || @default_tone

        text =
          "Subject: Re: #{subject}\n\n" <>
            "Thank you for the update. Our facilities operations team has logged this request " <>
            "and will follow up promptly (#{tone})."

        {:ok, draft_envelope(text, model, project, location)}
    end
  end

  @doc """
  Validates a `POST /api/ai/email-draft` response envelope against
  `GcpAiTextResponseSchema`.
  """
  @spec validate_draft_envelope(map()) :: :ok | {:error, [String.t()]}
  def validate_draft_envelope(%{"data" => data}) when is_map(data) do
    validate_draft_envelope(%{data: atomize_draft_keys(data)})
  end

  def validate_draft_envelope(%{data: data}) when is_map(data) do
    errors =
      []
      |> check(is_binary(data[:text]) and String.trim(data[:text]) != "", "data.text must be a non-empty string")
      |> check(data[:model] in @supported_models, "data.model must be one of #{inspect(@supported_models)}")
      |> check(is_binary(data[:location]) and data[:location] != "", "data.location must be a non-empty string")
      |> check(is_nil(data[:project]) or is_binary(data[:project]), "data.project must be a string or nil")

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  def validate_draft_envelope(_), do: {:error, ["envelope must be a map with a data object"]}

  # --- EmailAiThread AshPostgres Contract ---

  @doc """
  Builds an `EmailAiThread` record (`crud_email_ai_threads`) from create params
  for `tenant_id`, enforcing the `CrudC04EmailAiController` contract.
  """
  @spec build_email_ai_thread(map(), String.t(), keyword()) :: {:ok, thread_record()} | {:error, String.t()}
  def build_email_ai_thread(params, tenant_id, opts \\ [])
      when is_map(params) and is_binary(tenant_id) and byte_size(tenant_id) > 0 do
    subject =
      params
      |> Map.take(["subject", "title", "name"])
      |> Map.values()
      |> Enum.find_value(&non_blank_string/1)

    if is_nil(subject) do
      {:error, "subject is required"}
    else
      folder = normalize_enum(params["folder"], @allowed_folders, "inbox")
      status = normalize_enum(params["status"], @allowed_statuses, "open")
      urgency = normalize_enum(params["urgency"], @allowed_urgencies, "normal")
      category = non_blank_string(params["category"]) || "general"
      from = non_blank_string(params["from"]) || Keyword.get(opts, :default_from, "")
      to_list = normalize_email_list(params["to"])
      cc_list = normalize_email_list(params["cc"])
      body = to_string_safe(params["body"])
      replies = normalize_replies(params["replies"])
      deleted = params["deleted"] == true
      id = Keyword.get_lazy(opts, :id, &generate_uuid/0)
      now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

      payload = %{
        "tenant_id" => tenant_id,
        "subject" => subject,
        "folder" => folder,
        "from" => from,
        "to" => to_list,
        "cc" => cc_list,
        "body" => body,
        "status" => status,
        "category" => category,
        "urgency" => urgency,
        "replies" => replies,
        "deleted" => deleted
      }

      {:ok,
       %{
         id: id,
         tenant_id: tenant_id,
         table: @ash_table,
         name: subject,
         title: subject,
         subject: subject,
         folder: folder,
         from: from,
         to: to_list,
         cc: cc_list,
         body: body,
         status: status,
         category: category,
         urgency: urgency,
         replies: replies,
         deleted: deleted,
         payload: payload,
         created_at: now,
         updated_at: now
       }}
    end
  end

  @doc """
  Attaches a Vertex AI generated draft reply to an `EmailAiThread` record,
  recording the Vertex AI model/location metadata and updating status.
  """
  @spec attach_draft_reply(thread_record(), map(), keyword()) :: {:ok, thread_record()} | {:error, term()}
  def attach_draft_reply(%{tenant_id: tenant_id} = thread, %{data: draft}, opts \\ [])
      when is_binary(tenant_id) and is_map(draft) do
    with :ok <- validate_draft_envelope(%{data: draft}) do
      target_status = normalize_enum(Keyword.get(opts, :status, "draft"), @allowed_statuses, "draft")
      author = Keyword.get(opts, :from, "ai-assistant@servengine.local")
      now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

      reply_entry = %{
        "from" => author,
        "body" => draft.text,
        "model" => draft.model,
        "location" => draft.location,
        "project" => draft.project,
        "created_at" => now
      }

      replies = List.wrap(thread.replies) ++ [reply_entry]

      updated_payload =
        thread.payload
        |> Map.put("replies", replies)
        |> Map.put("status", target_status)

      {:ok,
       %{
         thread
         | replies: replies,
           status: target_status,
           payload: updated_payload,
           updated_at: now
       }}
    end
  end

  @doc """
  Validates an `EmailAiThread` record against the AshPostgres
  `crud_email_ai_threads` contract (tenant binding, required fields, enums,
  and payload mirror parity).
  """
  @spec validate_thread_contract(thread_record(), String.t()) :: :ok | {:error, [String.t()]}
  def validate_thread_contract(record, expected_tenant_id)
      when is_map(record) and is_binary(expected_tenant_id) do
    payload = Map.get(record, :payload) || %{}

    errors =
      []
      |> check(is_binary(record[:id]) and byte_size(record[:id]) > 0, "id must be a non-empty string")
      |> check(record[:tenant_id] == expected_tenant_id, "tenant_id mismatch (fail-closed isolation)")
      |> check(payload["tenant_id"] == expected_tenant_id, "payload.tenant_id must match tenant_id")
      |> check(is_binary(record[:subject]) and String.trim(record[:subject]) != "", "subject is required")
      |> check(record[:folder] in @allowed_folders, "invalid folder: #{inspect(record[:folder])}")
      |> check(record[:status] in @allowed_statuses, "invalid status: #{inspect(record[:status])}")
      |> check(record[:urgency] in @allowed_urgencies, "invalid urgency: #{inspect(record[:urgency])}")
      |> check(is_list(record[:to]), "to must be a list")
      |> check(is_list(record[:cc]), "cc must be a list")
      |> check(is_list(record[:replies]), "replies must be a list")
      |> check(is_boolean(record[:deleted]), "deleted must be a boolean")

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  # --- Plug Interface (POST /api/ai/email-draft & GET /api/ai/status) ---

  @impl true
  def init(opts) when is_list(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", request_path: "/api/ai/status"} = conn, opts) do
    project = Keyword.get(opts, :project, @default_project)
    location = Keyword.get(opts, :location, @default_location)
    model = Keyword.get(opts, :model, @default_model)

    send_json(conn, 200, %{
      data: %{
        configured: is_binary(project) and String.trim(project) != "",
        project: project,
        location: location,
        model: model
      }
    })
  end

  def call(%Plug.Conn{method: "POST", request_path: "/api/ai/email-draft"} = conn, opts) do
    with :ok <- authorize_request(conn, opts) do
      params = conn.body_params || %{}

      case simulate_email_draft(params, opts) do
        {:ok, envelope} ->
          send_json(conn, 200, envelope)

        {:error, reason} ->
          {status, body} = map_vertex_error(reason)
          send_json(conn, status, body)
      end
    else
      {:error, {status, body}} ->
        send_json(conn, status, body)
    end
  end

  def call(%Plug.Conn{} = conn, _opts) do
    send_json(conn, 404, %{error: "not_found"})
  end

  @doc """
  Maps Vertex AI error tuples to the exact HTTP status and JSON error contract
  implemented in `XaasWeb.GcpAiController.respond_vertex/2`.
  """
  @spec map_vertex_error(term()) :: {pos_integer(), map()}
  def map_vertex_error(:vertex_ai_not_configured) do
    {503, %{error: "Vertex AI is not configured", code: "vertex_ai_not_configured"}}
  end

  def map_vertex_error(:no_gcp_access_token) do
    {503, %{error: "Unable to acquire GCP access token", code: "no_gcp_access_token"}}
  end

  def map_vertex_error({:vertex_ai_http_error, 429, _}) do
    {429, %{error: "Vertex AI rate limit exceeded", code: "vertex_ai_rate_limited"}}
  end

  def map_vertex_error({:vertex_ai_http_error, _code, _}) do
    {502, %{error: "Vertex AI upstream error", code: "vertex_ai_http_error"}}
  end

  def map_vertex_error({:unsupported_vertex_model, model}) do
    {422, %{error: "Unsupported Vertex AI model: #{model}", code: "unsupported_vertex_model"}}
  end

  def map_vertex_error(_) do
    {503, %{error: "Vertex AI service unavailable", code: "vertex_ai_unavailable"}}
  end

  # --- Internal Helpers ---

  defp authorize_request(conn, opts) do
    if Keyword.get(opts, :require_auth?, true) do
      has_bearer? =
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token | _] -> String.trim(token) != ""
          _ -> false
        end

      if not has_bearer? do
        {:error, {401, %{error: "unauthorized", detail: "missing or invalid Bearer token"}}}
      else
        case get_req_header(conn, "x-tenant-id") do
          [tid] when is_binary(tid) and byte_size(tid) > 0 ->
            :ok

          [] ->
            {:error, {403, %{error: "tenant_required", detail: "x-tenant-id header is required"}}}

          _ ->
            {:error, {403, %{error: "unknown_tenant", detail: "multiple x-tenant-id headers"}}}
        end
      end
    else
      :ok
    end
  end

  defp draft_envelope(text, model, project, location) do
    %{
      data: %{
        text: text,
        model: model,
        project: project,
        location: location
      }
    }
  end

  defp atomize_draft_keys(data) do
    %{
      text: data["text"] || data[:text],
      model: data["model"] || data[:model],
      project: Map.get(data, "project", Map.get(data, :project)),
      location: data["location"] || data[:location]
    }
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
    |> halt()
  end

  defp param_str(val) when is_binary(val), do: val
  defp param_str(_), do: nil

  defp non_blank_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_blank_string(_), do: nil

  defp to_string_safe(val) when is_binary(val), do: val
  defp to_string_safe(_), do: ""

  defp normalize_enum(val, allowed, default) when is_binary(val) do
    down = val |> String.trim() |> String.downcase()
    if down in allowed, do: down, else: default
  end

  defp normalize_enum(_, _allowed, default), do: default

  defp normalize_email_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_email_list(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_email_list(_), do: []

  defp normalize_replies(list) when is_list(list), do: list
  defp normalize_replies(_), do: []

  defp check(errors, true, _msg), do: errors
  defp check(errors, false, msg), do: [msg | errors]

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      Bitwise.band(c, 0x0FFF),
      Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
      e
    ])
    |> IO.iodata_to_binary()
  end
end

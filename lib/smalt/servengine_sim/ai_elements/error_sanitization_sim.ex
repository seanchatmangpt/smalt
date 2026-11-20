defmodule Smalt.ServengineSim.AiElements.ErrorSanitizationSim do
  @moduledoc """
  ServEngine AI Elements (Chatbot, Workflow, IDE) + Vertex AI error sanitization
  and safe non-string parameter handling simulator.

  Mirrors the contract of `XaasWeb.AiElementsController` in `/Users/sac/srve`:

    * **Clean JSON error responses**: Every Vertex AI or request validation
      failure is mapped to a stable HTTP status and JSON object (`error`, `code`,
      and optional `allowed_models` / `upstream_status`) with **zero raw Elixir
      `inspect/1` leakage** (no `%Struct{}`, `%{...}`, `{:atom, ...}`,
      `#PID<...>`, `#Reference<...>`, or `=>` map arrows).
    * **Safe non-string param handling**: Arbitrary JSON types (integers,
      floats, booleans, lists, maps, `nil`) in any parameter slot (`model`,
      `prompt`, `message`, `messages`, `instruction`, `input`, `context`,
      `code`, `language`, `file_path`, `filename`, `action`, `step`,
      `step_name`, `node`, `workflow`, `workflow_name`, `system`,
      `system_instruction`) never crash with `FunctionClauseError` or
      `Protocol.UndefinedError`.
    * **Vertex AI alignment**: Enforces `global` location and the allowed model
      allowlist (`gemini-4-neon`).
  """

  @behaviour Plug

  import Plug.Conn

  @allowed_models [
    "gemini-4-neon"
  ]

  @default_model "gemini-4-neon"
  @default_location "global"
  @default_project "servengine-sim"

  @default_chat_system "You are ServEngine AI Assistant. Provide clear, accurate, concise responses."
  @default_workflow_system "You are ServEngine Workflow AI. Execute the requested workflow step accurately and return structured, actionable output."
  @default_ide_system "You are ServEngine IDE Assistant. Provide precise, production-ready code assistance without placeholders or stubs."

  @inspect_leakage_patterns [
    {:elixir_struct, ~r/%[A-Z][A-Za-z0-9_.]*\{/},
    {:elixir_map, ~r/%\{/},
    {:elixir_tuple, ~r/\{:[a-z_][a-zA-Z0-9_]*,/},
    {:elixir_opaque_term, ~r/#(?:PID|Reference|Port|Function)<[^>]+>/},
    {:elixir_map_arrow, ~r/=>/}
  ]

  @type endpoint :: :chat | :workflow_step | :ide_assist

  @doc "Returns the allowed Vertex AI model identifiers."
  @spec allowed_models() :: [String.t()]
  def allowed_models, do: @allowed_models

  @doc "Returns the default Vertex AI model identifier."
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc "Returns the default Vertex AI location (`global`)."
  @spec default_location() :: String.t()
  def default_location, do: @default_location

  # ---------------------------------------------------------------------------
  # Plug interface
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) when is_list(opts), do: opts

  @impl true
  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(%Plug.Conn{} = conn, opts) do
    opts = if is_list(opts), do: opts, else: []

    case route_endpoint(conn.method, conn.request_path) do
      {:ok, endpoint} ->
        params = extract_params(conn)
        handle_endpoint(conn, endpoint, params, opts)

      :not_found ->
        send_json(conn, 404, %{"error" => "not found", "code" => "not_found"})
    end
  end

  defp route_endpoint("POST", "/api/ai/elements/chat"), do: {:ok, :chat}
  defp route_endpoint("POST", "/api/ai/elements/workflow-step"), do: {:ok, :workflow_step}
  defp route_endpoint("POST", "/api/ai/elements/ide-assist"), do: {:ok, :ide_assist}
  defp route_endpoint(_, _), do: :not_found

  defp extract_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case conn.params do
      %Plug.Conn.Unfetched{} -> %{}
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp extract_params(%Plug.Conn{body_params: body_params}) when is_map(body_params) do
    body_params
  end

  defp extract_params(_conn), do: %{}

  defp handle_endpoint(conn, endpoint, params, opts) do
    backend = Keyword.get(opts, :backend, &default_backend/2)
    project = Keyword.get(opts, :project, @default_project)
    location = Keyword.get(opts, :location, @default_location)

    case validate_params(endpoint, params) do
      {:ok, validated} ->
        backend_opts = [
          model: validated.model,
          system_instruction: validated.system_instruction,
          location: location,
          project: project
        ]

        case backend.(validated.prompt, backend_opts) do
          {:ok, text} when is_binary(text) ->
            send_json(conn, 200, build_success_payload(endpoint, text, validated, project, location))

          {:error, reason} ->
            {status, body} = sanitize_error(reason)
            send_json(conn, status, body)

          unexpected ->
            {status, body} = sanitize_error(unexpected)
            send_json(conn, status, body)
        end

      {:error, reason} ->
        {status, body} = sanitize_error(reason)
        send_json(conn, status, body)
    end
  end

  defp default_backend(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    {:ok, "[#{model}] #{prompt}"}
  end

  defp build_success_payload(:chat, text, validated, project, location) do
    %{
      "data" => %{
        "text" => text,
        "role" => "assistant",
        "model" => validated.model,
        "project" => project,
        "location" => location
      }
    }
  end

  defp build_success_payload(:workflow_step, text, validated, project, location) do
    %{
      "data" => %{
        "text" => text,
        "step" => validated.meta.step,
        "status" => "completed",
        "model" => validated.model,
        "project" => project,
        "location" => location
      }
    }
  end

  defp build_success_payload(:ide_assist, text, validated, project, location) do
    %{
      "data" => %{
        "text" => text,
        "language" => validated.meta.language,
        "file_path" => validated.meta.file_path,
        "action" => validated.meta.action,
        "model" => validated.model,
        "project" => project,
        "location" => location
      }
    }
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
    |> halt()
  end

  # ---------------------------------------------------------------------------
  # Error sanitization (zero raw Elixir inspect leakage)
  # ---------------------------------------------------------------------------

  @doc """
  Maps an internal controller or Vertex AI error reason to `{http_status, json_map}`.

  Guarantees that no raw Elixir `inspect/1` representation of structs, maps,
  tuples, PIDs, references, or transport errors is ever returned in the JSON
  payload.
  """
  @spec sanitize_error(term()) :: {pos_integer(), map()}
  def sanitize_error(:invalid_model) do
    {400,
     %{
       "error" => "unsupported model",
       "code" => "invalid_model",
       "allowed_models" => @allowed_models
     }}
  end

  def sanitize_error({:missing_prompt, :chat}) do
    {400, %{"error" => "messages or prompt is required", "code" => "invalid_request"}}
  end

  def sanitize_error({:missing_prompt, :workflow_step}) do
    {400, %{"error" => "prompt or input is required", "code" => "invalid_request"}}
  end

  def sanitize_error({:missing_prompt, :ide_assist}) do
    {400, %{"error" => "instruction or prompt is required", "code" => "invalid_request"}}
  end

  def sanitize_error(:missing_prompt) do
    {400, %{"error" => "messages or prompt is required", "code" => "invalid_request"}}
  end

  def sanitize_error(:vertex_ai_not_configured) do
    {503, %{"error" => "Vertex AI is not configured", "code" => "vertex_ai_not_configured"}}
  end

  def sanitize_error(:no_gcp_access_token) do
    {503, %{"error" => "Unable to acquire GCP access token", "code" => "no_gcp_access_token"}}
  end

  def sanitize_error({:vertex_ai_http_error, status, resp}) when is_integer(status) do
    message =
      extract_upstream_error_message(resp) || "Vertex AI upstream error (HTTP #{status})"

    http_status = if status == 429, do: 429, else: 502

    {http_status,
     %{
       "error" => message,
       "code" => "vertex_ai_http_error",
       "upstream_status" => status
     }}
  end

  def sanitize_error({:vertex_ai_request_failed, _reason}) do
    {503, %{"error" => "Vertex AI request failed", "code" => "vertex_ai_request_failed"}}
  end

  def sanitize_error(_unexpected) do
    {503, %{"error" => "Vertex AI service unavailable", "code" => "vertex_ai_unavailable"}}
  end

  @doc """
  Extracts a clean upstream error message from a Vertex AI error JSON map.
  Returns `nil` for non-map, empty, or non-string error payloads.
  """
  @spec extract_upstream_error_message(term()) :: String.t() | nil
  def extract_upstream_error_message(%{"error" => %{"message" => msg}})
      when is_binary(msg) do
    non_empty_string(msg)
  end

  def extract_upstream_error_message(_), do: nil

  @doc """
  Scans a binary (e.g. encoded JSON response body) for raw Elixir `inspect/1`
  leakage such as structs (`%Mod{`), maps (`%{`), tagged tuples (`{:atom,`),
  opaque terms (`#PID<...>`), or map arrows (`=>`).
  """
  @spec detect_inspect_leakage(String.t()) :: :ok | {:error, {:inspect_leakage, [atom()]}}
  def detect_inspect_leakage(body) when is_binary(body) do
    matches =
      @inspect_leakage_patterns
      |> Enum.filter(fn {_tag, regex} -> Regex.match?(regex, body) end)
      |> Enum.map(fn {tag, _regex} -> tag end)

    case matches do
      [] -> :ok
      leaked -> {:error, {:inspect_leakage, leaked}}
    end
  end

  @doc """
  Verifies that a raw JSON response body is a valid JSON error object with
  non-empty string `"error"` and `"code"` fields and zero raw Elixir `inspect`
  leakage.
  """
  @spec verify_clean_json_error(String.t()) :: :ok | {:error, term()}
  def verify_clean_json_error(raw_json) when is_binary(raw_json) do
    with {:ok, decoded} <- Jason.decode(raw_json),
         true <- is_map(decoded) or {:error, :not_a_json_object},
         true <-
           (is_binary(decoded["error"]) and String.trim(decoded["error"]) != "") or
             {:error, :missing_error_field},
         true <-
           (is_binary(decoded["code"]) and String.trim(decoded["code"]) != "") or
             {:error, :missing_code_field},
         :ok <- detect_inspect_leakage(raw_json) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Safe non-string parameter handling
  # ---------------------------------------------------------------------------

  @doc """
  Validates and normalizes request parameters for `:chat`, `:workflow_step`, or
  `:ide_assist`. Safely handles non-string values in every parameter slot.
  """
  @spec validate_params(endpoint(), term()) :: {:ok, map()} | {:error, term()}
  def validate_params(endpoint, params)
      when endpoint in [:chat, :workflow_step, :ide_assist] do
    safe_params = if is_map(params), do: params, else: %{}

    with {:ok, model} <- resolve_model(Map.get(safe_params, "model")),
         {:ok, prompt, system_instruction, meta} <- build_endpoint_prompt(endpoint, safe_params) do
      {:ok,
       %{
         model: model,
         prompt: prompt,
         system_instruction: system_instruction,
         meta: meta
       }}
    end
  end

  @doc """
  Resolves the requested Vertex AI model. `nil`, `""`, and whitespace-only
  strings default to `gemini-4-neon`. Non-string values (integers,
  maps, lists, booleans) and unknown model names return `{:error, :invalid_model}`.
  """
  @spec resolve_model(term()) :: {:ok, String.t()} | {:error, :invalid_model}
  def resolve_model(nil), do: {:ok, @default_model}
  def resolve_model(""), do: {:ok, @default_model}

  def resolve_model(model) when is_binary(model) do
    trimmed = String.trim(model)

    cond do
      trimmed == "" -> {:ok, @default_model}
      trimmed in @allowed_models -> {:ok, trimmed}
      true -> {:error, :invalid_model}
    end
  end

  def resolve_model(_), do: {:error, :invalid_model}

  @doc """
  Returns the trimmed binary if `val` is a non-empty string, or `nil` for
  whitespace-only strings and any non-string value.
  """
  @spec non_empty_string(term()) :: String.t() | nil
  def non_empty_string(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def non_empty_string(_), do: nil

  @doc """
  Formats workflow `input` / `context` values safely: strings are trimmed,
  maps/lists are JSON-encoded, and other non-string values return `nil`.
  """
  @spec format_input(term()) :: String.t() | nil
  def format_input(nil), do: nil
  def format_input(val) when is_binary(val), do: non_empty_string(val)

  def format_input(val) when is_map(val) or is_list(val) do
    case Jason.encode(val) do
      {:ok, encoded} -> non_empty_string(encoded)
      {:error, _} -> nil
    end
  end

  def format_input(_), do: nil

  @doc """
  Extracts text from a chat message map (`content`, `parts`, or `text`).
  Safely returns `""` for non-string values or non-map entries.
  """
  @spec extract_message_text(term()) :: String.t()
  def extract_message_text(%{"content" => content}) when is_binary(content) do
    String.trim(content)
  end

  def extract_message_text(%{"parts" => parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
    |> String.trim()
  end

  def extract_message_text(%{"text" => text}) when is_binary(text) do
    String.trim(text)
  end

  def extract_message_text(_), do: ""

  defp build_endpoint_prompt(:chat, params) do
    explicit_system =
      non_empty_string(params["system"]) || non_empty_string(params["system_instruction"])

    case params["messages"] do
      messages when is_list(messages) and messages != [] ->
        {system_msgs, conv_msgs} =
          Enum.split_with(messages, fn msg ->
            is_map(msg) and Map.get(msg, "role") == "system"
          end)

        inferred_system =
          system_msgs
          |> Enum.map(&extract_message_text/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")
          |> non_empty_string()

        formatted =
          conv_msgs
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn msg ->
            role = safe_role(Map.get(msg, "role"))
            text = extract_message_text(msg)
            if text == "", do: nil, else: "#{String.capitalize(role)}: #{text}"
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n\n")

        fallback_prompt =
          non_empty_string(params["prompt"]) || non_empty_string(params["message"])

        final_prompt =
          case {non_empty_string(formatted), fallback_prompt} do
            {nil, nil} -> nil
            {text, nil} -> text
            {nil, extra} -> extra
            {text, extra} -> "#{text}\n\nUser: #{extra}"
          end

        case final_prompt do
          nil ->
            {:error, {:missing_prompt, :chat}}

          prompt ->
            {:ok, prompt, explicit_system || inferred_system || @default_chat_system, %{}}
        end

      _ ->
        case non_empty_string(params["prompt"]) || non_empty_string(params["message"]) do
          nil ->
            {:error, {:missing_prompt, :chat}}

          prompt ->
            {:ok, prompt, explicit_system || @default_chat_system, %{}}
        end
    end
  end

  defp build_endpoint_prompt(:workflow_step, params) do
    instruction =
      non_empty_string(params["prompt"]) || non_empty_string(params["instruction"])

    input = format_input(params["input"] || params["context"])

    step_name =
      non_empty_string(params["step"]) ||
        non_empty_string(params["step_name"]) ||
        non_empty_string(params["node"]) ||
        "workflow_step"

    workflow_name =
      non_empty_string(params["workflow"]) || non_empty_string(params["workflow_name"])

    system_instruction =
      non_empty_string(params["system"]) ||
        non_empty_string(params["system_instruction"]) ||
        @default_workflow_system

    if is_nil(instruction) and is_nil(input) do
      {:error, {:missing_prompt, :workflow_step}}
    else
      sections =
        [
          if(workflow_name, do: "Workflow: #{workflow_name}"),
          "Step: #{step_name}",
          if(instruction, do: "Instruction:\n#{instruction}"),
          if(input, do: "Input:\n#{input}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      {:ok, sections, system_instruction, %{step: step_name}}
    end
  end

  defp build_endpoint_prompt(:ide_assist, params) do
    instruction =
      non_empty_string(params["instruction"]) || non_empty_string(params["prompt"])

    code = non_empty_string(params["code"])
    language = non_empty_string(params["language"]) || "text"

    file_path =
      non_empty_string(params["file_path"]) || non_empty_string(params["filename"])

    action = non_empty_string(params["action"]) || "assist"

    system_instruction =
      non_empty_string(params["system"]) ||
        non_empty_string(params["system_instruction"]) ||
        @default_ide_system

    if is_nil(instruction) do
      {:error, {:missing_prompt, :ide_assist}}
    else
      sections =
        [
          "Action: #{action}",
          "Language: #{language}",
          if(file_path, do: "File: #{file_path}"),
          "Instruction:\n#{instruction}",
          if(code, do: "Code:\n```#{language}\n#{code}\n```")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      {:ok, sections, system_instruction,
       %{language: language, file_path: file_path, action: action}}
    end
  end

  defp safe_role(role) when is_binary(role) do
    case String.trim(role) do
      "" -> "user"
      trimmed -> trimmed
    end
  end

  defp safe_role(_), do: "user"
end

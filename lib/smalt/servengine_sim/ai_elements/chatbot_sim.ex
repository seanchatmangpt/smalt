defmodule Smalt.ServengineSim.AiElements.ChatbotSim do
  @moduledoc """
  Simulator for the ServEngine `/ai/chatbot` AI Elements workspace backed by
  GCP Vertex AI (`global` location, `gemini-4-neon` and
  `gemini-4-neon`).

  Mirrors the frontend state machine in
  `servengine-frontend/src/components/features/AiElements/chatbot/useVertexChat.ts`,
  `ChatbotWorkspace.tsx`, and `src/api/ai-elements/vertexClient.ts`:

    * Multi-turn Vertex chat via `POST /api/ai/chat` with full conversation
      history projection (`role`, `content`), optional `system`, `temperature`,
      `maxOutputTokens`, and `context`.
    * Live status probing via `GET /api/ai/status` (`configured`, `project`,
      `location: "global"`, `model`, `availableModels`).
    * Runtime model switching between `"gemini-4-neon"` and
      `"gemini-4-neon"` while preserving conversation history.
    * Last-turn regeneration (`regenerate_last/1`) that trims back to the most
      recent `"user"` message and re-dispatches with the currently active model.
    * Chat clearing (`clear_chat/1`) that resets messages and errors while
      retaining the selected model and Vertex configuration.
  """

  @route "/ai/chatbot"
  @chat_endpoint "/api/ai/chat"
  @status_endpoint "/api/ai/status"
  @default_location "global"
  @default_project "servengine-prod"
  @default_model "gemini-4-neon"
  @supported_models ["gemini-4-neon"]

  @type model_id :: String.t()
  @type role :: String.t()

  @type usage :: %{
          promptTokens: non_neg_integer(),
          completionTokens: non_neg_integer(),
          totalTokens: non_neg_integer()
        }

  @type chat_message :: %{
          required(:id) => String.t(),
          required(:role) => role(),
          required(:content) => String.t(),
          required(:timestamp) => String.t(),
          optional(:model) => model_id() | nil,
          optional(:usage) => usage() | nil
        }

  @type recorded_request :: %{
          endpoint: String.t(),
          method: String.t(),
          body: map() | nil
        }

  @type transport_fn :: (recorded_request() -> {:ok, map()} | {:error, term()})

  @type t :: %__MODULE__{
          route: String.t(),
          model: model_id(),
          location: String.t(),
          project: String.t(),
          configured: boolean(),
          system_prompt: String.t() | nil,
          temperature: float() | nil,
          max_output_tokens: pos_integer() | nil,
          context: map() | nil,
          messages: [chat_message()],
          is_loading: boolean(),
          error: String.t() | nil,
          seq: non_neg_integer(),
          requests: [recorded_request()],
          transport: transport_fn() | nil
        }

  defstruct route: @route,
            model: @default_model,
            location: @default_location,
            project: @default_project,
            configured: true,
            system_prompt: nil,
            temperature: nil,
            max_output_tokens: nil,
            context: nil,
            messages: [],
            is_loading: false,
            error: nil,
            seq: 0,
            requests: [],
            transport: nil

  @doc "Canonical frontend route for the AI Elements chatbot workspace."
  @spec route() :: String.t()
  def route, do: @route

  @doc "Canonical backend endpoint for Vertex AI chat turns."
  @spec chat_endpoint() :: String.t()
  def chat_endpoint, do: @chat_endpoint

  @doc "Canonical backend endpoint for Vertex AI status checks."
  @spec status_endpoint() :: String.t()
  def status_endpoint, do: @status_endpoint

  @doc "Default GCP Vertex AI location (`\"global\"`)."
  @spec default_location() :: String.t()
  def default_location, do: @default_location

  @doc "Default Vertex AI model (`\"gemini-4-neon\"`)."
  @spec default_model() :: model_id()
  def default_model, do: @default_model

  @doc "Supported Vertex AI models in the `/ai/chatbot` model selector."
  @spec supported_models() :: [model_id()]
  def supported_models, do: @supported_models

  @doc "Returns `true` if `model` is a supported `/ai/chatbot` Vertex model."
  @spec supported_model?(term()) :: boolean()
  def supported_model?(model) when is_binary(model), do: model in @supported_models
  def supported_model?(_), do: false

  @doc """
  Creates a new `/ai/chatbot` simulation session.

  Options:
    * `:initial_model` - initial Vertex model (defaults to `"gemini-4-neon"`;
      unsupported values fall back to `"gemini-4-neon"`, matching `ChatbotWorkspace`).
    * `:initial_messages` - initial list of chat messages (defaults to `[]`).
    * `:system_prompt` - optional system instruction forwarded as `system`.
    * `:temperature` - optional sampling temperature.
    * `:max_output_tokens` - optional `maxOutputTokens` cap.
    * `:context` - optional context map forwarded to `/api/ai/chat`.
    * `:project` - GCP project ID (defaults to `"servengine-prod"`).
    * `:location` - GCP Vertex AI location (defaults to `"global"`).
    * `:configured` - whether Vertex credentials are configured (defaults to `true`).
    * `:transport` - optional 1-arity function `(request -> {:ok, response} | {:error, reason})`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    raw_model = Keyword.get(opts, :initial_model, @default_model)
    model = if supported_model?(raw_model), do: raw_model, else: @default_model
    initial_messages = Keyword.get(opts, :initial_messages, [])

    %__MODULE__{
      route: @route,
      model: model,
      location: Keyword.get(opts, :location, @default_location),
      project: Keyword.get(opts, :project, @default_project),
      configured: Keyword.get(opts, :configured, true),
      system_prompt: Keyword.get(opts, :system_prompt),
      temperature: Keyword.get(opts, :temperature),
      max_output_tokens: Keyword.get(opts, :max_output_tokens),
      context: Keyword.get(opts, :context),
      messages: initial_messages,
      seq: length(initial_messages),
      transport: Keyword.get(opts, :transport)
    }
  end

  @doc """
  Simulates `GET /api/ai/status` to verify Vertex AI readiness.
  """
  @spec fetch_status(t()) :: {:ok, map(), t()} | {:error, String.t(), t()}
  def fetch_status(%__MODULE__{} = state) do
    request = %{endpoint: @status_endpoint, method: "GET", body: nil}
    state = record_request(state, request)

    case dispatch_transport(state, request) do
      {:ok, payload} ->
        {:ok, payload, state}

      {:error, reason} ->
        {:error, format_error(reason), state}
    end
  end

  @doc """
  Switches the active Vertex AI model while preserving conversation history.
  """
  @spec set_model(t(), model_id()) :: {:ok, t()} | {:error, {:unsupported_model, term()}}
  def set_model(%__MODULE__{} = state, model) do
    if supported_model?(model) do
      {:ok, %{state | model: model}}
    else
      {:error, {:unsupported_model, model}}
    end
  end

  @doc """
  Mirrors `ChatbotWorkspace.handleSubmit(prompt, selectedModel)`: switches
  models when `selected_model` differs from the active model, then sends the
  user prompt.
  """
  @spec submit_with_model(t(), String.t(), model_id()) ::
          {:ok, chat_message(), t()}
          | {:noop, t()}
          | {:error, term(), t()}
  def submit_with_model(%__MODULE__{} = state, content, selected_model) do
    case set_model(state, selected_model) do
      {:ok, updated} -> send_message(updated, content)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc """
  Sends a user message and executes a Vertex AI chat turn via `POST /api/ai/chat`.

  Blank or whitespace-only messages are ignored and return `{:noop, state}`.
  On transport failure, the user message remains in `state.messages` and
  `state.error` is populated (matching `useVertexChat.ts`).
  """
  @spec send_message(t(), String.t()) ::
          {:ok, chat_message(), t()} | {:noop, t()} | {:error, String.t(), t()}
  def send_message(%__MODULE__{} = state, content) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:noop, state}
    else
      next_seq = state.seq + 1

      user_message = %{
        id: "user-#{next_seq}",
        role: "user",
        content: trimmed,
        timestamp: synthetic_timestamp(next_seq)
      }

      next_state = %{
        state
        | messages: state.messages ++ [user_message],
          seq: next_seq
      }

      execute_chat(next_state)
    end
  end

  @doc """
  Regenerates the last assistant response by trimming history back to the most
  recent `"user"` message and re-issuing `POST /api/ai/chat` with the currently
  selected model.

  Returns `{:noop, state}` when no `"user"` message exists in the conversation.
  """
  @spec regenerate_last(t()) ::
          {:ok, chat_message(), t()} | {:noop, t()} | {:error, String.t(), t()}
  def regenerate_last(%__MODULE__{messages: messages} = state) do
    case last_user_index(messages) do
      nil ->
        {:noop, state}

      idx ->
        trimmed_history = Enum.slice(messages, 0..idx)
        execute_chat(%{state | messages: trimmed_history})
    end
  end

  @doc """
  Clears all chat messages and error state while preserving the active model
  and Vertex AI configuration.
  """
  @spec clear_chat(t()) :: t()
  def clear_chat(%__MODULE__{} = state) do
    %{state | messages: [], error: nil, is_loading: false}
  end

  @doc "Clears the current error banner without altering messages."
  @spec clear_error(t()) :: t()
  def clear_error(%__MODULE__{} = state) do
    %{state | error: nil}
  end

  @doc """
  Projects internal chat messages into the `VertexChatMessage[]` wire shape
  (`%{role: ..., content: ...}`).
  """
  @spec to_vertex_messages([chat_message()]) :: [%{role: role(), content: String.t()}]
  def to_vertex_messages(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg.role, content: msg.content}
    end)
  end

  @doc """
  Validates structural invariants of a simulated `/ai/chatbot` session.
  """
  @spec validate_session(t()) :: :ok | {:error, [String.t()]}
  def validate_session(%__MODULE__{} = state) do
    errors =
      []
      |> check(state.route == @route, "route must be #{@route}")
      |> check(state.location == @default_location, "location must be #{@default_location}")
      |> check(supported_model?(state.model), "unsupported active model: #{inspect(state.model)}")
      |> check(
        Enum.all?(state.messages, &valid_message?/1),
        "all messages must have valid id, role, and non-empty content"
      )
      |> check(
        Enum.all?(state.requests, &valid_request?/1),
        "all recorded requests must match the Vertex AI endpoint contract"
      )

    case errors do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  # -- Private helpers --------------------------------------------------------

  defp execute_chat(%__MODULE__{} = state) do
    body = build_chat_request_body(state)
    request = %{endpoint: @chat_endpoint, method: "POST", body: body}
    state = %{record_request(state, request) | is_loading: true, error: nil}

    case dispatch_transport(state, request) do
      {:ok, response} ->
        next_seq = state.seq + 1
        response_model = Map.get(response, :model) || Map.get(response, "model") || state.model
        response_text = Map.get(response, :text) || Map.get(response, "text") || ""
        response_usage = Map.get(response, :usage) || Map.get(response, "usage")

        assistant_message = %{
          id: "assistant-#{next_seq}",
          role: "assistant",
          content: response_text,
          timestamp: synthetic_timestamp(next_seq),
          model: response_model,
          usage: response_usage
        }

        updated = %{
          state
          | messages: state.messages ++ [assistant_message],
            seq: next_seq,
            is_loading: false,
            error: nil
        }

        {:ok, assistant_message, updated}

      {:error, reason} ->
        err_msg = format_error(reason)
        updated = %{state | is_loading: false, error: err_msg}
        {:error, err_msg, updated}
    end
  end

  defp build_chat_request_body(%__MODULE__{} = state) do
    base = %{
      messages: to_vertex_messages(state.messages),
      model: state.model
    }

    base
    |> maybe_put(:system, state.system_prompt)
    |> maybe_put(:temperature, state.temperature)
    |> maybe_put(:maxOutputTokens, state.max_output_tokens)
    |> maybe_put(:context, state.context)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp dispatch_transport(%__MODULE__{transport: transport}, request)
       when is_function(transport, 1) do
    transport.(request)
  end

  defp dispatch_transport(%__MODULE__{} = state, %{endpoint: @status_endpoint, method: "GET"}) do
    {:ok,
     %{
       configured: state.configured,
       project: state.project,
       location: state.location,
       model: state.model,
       availableModels: @supported_models
     }}
  end

  defp dispatch_transport(%__MODULE__{configured: false}, %{endpoint: @chat_endpoint}) do
    {:error, "Vertex AI credentials or project are not configured on the backend"}
  end

  defp dispatch_transport(%__MODULE__{} = state, %{endpoint: @chat_endpoint, body: body}) do
    turns = length(body.messages)
    last_prompt = body.messages |> List.last() |> Map.get(:content, "")
    prompt_tokens = Enum.reduce(body.messages, 0, fn m, acc -> acc + byte_size(m.content) end)
    reply = "[#{body.model}@#{state.location} turn=#{turns}] #{last_prompt}"
    completion_tokens = byte_size(reply)

    {:ok,
     %{
       text: reply,
       model: body.model,
       project: state.project,
       location: state.location,
       usage: %{
         promptTokens: prompt_tokens,
         completionTokens: completion_tokens,
         totalTokens: prompt_tokens + completion_tokens
       }
     }}
  end

  defp record_request(%__MODULE__{requests: requests} = state, request) do
    %{state | requests: requests ++ [request]}
  end

  defp last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%{role: "user"}, idx} -> idx
      _ -> nil
    end)
  end

  defp synthetic_timestamp(seq) do
    "2026-11-19T00:00:#{seq |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}Z"
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_error(reason), do: inspect(reason)

  defp valid_message?(%{id: id, role: role, content: content})
       when is_binary(id) and role in ["user", "assistant", "system"] and
              is_binary(content) and byte_size(content) > 0,
       do: true

  defp valid_message?(_), do: false

  defp valid_request?(%{endpoint: @status_endpoint, method: "GET", body: nil}), do: true

  defp valid_request?(%{
         endpoint: @chat_endpoint,
         method: "POST",
         body: %{messages: [_ | _], model: model}
       }),
       do: supported_model?(model)

  defp valid_request?(_), do: false

  defp check(errors, true, _msg), do: errors
  defp check(errors, false, msg), do: [msg | errors]
end

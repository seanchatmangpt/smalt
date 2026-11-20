defmodule Smalt.ServengineSim.AiElements.VertexClientSim do
  @moduledoc """
  Vertex AI `locations/global` host and model allowlist validator/simulator
  aligned with `/Users/sac/srve` AI Elements (IDE, Workflow, Chatbot).

  Enforces two critical Vertex AI invariants:

    1. **Global endpoint host**: `locations/global` MUST target
       `https://aiplatform.googleapis.com` (never `global-aiplatform.googleapis.com`
       or a regional host such as `us-central1-aiplatform.googleapis.com`).
    2. **Model allowlist**: Only `"gemini-4-neon"` is permitted.
  """

  @global_host "aiplatform.googleapis.com"
  @global_location "global"
  @allowed_models ["gemini-4-neon"]
  @allowed_actions ["generateContent", "streamGenerateContent"]
  @default_model "gemini-4-neon"
  @default_action "generateContent"

  @path_regex ~r|^/v1/projects/([^/]+)/locations/([^/]+)/publishers/google/models/([^/:]+):([^/]+)$|

  @type validation_error ::
          {:invalid_project, term()}
          | {:unsupported_location, term()}
          | {:invalid_host, term()}
          | {:disallowed_model, term()}
          | {:unsupported_action, term()}
          | {:invalid_scheme, term()}
          | {:invalid_path, term()}
          | {:invalid_url, term()}

  @doc "Returns the canonical Vertex AI host for `locations/global`."
  @spec global_host() :: String.t()
  def global_host, do: @global_host

  @doc "Returns the required Vertex AI location (`\"global\"`)."
  @spec default_location() :: String.t()
  def default_location, do: @global_location

  @doc "Returns the allowlisted Vertex AI model IDs."
  @spec allowed_models() :: [String.t()]
  def allowed_models, do: @allowed_models

  @doc "Returns the default allowlisted Vertex AI model ID."
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc "Returns the supported Vertex AI model RPC actions."
  @spec allowed_actions() :: [String.t()]
  def allowed_actions, do: @allowed_actions

  @doc """
  Resolves the canonical Vertex AI host for `location`.

  Only `"global"` is admitted, mapping strictly to `"aiplatform.googleapis.com"`.
  """
  @spec host_for_location(term()) :: {:ok, String.t()} | {:error, {:unsupported_location, term()}}
  def host_for_location(@global_location), do: {:ok, @global_host}
  def host_for_location(other), do: {:error, {:unsupported_location, other}}

  @doc "Validates that `location` is `\"global\"`."
  @spec validate_location(term()) :: :ok | {:error, {:unsupported_location, term()}}
  def validate_location(@global_location), do: :ok
  def validate_location(other), do: {:error, {:unsupported_location, other}}

  @doc "Validates that `host` matches `aiplatform.googleapis.com` for `locations/global`."
  @spec validate_host(term()) :: :ok | {:error, {:invalid_host, term()}}
  def validate_host(@global_host), do: :ok
  def validate_host(other), do: {:error, {:invalid_host, other}}

  @doc "Validates that `model` is in the Vertex AI model allowlist."
  @spec validate_model(term()) :: :ok | {:error, {:disallowed_model, term()}}
  def validate_model(model) when model in @allowed_models, do: :ok
  def validate_model(other), do: {:error, {:disallowed_model, other}}

  @doc "Validates that `action` is a supported Vertex AI generation action."
  @spec validate_action(term()) :: :ok | {:error, {:unsupported_action, term()}}
  def validate_action(action) when action in @allowed_actions, do: :ok
  def validate_action(other), do: {:error, {:unsupported_action, other}}

  @doc "Validates that `project` is a non-empty GCP project identifier."
  @spec validate_project(term()) :: :ok | {:error, {:invalid_project, term()}}
  def validate_project(project) when is_binary(project) do
    trimmed = String.trim(project)

    if trimmed != "" and trimmed == project and not String.contains?(project, ["/", " ", "\t", "\n"]) do
      :ok
    else
      {:error, {:invalid_project, project}}
    end
  end

  def validate_project(other), do: {:error, {:invalid_project, other}}

  @doc """
  Builds a validated Vertex AI `locations/global` endpoint URL.
  """
  @spec build_endpoint(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, validation_error()}
  def build_endpoint(
        project,
        location \\ @global_location,
        model \\ @default_model,
        action \\ @default_action
      ) do
    with :ok <- validate_project(project),
         {:ok, host} <- host_for_location(location),
         :ok <- validate_model(model),
         :ok <- validate_action(action) do
      {:ok,
       "https://#{host}/v1/projects/#{project}/locations/#{location}/publishers/google/models/#{model}:#{action}"}
    end
  end

  @doc """
  Parses and validates a full Vertex AI endpoint URL against the `locations/global`
  host (`aiplatform.googleapis.com`) and model allowlist.
  """
  @spec validate_endpoint_url(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_endpoint_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri.scheme),
         :ok <- validate_host(uri.host),
         {:ok, %{project: project, location: location, model: model, action: action}} <-
           parse_endpoint_path(uri.path),
         :ok <- validate_project(project),
         :ok <- validate_location(location),
         :ok <- validate_model(model),
         :ok <- validate_action(action) do
      {:ok,
       %{
         host: uri.host,
         project: project,
         location: location,
         model: model,
         action: action,
         endpoint: url
       }}
    end
  end

  def validate_endpoint_url(other), do: {:error, {:invalid_url, other}}

  @doc """
  Validates a simulated Vertex AI client request map.

  Accepts atom or string keys for `:project`, `:location` (defaults to `"global"`),
  `:model` (defaults to `"gemini-4-neon"`), `:action` (defaults to
  `"generateContent"`), and optional `:endpoint` (validated if provided).
  """
  @spec validate_request(map()) :: {:ok, map()} | {:error, validation_error()}
  def validate_request(req) when is_map(req) do
    case fetch_field(req, :endpoint) do
      endpoint when is_binary(endpoint) ->
        validate_endpoint_url(endpoint)

      nil ->
        project = fetch_field(req, :project)
        location = fetch_field(req, :location, @global_location)
        model = fetch_field(req, :model, @default_model)
        action = fetch_field(req, :action, @default_action)

        with {:ok, endpoint} <- build_endpoint(project, location, model, action) do
          {:ok,
           %{
             host: @global_host,
             project: project,
             location: location,
             model: model,
             action: action,
             endpoint: endpoint
           }}
        end

      other ->
        {:error, {:invalid_url, other}}
    end
  end

  @doc """
  Builds a simulated `VertexStatusResponse` map matching `/Users/sac/srve`'s
  `vertexClient.ts` contract.
  """
  @spec status_response(keyword()) :: map()
  def status_response(opts \\ []) do
    project = Keyword.get(opts, :project)
    location = Keyword.get(opts, :location, @global_location)
    model = Keyword.get(opts, :model, @default_model)

    configured =
      match?(:ok, validate_project(project)) and
        match?(:ok, validate_location(location)) and
        match?(:ok, validate_model(model))

    %{
      configured: configured,
      project: if(is_binary(project) and String.trim(project) != "", do: project, else: nil),
      location: location,
      model: model,
      host: if(location == @global_location, do: @global_host, else: nil),
      available_models: @allowed_models
    }
  end

  defp validate_scheme("https"), do: :ok
  defp validate_scheme(other), do: {:error, {:invalid_scheme, other}}

  defp parse_endpoint_path(path) when is_binary(path) do
    case Regex.run(@path_regex, path) do
      [_full, project, location, model, action] ->
        {:ok, %{project: project, location: location, model: model, action: action}}

      _ ->
        {:error, {:invalid_path, path}}
    end
  end

  defp parse_endpoint_path(other), do: {:error, {:invalid_path, other}}

  defp fetch_field(map, key, default \\ nil) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end
end

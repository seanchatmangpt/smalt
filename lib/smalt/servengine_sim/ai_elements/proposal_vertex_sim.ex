defmodule Smalt.ServengineSim.AiElements.ProposalVertexSim do
  @moduledoc """
  Contract simulator and validator for ServEngine's
  `Xaas.ServEngine.Operations.ProposalGenerator.VertexAdapter` and the
  `POST /api/ai/proposal-refine` (`XaasWeb.GcpAiController.proposal_refine/2`)
  HTTP endpoint.

  Enforces:
    * Zero `StubAdapter` usage in runtime configuration, adapter bindings, or
      generated proposal outputs.
    * Strict Vertex AI configuration aligned with `/Users/sac/srve`:
        * `location`: `"global"`
        * `model`: `"gemini-4-neon"`
        * non-empty `project`
    * Fail-closed semantics on missing configuration or upstream Vertex AI
      errors (never returning fake success).
    * Canonical `/api/ai/proposal-refine` request/response and error mapping
      (`200`, `429`, `502`, `503`).
  """

  @behaviour Plug

  import Plug.Conn

  @vertex_adapter "Xaas.ServEngine.Operations.ProposalGenerator.VertexAdapter"
  @stub_adapter "Xaas.ServEngine.Operations.ProposalGenerator.StubAdapter"
  @proposal_refine_path "/api/ai/proposal-refine"
  @default_location "global"
  @default_model "gemini-4-neon"
  @allowed_locations ["global"]
  @allowed_models ["gemini-4-neon"]
  @default_instruction "Refine for clarity and professionalism."
  @default_system_instruction "You are ServEngine Proposal AI. Return an improved, itemized facilities maintenance proposal."
  @generator_system_instruction "You are a facilities management estimator producing clear, itemized service proposals."

  @canonical_error_codes %{
    429 => "vertex_ai_rate_limited",
    502 => "vertex_ai_http_error",
    503 => ["vertex_ai_not_configured", "no_gcp_access_token", "vertex_ai_unavailable"]
  }

  @type vertex_config :: %{
          required(:project) => String.t(),
          required(:location) => String.t(),
          required(:model) => String.t()
        }

  @doc "Canonical VertexAdapter module name."
  @spec vertex_adapter() :: String.t()
  def vertex_adapter, do: @vertex_adapter

  @doc "Forbidden StubAdapter module name."
  @spec stub_adapter() :: String.t()
  def stub_adapter, do: @stub_adapter

  @doc "Allowed Vertex AI locations."
  @spec allowed_locations() :: [String.t()]
  def allowed_locations, do: @allowed_locations

  @doc "Allowed Vertex AI Gemini model IDs."
  @spec allowed_models() :: [String.t()]
  def allowed_models, do: @allowed_models

  @doc "Canonical proposal-refine HTTP endpoint path."
  @spec proposal_refine_path() :: String.t()
  def proposal_refine_path, do: @proposal_refine_path

  # ---------------------------------------------------------------------------
  # Adapter & Vertex AI config validation (zero StubAdapter)
  # ---------------------------------------------------------------------------

  @doc """
  Validates that an adapter binding is `ProposalGenerator.VertexAdapter` and
  explicitly refuses any `StubAdapter`.
  """
  @spec validate_adapter_binding(module() | String.t() | nil) :: :ok | {:error, term()}
  def validate_adapter_binding(nil), do: {:error, :no_generator_config}

  def validate_adapter_binding(adapter) do
    normalized = normalize_module_name(adapter)

    cond do
      normalized == "" ->
        {:error, :no_generator_config}

      stub_adapter_name?(normalized) ->
        {:error, {:stub_adapter_forbidden, normalized}}

      normalized == @vertex_adapter ->
        :ok

      true ->
        {:error, {:unexpected_adapter, normalized}}
    end
  end

  @doc """
  Validates a Vertex AI config map (`project`, `location`, `model`).
  """
  @spec validate_vertex_config(map() | keyword() | nil) :: :ok | {:error, term()}
  def validate_vertex_config(nil), do: {:error, :vertex_ai_not_configured}

  def validate_vertex_config(config) when is_list(config) do
    config |> Map.new() |> validate_vertex_config()
  end

  def validate_vertex_config(config) when is_map(config) do
    project = fetch_field(config, :project)
    location = fetch_field(config, :location)
    model = fetch_field(config, :model)

    cond do
      not non_empty_string?(project) ->
        {:error, :missing_vertex_project}

      location not in @allowed_locations ->
        {:error, {:invalid_vertex_location, location}}

      model not in @allowed_models ->
        {:error, {:invalid_vertex_model, model}}

      true ->
        :ok
    end
  end

  def validate_vertex_config(_), do: {:error, :vertex_ai_not_configured}

  @doc """
  Audits a runtime configuration map/keyword list to ensure
  `proposal_generator_adapter` is `VertexAdapter` (zero `StubAdapter`) and
  `vertex_ai` config is valid.
  """
  @spec audit_runtime_config(map() | keyword()) :: :ok | {:error, [term()]}
  def audit_runtime_config(config) when is_list(config) do
    config |> Map.new() |> audit_runtime_config()
  end

  def audit_runtime_config(config) when is_map(config) do
    adapter = fetch_field(config, :proposal_generator_adapter)
    vertex_cfg = fetch_field(config, :vertex_ai)

    errors =
      []
      |> collect_error(validate_adapter_binding(adapter))
      |> collect_error(validate_vertex_config(vertex_cfg))

    case errors do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  # ---------------------------------------------------------------------------
  # ProposalGenerator.VertexAdapter.generate/2 simulation & validation
  # ---------------------------------------------------------------------------

  @doc """
  Simulates `Xaas.ServEngine.Operations.ProposalGenerator.VertexAdapter.generate/2`.

  Options:
    * `:adapter` - defaults to `#{@vertex_adapter}`; any `StubAdapter` is refused.
    * `:project` - GCP project ID (required unless `:configured?` is false).
    * `:location` - defaults to `"global"`.
    * `:model` - defaults to `"gemini-4-neon"`.
    * `:proposal_id` - propagated into the generated body map.
    * `:vertex_fn` - optional `(prompt, opts) -> {:ok, text} | {:error, reason}`
      callback to simulate Vertex AI responses or failures.
  """
  @spec simulate_generate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def simulate_generate(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    adapter = Keyword.get(opts, :adapter, @vertex_adapter)

    with :ok <- validate_adapter_binding(adapter),
         {:ok, vertex_cfg} <- extract_vertex_config(opts) do
      prompt = """
      Generate a concise, professional commercial facilities maintenance proposal based on this work order payload:
      #{Jason.encode!(payload)}
      """

      vertex_fn = Keyword.get(opts, :vertex_fn, &default_vertex_generate/2)

      case vertex_fn.(prompt,
             system_instruction: @generator_system_instruction,
             model: vertex_cfg.model,
             location: vertex_cfg.location,
             project: vertex_cfg.project
           ) do
        {:ok, text} when is_binary(text) and byte_size(text) > 0 ->
          {:ok,
           %{
             body: text,
             config: vertex_cfg,
             adapter: normalize_module_name(adapter),
             proposal_id: Keyword.get(opts, :proposal_id),
             generated_at: DateTime.to_iso8601(DateTime.utc_now())
           }}

        {:ok, _empty} ->
          {:error, :empty_vertex_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Validates the output map returned by `ProposalGenerator.VertexAdapter.generate/2`.
  """
  @spec validate_generated_body(map()) :: :ok | {:error, [term()]}
  def validate_generated_body(result) when is_map(result) do
    body = fetch_field(result, :body)
    config = fetch_field(result, :config)
    adapter = fetch_field(result, :adapter)
    generated_at = fetch_field(result, :generated_at)

    errors =
      []
      |> collect_check(non_empty_string?(body), :missing_or_empty_body)
      |> collect_error(validate_vertex_config(config))
      |> collect_error(validate_adapter_binding(adapter))
      |> collect_error(validate_iso8601(generated_at))

    case errors do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  def validate_generated_body(_), do: {:error, [:invalid_generated_body]}

  # ---------------------------------------------------------------------------
  # POST /api/ai/proposal-refine Plug simulator & response validator
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) when is_list(opts), do: opts

  @impl true
  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(%Plug.Conn{request_path: @proposal_refine_path, method: "POST"} = conn, opts) do
    opts = if is_list(opts), do: opts, else: []
    adapter = Keyword.get(opts, :adapter, @vertex_adapter)

    case validate_adapter_binding(adapter) do
      {:error, reason} ->
        send_json(conn, 503, %{
          error: "Proposal generator adapter misconfigured: #{inspect(reason)}",
          code: "stub_adapter_forbidden"
        })

      :ok ->
        handle_proposal_refine(conn, opts)
    end
  end

  def call(%Plug.Conn{request_path: @proposal_refine_path} = conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_json(405, %{error: "method not allowed", code: "method_not_allowed"})
  end

  def call(%Plug.Conn{} = conn, _opts) do
    send_json(conn, 404, %{error: "not found", code: "not_found"})
  end

  @doc """
  Validates an HTTP `{status, decoded_body}` response from `POST /api/ai/proposal-refine`.
  """
  @spec validate_refine_response(integer(), map()) :: :ok | {:error, [term()]}
  def validate_refine_response(200, %{"data" => data}) when is_map(data) do
    text = data["text"]
    model = data["model"]
    project = data["project"]
    location = data["location"]

    errors =
      []
      |> collect_check(non_empty_string?(text), :missing_or_empty_text)
      |> collect_error(
        validate_vertex_config(%{project: project, location: location, model: model})
      )
      |> collect_check(
        not stub_text_marker?(text),
        :stub_output_detected
      )

    case errors do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  def validate_refine_response(200, _body), do: {:error, [:missing_data_envelope]}

  def validate_refine_response(status, %{"error" => msg, "code" => code})
      when status in [429, 502, 503] do
    allowed_codes =
      case Map.get(@canonical_error_codes, status) do
        list when is_list(list) -> list
        single -> [single]
      end

    errors =
      []
      |> collect_check(non_empty_string?(msg), :missing_error_message)
      |> collect_check(code in allowed_codes, {:unexpected_error_code, status, code})

    case errors do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  def validate_refine_response(status, body) do
    {:error, [{:unexpected_response, status, body}]}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp handle_proposal_refine(conn, opts) do
    with {:ok, params, conn} <- read_json_params(conn) do
      draft = param_str(params["draft"]) || param_str(params["body"]) || ""

      instruction =
        param_str(params["instruction"]) || param_str(params["prompt"]) || @default_instruction

      requested_model = param_str(params["model"])

      case resolve_refine_vertex_config(opts, requested_model) do
        {:error, :vertex_ai_not_configured} ->
          respond_vertex(conn, {:error, :vertex_ai_not_configured}, nil)

        {:error, {:invalid_vertex_model, bad_model}} ->
          send_json(conn, 400, %{
            error: "Unsupported Vertex AI model: #{inspect(bad_model)}",
            code: "invalid_vertex_model"
          })

        {:error, {:invalid_vertex_location, bad_loc}} ->
          send_json(conn, 503, %{
            error: "Unsupported Vertex AI location: #{inspect(bad_loc)}",
            code: "invalid_vertex_location"
          })

        {:ok, vertex_cfg} ->
          prompt = """
          Refine the following service proposal according to the instruction.
          Instruction: #{instruction}
          Current Proposal:
          #{draft}
          """

          vertex_fn = Keyword.get(opts, :vertex_fn, &default_vertex_generate/2)

          result =
            vertex_fn.(prompt,
              system_instruction: @default_system_instruction,
              model: vertex_cfg.model,
              location: vertex_cfg.location,
              project: vertex_cfg.project
            )

          respond_vertex(conn, result, vertex_cfg)
      end
    else
      {:error, :invalid_json, conn} ->
        send_json(conn, 400, %{error: "invalid JSON payload", code: "invalid_json"})
    end
  end

  defp resolve_refine_vertex_config(opts, requested_model) do
    if Keyword.get(opts, :configured?, true) == false do
      {:error, :vertex_ai_not_configured}
    else
      project = Keyword.get(opts, :project)
      location = Keyword.get(opts, :location, @default_location)
      model = requested_model || Keyword.get(opts, :model, @default_model)

      cond do
        not non_empty_string?(project) ->
          {:error, :vertex_ai_not_configured}

        location not in @allowed_locations ->
          {:error, {:invalid_vertex_location, location}}

        model not in @allowed_models ->
          {:error, {:invalid_vertex_model, model}}

        true ->
          {:ok, %{project: project, location: location, model: model}}
      end
    end
  end

  defp extract_vertex_config(opts) do
    if Keyword.get(opts, :configured?, true) == false do
      {:error, :vertex_ai_not_configured}
    else
      cfg = %{
        project: Keyword.get(opts, :project),
        location: Keyword.get(opts, :location, @default_location),
        model: Keyword.get(opts, :model, @default_model)
      }

      case validate_vertex_config(cfg) do
        :ok -> {:ok, cfg}
        {:error, :missing_vertex_project} -> {:error, :vertex_ai_not_configured}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp respond_vertex(conn, {:ok, text}, vertex_cfg) do
    send_json(conn, 200, %{
      data: %{
        text: text,
        model: vertex_cfg.model,
        project: vertex_cfg.project,
        location: vertex_cfg.location
      }
    })
  end

  defp respond_vertex(conn, {:error, reason}, _vertex_cfg) do
    {status, code, msg} =
      case reason do
        :vertex_ai_not_configured ->
          {503, "vertex_ai_not_configured", "Vertex AI is not configured"}

        :no_gcp_access_token ->
          {503, "no_gcp_access_token", "Unable to acquire GCP access token"}

        {:vertex_ai_http_error, 429, _} ->
          {429, "vertex_ai_rate_limited", "Vertex AI rate limit exceeded"}

        {:vertex_ai_http_error, _code, _} ->
          {502, "vertex_ai_http_error", "Vertex AI upstream error"}

        _ ->
          {503, "vertex_ai_unavailable", "Vertex AI service unavailable"}
      end

    send_json(conn, status, %{error: msg, code: code})
  end

  defp default_vertex_generate(prompt, opts) do
    model = Keyword.get(opts, :model, @default_model)
    trimmed = prompt |> String.trim() |> String.slice(0, 120)
    {:ok, "[vertex:#{model}] Itemized commercial facilities maintenance proposal: #{trimmed}"}
  end

  defp read_json_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn) do
      {:ok, "", conn} ->
        {:ok, %{}, conn}

      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, map, conn}
          _ -> {:error, :invalid_json, conn}
        end

      {:more, _partial, conn} ->
        {:error, :invalid_json, conn}

      {:error, _reason} ->
        {:error, :invalid_json, conn}
    end
  end

  defp read_json_params(%Plug.Conn{body_params: params} = conn) when is_map(params) do
    {:ok, params, conn}
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
    |> halt()
  end

  defp normalize_module_name(mod) when is_atom(mod) do
    mod |> Atom.to_string() |> String.trim_leading("Elixir.")
  end

  defp normalize_module_name(mod) when is_binary(mod) do
    mod |> String.trim() |> String.trim_leading("Elixir.")
  end

  defp normalize_module_name(_), do: ""

  defp stub_adapter_name?(name) do
    name == @stub_adapter or String.ends_with?(name, ".StubAdapter") or name == "StubAdapter"
  end

  defp stub_text_marker?(text) when is_binary(text) do
    String.contains?(text, "StubAdapter") or String.contains?(text, "[stub]")
  end

  defp stub_text_marker?(_), do: false

  defp fetch_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp param_str(val) when is_binary(val), do: val
  defp param_str(_), do: nil

  defp non_empty_string?(val), do: is_binary(val) and String.trim(val) != ""

  defp validate_iso8601(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, _dt, _offset} -> :ok
      {:error, _} -> {:error, :invalid_generated_at}
    end
  end

  defp validate_iso8601(_), do: {:error, :missing_generated_at}

  defp collect_error(errors, :ok), do: errors
  defp collect_error(errors, {:error, reason}), do: [reason | errors]

  defp collect_check(errors, true, _reason), do: errors
  defp collect_check(errors, false, reason), do: [reason | errors]
end

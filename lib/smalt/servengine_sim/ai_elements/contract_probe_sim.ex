defmodule Smalt.ServengineSim.AiElements.ContractProbeSim do
  @moduledoc """
  Live FE<->BE contract parity probe for ServEngine AI Elements (Chatbot,
  Workflow, IDE) backed by GCP Vertex AI (`global` / `gemini-4-neon` /
  `gemini-4-neon`).

  Parses and cross-checks three authoritative source files from `/Users/sac/srve`:

    1. `servengine-frontend/src/api/ai-elements/vertexClient.ts`
    2. `xaas/lib/xaas_web/controllers/ai_elements_controller.ex`
    3. `xaas/lib/xaas_web/router.ex`

  Verifies 100% parity across:
    * HTTP method + path routing (`GET /api/ai/status`, `POST /api/ai/chat`,
      `POST /api/ai/workflow-step`, `POST /api/ai/ide-assist`)
    * Router pipeline ordering (`:cors` -> `:require_internal_api_token` -> `:api`),
      `OPTIONS /*path` preflight coverage, and mounting before any `forward("/api", ...)`
    * Vertex AI allowed model IDs (`gemini-4-neon`)
    * Response envelope unwrapping (`%{data: ...}`) and error envelope (`%{error: ..., code: ...}`)
    * Required FE response fields vs BE controller `data: %{...}` payload keys
    * Required/core FE request fields vs BE controller accepted `params[...]` keys
  """

  @default_vertex_client_path "/Users/sac/srve/servengine-frontend/src/api/ai-elements/vertexClient.ts"
  @default_controller_path "/Users/sac/srve/xaas/lib/xaas_web/controllers/ai_elements_controller.ex"
  @default_router_path "/Users/sac/srve/xaas/lib/xaas_web/router.ex"

  @expected_models ["gemini-4-neon"]

  @type route_spec :: %{method: String.t(), path: String.t()}

  @type parity_report :: %{
          status: :ok | :mismatch,
          fe_routes: [route_spec()],
          be_routes: [route_spec()],
          fe_models: [String.t()],
          be_models: [String.t()],
          be_default_model: String.t() | nil,
          router_checks: map(),
          envelope_checks: map(),
          payload_checks: map(),
          mismatches: [String.t()]
        }

  @doc """
  Returns the default `/Users/sac/srve` file paths probed by this simulator.
  """
  @spec default_paths() :: %{
          vertex_client: String.t(),
          controller: String.t(),
          router: String.t()
        }
  def default_paths do
    %{
      vertex_client: @default_vertex_client_path,
      controller: @default_controller_path,
      router: @default_router_path
    }
  end

  @doc """
  Reads the live `/Users/sac/srve` files (or custom `:vertex_client`,
  `:controller`, `:router` paths via `opts`) and verifies 100% FE<->BE parity.
  """
  @spec probe_files(keyword()) :: {:ok, parity_report()} | {:error, term()}
  def probe_files(opts \\ []) do
    paths = default_paths()
    vc_path = Keyword.get(opts, :vertex_client, paths.vertex_client)
    ctrl_path = Keyword.get(opts, :controller, paths.controller)
    router_path = Keyword.get(opts, :router, paths.router)

    with {:ok, vc_src} <- File.read(vc_path),
         {:ok, ctrl_src} <- File.read(ctrl_path),
         {:ok, router_src} <- File.read(router_path) do
      verify_parity(vc_src, ctrl_src, router_src)
    end
  end

  @doc """
  Verifies 100% FE<->BE route, model, envelope, and payload parity from raw
  source strings for `vertexClient.ts`, `ai_elements_controller.ex`, and `router.ex`.
  """
  @spec verify_parity(String.t(), String.t(), String.t()) ::
          {:ok, parity_report()} | {:error, parity_report()}
  def verify_parity(vertex_client_src, controller_src, router_src)
      when is_binary(vertex_client_src) and is_binary(controller_src) and is_binary(router_src) do
    fe_routes = extract_fe_routes(vertex_client_src)
    be_routes = extract_be_ai_routes(router_src)
    fe_models = extract_fe_models(vertex_client_src)
    be_models = extract_be_allowed_models(controller_src)
    be_default_model = extract_be_default_model(controller_src)

    router_checks = check_router_guards(router_src)
    envelope_checks = check_envelopes(vertex_client_src, controller_src)
    payload_checks = check_payload_parity(vertex_client_src, controller_src)

    mismatches =
      []
      |> check_route_parity(fe_routes, be_routes)
      |> check_model_parity(fe_models, be_models, be_default_model)
      |> collect_map_failures("router", router_checks)
      |> collect_map_failures("envelope", envelope_checks)
      |> collect_payload_failures(payload_checks)

    report = %{
      status: if(mismatches == [], do: :ok, else: :mismatch),
      fe_routes: fe_routes,
      be_routes: be_routes,
      fe_models: fe_models,
      be_models: be_models,
      be_default_model: be_default_model,
      router_checks: router_checks,
      envelope_checks: envelope_checks,
      payload_checks: payload_checks,
      mismatches: Enum.reverse(mismatches)
    }

    if report.status == :ok, do: {:ok, report}, else: {:error, report}
  end

  @doc """
  Extracts `{method, path}` route specs invoked by `requestVertex` in `vertexClient.ts`.
  """
  @spec extract_fe_routes(String.t()) :: [route_spec()]
  def extract_fe_routes(vertex_client_src) when is_binary(vertex_client_src) do
    regex = ~r/requestVertex<[^>]+>\(\s*"([^"]+)"\s*,\s*\{\s*method:\s*"(GET|POST|PUT|PATCH|DELETE)"/s

    Regex.scan(regex, vertex_client_src)
    |> Enum.map(fn [_, path, method] -> %{method: method, path: path} end)
    |> Enum.uniq()
  end

  @doc """
  Extracts `/api/ai/*` routes from `scope "/api", XaasWeb do` in `router.ex`.
  """
  @spec extract_be_ai_routes(String.t()) :: [route_spec()]
  def extract_be_ai_routes(router_src) when is_binary(router_src) do
    case extract_api_ai_scope_block(router_src) do
      nil ->
        []

      block ->
        ~r/\b(get|post|put|patch|delete)\(\s*"(\/ai\/[^"]+)"\s*,/
        |> Regex.scan(block)
        |> Enum.map(fn [_, method, sub_path] ->
          %{method: String.upcase(method), path: "/api" <> sub_path}
        end)
        |> Enum.uniq()
    end
  end

  @doc """
  Extracts literal Vertex model IDs from `export type VertexModelId` in `vertexClient.ts`.
  """
  @spec extract_fe_models(String.t()) :: [String.t()]
  def extract_fe_models(vertex_client_src) when is_binary(vertex_client_src) do
    case Regex.run(~r/export type VertexModelId\s*=\s*([^;]+);/s, vertex_client_src) do
      [_, body] ->
        ~r/"(gemini-[^"]+)"/
        |> Regex.scan(body)
        |> Enum.map(fn [_, model] -> model end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  Extracts `@allowed_models` from `ai_elements_controller.ex`.
  """
  @spec extract_be_allowed_models(String.t()) :: [String.t()]
  def extract_be_allowed_models(controller_src) when is_binary(controller_src) do
    case Regex.run(~r/@allowed_models\s*\[([^\]]+)\]/s, controller_src) do
      [_, body] ->
        ~r/"([^"]+)"/
        |> Regex.scan(body)
        |> Enum.map(fn [_, model] -> model end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  Extracts `@default_model` from `ai_elements_controller.ex`.
  """
  @spec extract_be_default_model(String.t()) :: String.t() | nil
  def extract_be_default_model(controller_src) when is_binary(controller_src) do
    case Regex.run(~r/@default_model\s+"([^"]+)"/, controller_src) do
      [_, model] -> model
      _ -> nil
    end
  end

  @doc """
  Extracts required and optional field names from a TypeScript `export interface Name { ... }`.
  """
  @spec extract_ts_interface_fields(String.t(), String.t()) :: %{
          required: [String.t()],
          optional: [String.t()]
        }
  def extract_ts_interface_fields(ts_src, interface_name)
      when is_binary(ts_src) and is_binary(interface_name) do
    pattern = ~r/export interface #{Regex.escape(interface_name)}\s*\{(.*?)\n\}/s

    case Regex.run(pattern, ts_src) do
      [_, body] ->
        lines = String.split(body, "\n")

        Enum.reduce(lines, %{required: [], optional: []}, fn line, acc ->
          case Regex.run(~r/^\s{2}([a-zA-Z_][a-zA-Z0-9_]*)(\?)?\s*:/, line) do
            [_, field, "?"] ->
              %{acc | optional: acc.optional ++ [field]}

            [_, field] ->
              %{acc | required: acc.required ++ [field]}

            _ ->
              acc
          end
        end)

      _ ->
        %{required: [], optional: []}
    end
  end

  @doc """
  Extracts the `data: %{...}` response keys for a given action (`"chat"`,
  `"workflow_step"`, or `"ide_assist"`) in `ai_elements_controller.ex`.
  """
  @spec extract_controller_response_keys(String.t(), String.t()) :: [String.t()]
  def extract_controller_response_keys(controller_src, action_name)
      when is_binary(controller_src) and is_binary(action_name) do
    action_block = extract_def_block(controller_src, action_name)

    case action_block && Regex.run(~r/data:\s*%\{([^}]+)\}/s, action_block) do
      [_, body] ->
        ~r/([a-z_][a-z0-9_]*)\s*:/
        |> Regex.scan(body)
        |> Enum.map(fn [_, key] -> key end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  Extracts all `params["..."]` keys referenced in `ai_elements_controller.ex`.
  """
  @spec extract_controller_param_keys(String.t()) :: [String.t()]
  def extract_controller_param_keys(controller_src) when is_binary(controller_src) do
    ~r/params\["([^"]+)"\]/
    |> Regex.scan(controller_src)
    |> Enum.map(fn [_, key] -> key end)
    |> Enum.uniq()
  end

  # -- Internal Checks --

  defp check_route_parity(mismatches, fe_routes, be_routes) do
    missing =
      Enum.reject(fe_routes, fn fe_route ->
        Enum.any?(be_routes, fn be_route ->
          be_route.method == fe_route.method and be_route.path == fe_route.path
        end)
      end)

    mismatches =
      if fe_routes == [] do
        ["no FE routes extracted from vertexClient.ts" | mismatches]
      else
        mismatches
      end

    Enum.reduce(missing, mismatches, fn route, acc ->
      ["FE route #{route.method} #{route.path} missing from router.ex" | acc]
    end)
  end

  defp check_model_parity(mismatches, fe_models, be_models, be_default_model) do
    mismatches =
      if MapSet.new(fe_models) != MapSet.new(be_models) do
        [
          "model mismatch: FE=#{inspect(fe_models)} vs BE=#{inspect(be_models)}"
          | mismatches
        ]
      else
        mismatches
      end

    mismatches =
      if not Enum.all?(@expected_models, &(&1 in be_models)) do
        [
          "missing expected Vertex AI models #{inspect(@expected_models)} in BE=#{inspect(be_models)}"
          | mismatches
        ]
      else
        mismatches
      end

    if be_default_model in be_models do
      mismatches
    else
      [
        "BE @default_model #{inspect(be_default_model)} is not in @allowed_models #{inspect(be_models)}"
        | mismatches
      ]
    end
  end

  defp check_router_guards(router_src) do
    block = extract_api_ai_scope_block(router_src) || ""

    pipeline_order_ok? =
      Regex.match?(
        ~r/pipe_through\(\[:cors,\s*:require_internal_api_token,\s*:api\]\)/,
        block
      )

    options_preflight_ok? =
      Regex.match?(~r/options\("\/\*path",\s*LegacyBridgeController,\s*:options_preflight\)/, block)

    mounted_before_forward? =
      case {:binary.match(router_src, ~s(post("/ai/chat")),
            :binary.match(router_src, ~s(forward("/api",))} do
        {{ai_pos, _}, {fwd_pos, _}} -> ai_pos < fwd_pos
        {{_, _}, :nomatch} -> true
        _ -> false
      end

    %{
      pipeline_order_ok?: pipeline_order_ok?,
      options_preflight_ok?: options_preflight_ok?,
      mounted_before_forward?: mounted_before_forward?
    }
  end

  defp check_envelopes(vertex_client_src, controller_src) do
    %{
      fe_unwraps_data_envelope?: String.contains?(vertex_client_src, ~s("data" in payload)),
      fe_sends_bearer_auth?: String.contains?(vertex_client_src, "Bearer "),
      fe_sends_json_headers?:
        String.contains?(vertex_client_src, ~s(Accept: "application/json")) and
          String.contains?(vertex_client_src, ~s(headers["Content-Type"] = "application/json")),
      fe_parses_error_field?: String.contains?(vertex_client_src, ~s("error" in parsed)),
      be_wraps_data_envelope?: String.contains?(controller_src, "data: %{"),
      be_returns_typed_error_envelope?:
        String.contains?(controller_src, "error:") and String.contains?(controller_src, "code:")
    }
  end

  defp check_payload_parity(vertex_client_src, controller_src) do
    be_params = extract_controller_param_keys(controller_src)

    endpoints = [
      {:chat, "VertexChatResponse", "chat", ["messages", "prompt", "model"]},
      {:workflow_step, "VertexWorkflowStepResponse", "workflow_step",
       ["instruction", "prompt", "input", "model"]},
      {:ide_assist, "VertexIdeAssistResponse", "ide_assist",
       ["action", "code", "instruction", "prompt", "language", "model"]}
    ]

    Map.new(endpoints, fn {key, ts_resp_iface, be_action, expected_be_params} ->
      fe_resp_fields = extract_ts_interface_fields(vertex_client_src, ts_resp_iface)
      be_resp_keys = extract_controller_response_keys(controller_src, be_action)

      missing_resp_keys =
        Enum.reject(fe_resp_fields.required, fn field -> field in be_resp_keys end)

      missing_req_params =
        Enum.reject(expected_be_params, fn param -> param in be_params end)

      {key,
       %{
         fe_required_response_fields: fe_resp_fields.required,
         be_response_keys: be_resp_keys,
         missing_response_keys: missing_resp_keys,
         missing_request_params: missing_req_params,
         ok?: missing_resp_keys == [] and missing_req_params == []
       }}
    end)
  end

  defp collect_map_failures(mismatches, prefix, checks_map) do
    Enum.reduce(checks_map, mismatches, fn {k, ok?}, acc ->
      if ok?, do: acc, else: ["#{prefix} check failed: #{k}" | acc]
    end)
  end

  defp collect_payload_failures(mismatches, payload_checks) do
    Enum.reduce(payload_checks, mismatches, fn {endpoint, result}, acc ->
      acc =
        if result.missing_response_keys == [] do
          acc
        else
          [
            "#{endpoint} response missing required FE keys: #{inspect(result.missing_response_keys)}"
            | acc
          ]
        end

      if result.missing_request_params == [] do
        acc
      else
        [
          "#{endpoint} controller missing expected request params: #{inspect(result.missing_request_params)}"
          | acc
        ]
      end
    end)
  end

  defp extract_api_ai_scope_block(router_src) do
    # Locate the `scope "/api", XaasWeb do ... end` block that contains `/ai/chat`.
    ~r/scope\s+"\/api",\s*XaasWeb\s+do(.*?)\n  end/s
    |> Regex.scan(router_src)
    |> Enum.map(fn [full, _inner] -> full end)
    |> Enum.find(&String.contains?(&1, ~s("/ai/chat")))
  end

  defp extract_def_block(src, action_name) do
    pattern = ~r/def #{Regex.escape(action_name)}\(conn,\s*params\)\s+do(.*?)\n  end/s

    case Regex.run(pattern, src) do
      [full, _] -> full
      _ -> nil
    end
  end
end

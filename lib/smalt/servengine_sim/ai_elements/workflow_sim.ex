defmodule Smalt.ServengineSim.AiElements.WorkflowSim do
  @moduledoc """
  Simulator for the `/ai/workflow` 5-node ServEngine DAG
  (`Intake -> Triage -> Dispatch -> Proposal -> QA`) with sequential Vertex AI
  step chaining.

  Aligned with `/Users/sac/srve` AI Elements (`WorkflowWorkspace.tsx` and
  `vertexClient.ts`) and Vertex AI (`location: "global"`,
  `gemini-4-neon`).

  Capabilities:
    * Defines the canonical 5-node ServEngine workflow DAG and edge topology.
    * Validates DAG invariants (unique node IDs, valid edge endpoints,
      acyclicity via Kahn's topological sort, supported Vertex AI models, and
      `global` Vertex AI location).
    * Builds `VertexWorkflowStepRequest`-compatible payloads with `{{input}}`
      prompt interpolation and accumulated `previous_outputs` chaining.
    * Executes steps sequentially through an injectable Vertex step executor
      (or a deterministic built-in simulator) and fails closed on step errors
      without executing downstream nodes.
  """

  @workflow_route "/ai/workflow"
  @vertex_step_endpoint "/api/ai/vertex/workflow/step"
  @default_location "global"
  @default_project "servengine-prod"
  @default_workflow_id "servengine-wo-dag"
  @supported_models ["gemini-4-neon"]

  @type node_status :: :idle | :running | :completed | :error | :skipped
  @type node_kind :: :intake | :analyze | :dispatch | :transform | :summarize | :custom

  @type workflow_node :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:kind) => node_kind(),
          required(:model) => String.t(),
          required(:prompt) => String.t(),
          required(:system_prompt) => String.t(),
          optional(:status) => node_status(),
          optional(:output) => String.t() | nil,
          optional(:error) => term() | nil,
          optional(:duration_ms) => non_neg_integer() | nil,
          optional(:temperature) => float()
        }

  @type dag :: %{
          required(:nodes) => [workflow_node()],
          required(:edges) => [{String.t(), String.t()}]
        }

  @type step_request :: %{
          workflow_id: String.t(),
          step_id: String.t(),
          step_name: String.t(),
          step_type: String.t(),
          instruction: String.t(),
          input: String.t(),
          previous_outputs: %{String.t() => String.t()},
          system: String.t(),
          model: String.t(),
          location: String.t(),
          project: String.t(),
          endpoint: String.t(),
          temperature: float()
        }

  @type step_response :: %{
          text: String.t(),
          output: String.t(),
          step_id: String.t(),
          status: String.t(),
          model: String.t(),
          project: String.t(),
          location: String.t(),
          latency_ms: non_neg_integer()
        }

  @type step_executor :: (step_request() -> {:ok, step_response() | map()} | {:error, term()})

  @doc "Returns the canonical AI Elements route path (`/ai/workflow`)."
  @spec workflow_route() :: String.t()
  def workflow_route, do: @workflow_route

  @doc "Returns the Vertex AI workflow step endpoint path."
  @spec vertex_step_endpoint() :: String.t()
  def vertex_step_endpoint, do: @vertex_step_endpoint

  @doc "Returns the supported Vertex AI model IDs."
  @spec supported_models() :: [String.t()]
  def supported_models, do: @supported_models

  @doc "Returns the required Vertex AI location (`\"global\"`)."
  @spec default_location() :: String.t()
  def default_location, do: @default_location

  @doc """
  Returns the canonical 5-node ServEngine DAG:
  `intake -> triage -> dispatch -> proposal -> qa`.
  """
  @spec default_dag() :: dag()
  def default_dag do
    %{
      nodes: [
        %{
          id: "intake",
          label: "Intake",
          kind: :intake,
          model: "gemini-4-neon",
          prompt:
            "Normalize incoming work order request into trade, urgency, location, and scope:\n\n{{input}}",
          system_prompt:
            "You are a ServEngine facilities intake specialist. Return concise structured bullets.",
          status: :idle,
          output: nil,
          error: nil,
          duration_ms: nil,
          temperature: 0.1
        },
        %{
          id: "triage",
          label: "Triage",
          kind: :analyze,
          model: "gemini-4-neon",
          prompt:
            "Evaluate SLA priority, required certifications, NTE threshold, and safety precautions:\n\n{{input}}",
          system_prompt:
            "You are a ServEngine SLA and safety triage analyst. Be precise and actionable.",
          status: :idle,
          output: nil,
          error: nil,
          duration_ms: nil,
          temperature: 0.1
        },
        %{
          id: "dispatch",
          label: "Dispatch",
          kind: :dispatch,
          model: "gemini-4-neon",
          prompt:
            "Select technician dispatch brief, ETA window, and on-site diagnostic checklist:\n\n{{input}}",
          system_prompt:
            "You are a senior ServEngine dispatch coordinator. Produce a ready-to-send dispatch brief.",
          status: :idle,
          output: nil,
          error: nil,
          duration_ms: nil,
          temperature: 0.2
        },
        %{
          id: "proposal",
          label: "Proposal",
          kind: :transform,
          model: "gemini-4-neon",
          prompt:
            "Draft itemized repair proposal, labor/materials estimate, and NTE compliance summary:\n\n{{input}}",
          system_prompt:
            "You are a ServEngine commercial estimating specialist. Output a structured proposal.",
          status: :idle,
          output: nil,
          error: nil,
          duration_ms: nil,
          temperature: 0.2
        },
        %{
          id: "qa",
          label: "QA",
          kind: :summarize,
          model: "gemini-4-neon",
          prompt:
            "Verify completion evidence, SLA adherence, and invoice readiness for closeout:\n\n{{input}}",
          system_prompt:
            "You are a ServEngine QA auditor. Return PASS/FAIL verdict with itemized checks.",
          status: :idle,
          output: nil,
          error: nil,
          duration_ms: nil,
          temperature: 0.0
        }
      ],
      edges: [
        {"intake", "triage"},
        {"triage", "dispatch"},
        {"dispatch", "proposal"},
        {"proposal", "qa"}
      ]
    }
  end

  @doc """
  Validates the DAG structure, model allowlist, and acyclicity.

  Returns `{:ok, ordered_node_ids}` in topological execution order, or
  `{:error, reason}`.
  """
  @spec validate_dag(dag()) :: {:ok, [String.t()]} | {:error, term()}
  def validate_dag(%{nodes: nodes, edges: edges}) when is_list(nodes) and is_list(edges) do
    with :ok <- ensure_non_empty(nodes),
         :ok <- ensure_unique_ids(nodes),
         :ok <- ensure_supported_models(nodes),
         node_ids = MapSet.new(nodes, & &1.id),
         :ok <- ensure_valid_edges(edges, node_ids) do
      topological_sort(nodes, edges)
    end
  end

  def validate_dag(_), do: {:error, :invalid_dag_shape}

  @doc """
  Validates Vertex AI configuration. Enforces `location == "global"`.
  """
  @spec validate_vertex_config(keyword()) :: :ok | {:error, term()}
  def validate_vertex_config(opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    if location == @default_location do
      :ok
    else
      {:error, {:invalid_vertex_location, location, expected: @default_location}}
    end
  end

  @doc """
  Substitutes `{{input}}` in a node prompt template with the upstream text.
  If `{{input}}` is not present, appends the input text when non-empty.
  """
  @spec render_prompt(String.t(), String.t()) :: String.t()
  def render_prompt(template, input) when is_binary(template) and is_binary(input) do
    cond do
      String.contains?(template, "{{input}}") ->
        String.replace(template, "{{input}}", input)

      String.trim(input) == "" ->
        template

      true ->
        template <> "\n\n" <> input
    end
  end

  @doc """
  Builds a `VertexWorkflowStepRequest`-aligned payload for a single DAG node.
  """
  @spec build_step_request(workflow_node(), String.t(), %{String.t() => String.t()}, keyword()) ::
          step_request()
  def build_step_request(node, step_input, previous_outputs, opts \\ []) do
    %{
      workflow_id: Keyword.get(opts, :workflow_id, @default_workflow_id),
      step_id: node.id,
      step_name: node.label,
      step_type: Atom.to_string(node.kind),
      instruction: render_prompt(node.prompt, step_input),
      input: step_input,
      previous_outputs: previous_outputs,
      system: node.system_prompt,
      model: node.model,
      location: Keyword.get(opts, :location, @default_location),
      project: Keyword.get(opts, :project, @default_project),
      endpoint: @vertex_step_endpoint,
      temperature: Map.get(node, :temperature, 0.1)
    }
  end

  @doc """
  Executes the ServEngine workflow DAG sequentially, chaining each node's output
  into the next node's `{{input}}` and accumulating `previous_outputs`.

  Options:
    * `:dag` - DAG map (defaults to `default_dag/0`)
    * `:workflow_id` - workflow identifier (defaults to `"servengine-wo-dag"`)
    * `:location` - Vertex AI location (must be `"global"`)
    * `:project` - GCP project ID (defaults to `"servengine-prod"`)
    * `:step_executor` - 1-arity function `(step_request -> {:ok, response} | {:error, reason})`
      (defaults to `default_vertex_executor/1`)
    * `:stop_on_error` - whether to halt remaining nodes on first error (default: `true`)
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  def run(initial_input, opts \\ []) when is_binary(initial_input) do
    dag = Keyword.get(opts, :dag, default_dag())
    executor = Keyword.get(opts, :step_executor, &default_vertex_executor/1)
    stop_on_error = Keyword.get(opts, :stop_on_error, true)
    workflow_id = Keyword.get(opts, :workflow_id, @default_workflow_id)
    location = Keyword.get(opts, :location, @default_location)

    with :ok <- validate_vertex_config(opts),
         {:ok, ordered_ids} <- validate_dag(dag) do
      nodes_by_id = Map.new(dag.nodes, &{&1.id, &1})
      parents_by_id = build_parents_map(dag.edges)

      initial_acc = %{
        current_input: initial_input,
        outputs: %{},
        nodes_by_id: nodes_by_id,
        trace: [],
        completed_steps: [],
        skipped_steps: [],
        failed_step: nil,
        failure_reason: nil,
        total_duration_ms: 0
      }

      final_acc =
        Enum.reduce(ordered_ids, initial_acc, fn node_id, acc ->
          if stop_on_error and acc.failed_step != nil do
            updated_node =
              acc.nodes_by_id
              |> Map.fetch!(node_id)
              |> Map.put(:status, :skipped)

            %{
              acc
              | nodes_by_id: Map.put(acc.nodes_by_id, node_id, updated_node),
                skipped_steps: acc.skipped_steps ++ [node_id]
            }
          else
            node = Map.fetch!(acc.nodes_by_id, node_id)
            step_input = resolve_step_input(node_id, parents_by_id, acc.outputs, initial_input)
            request = build_step_request(node, step_input, acc.outputs, opts)

            case executor.(request) do
              {:ok, response} ->
                output = extract_step_output(response)
                latency_ms = Map.get(response, :latency_ms, Map.get(response, "latencyMs", 0))

                updated_node =
                  node
                  |> Map.put(:status, :completed)
                  |> Map.put(:output, output)
                  |> Map.put(:error, nil)
                  |> Map.put(:duration_ms, latency_ms)

                trace_entry = %{
                  step_id: node_id,
                  label: node.label,
                  model: request.model,
                  location: request.location,
                  status: :completed,
                  latency_ms: latency_ms,
                  request: request,
                  response: response
                }

                %{
                  acc
                  | current_input: output,
                    outputs: Map.put(acc.outputs, node_id, output),
                    nodes_by_id: Map.put(acc.nodes_by_id, node_id, updated_node),
                    trace: acc.trace ++ [trace_entry],
                    completed_steps: acc.completed_steps ++ [node_id],
                    total_duration_ms: acc.total_duration_ms + latency_ms
                }

              {:error, reason} ->
                updated_node =
                  node
                  |> Map.put(:status, :error)
                  |> Map.put(:error, reason)

                trace_entry = %{
                  step_id: node_id,
                  label: node.label,
                  model: request.model,
                  location: request.location,
                  status: :error,
                  error: reason,
                  request: request
                }

                %{
                  acc
                  | nodes_by_id: Map.put(acc.nodes_by_id, node_id, updated_node),
                    trace: acc.trace ++ [trace_entry],
                    failed_step: acc.failed_step || node_id,
                    failure_reason: acc.failure_reason || reason
                }
            end
          end
        end)

      ordered_nodes = Enum.map(ordered_ids, &Map.fetch!(final_acc.nodes_by_id, &1))

      if final_acc.failed_step do
        {:error,
         %{
           workflow_id: workflow_id,
           route: @workflow_route,
           location: location,
           status: :error,
           failed_step: final_acc.failed_step,
           reason: final_acc.failure_reason,
           execution_order: ordered_ids,
           completed_steps: final_acc.completed_steps,
           skipped_steps: final_acc.skipped_steps,
           nodes: ordered_nodes,
           outputs: final_acc.outputs,
           trace: final_acc.trace
         }}
      else
        final_step_id = List.last(ordered_ids)

        {:ok,
         %{
           workflow_id: workflow_id,
           route: @workflow_route,
           location: location,
           status: :completed,
           execution_order: ordered_ids,
           nodes: ordered_nodes,
           outputs: final_acc.outputs,
           final_output: Map.get(final_acc.outputs, final_step_id),
           trace: final_acc.trace,
           total_duration_ms: final_acc.total_duration_ms
         }}
      end
    end
  end

  @doc """
  Deterministic built-in Vertex AI step simulator for offline verification.
  """
  @spec default_vertex_executor(step_request()) :: {:ok, step_response()}
  def default_vertex_executor(%{step_id: step_id, model: model, location: location} = req) do
    summary =
      case step_id do
        "intake" ->
          "[Intake/#{model}] Trade: HVAC | Urgency: P1 | Normalized: #{String.slice(req.input, 0, 80)}"

        "triage" ->
          "[Triage/#{model}] SLA: 4h Emergency | Cert: EPA-608 | From: #{req.input}"

        "dispatch" ->
          "[Dispatch/#{model}] Tech Assigned: HVAC-Senior-04 | ETA: 45m | Based on: #{req.input}"

        "proposal" ->
          "[Proposal/#{model}] Estimate: $1,450 NTE-Compliant | Scope from: #{req.input}"

        "qa" ->
          "[QA/#{model}] Verdict: PASS | ChainVerified: #{map_size(req.previous_outputs)} prior steps | Final: #{req.input}"

        other ->
          "[#{other}/#{model}] Processed: #{req.input}"
      end

    latency_ms =
      case model do
        "gemini-4-neon" -> 120
        _ -> 150
      end

    {:ok,
     %{
       text: summary,
       output: summary,
       step_id: step_id,
       status: "completed",
       model: model,
       project: req.project,
       location: location,
       latency_ms: latency_ms
     }}
  end

  # -- Private helpers --

  defp ensure_non_empty([]), do: {:error, :empty_dag}
  defp ensure_non_empty(_nodes), do: :ok

  defp ensure_unique_ids(nodes) do
    ids = Enum.map(nodes, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_node_id, dup}}
    end
  end

  defp ensure_supported_models(nodes) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      if node.model in @supported_models do
        {:cont, :ok}
      else
        {:halt, {:error, {:unsupported_model, node.id, node.model}}}
      end
    end)
  end

  defp ensure_valid_edges(edges, node_ids) do
    Enum.reduce_while(edges, :ok, fn
      {from, to}, :ok when from == to ->
        {:halt, {:error, {:self_loop, from}}}

      {from, to}, :ok ->
        cond do
          not MapSet.member?(node_ids, from) ->
            {:halt, {:error, {:unknown_edge_node, from}}}

          not MapSet.member?(node_ids, to) ->
            {:halt, {:error, {:unknown_edge_node, to}}}

          true ->
            {:cont, :ok}
        end

      invalid, :ok ->
        {:halt, {:error, {:invalid_edge, invalid}}}
    end)
  end

  defp topological_sort(nodes, edges) do
    node_order = Enum.map(nodes, & &1.id)
    order_index = node_order |> Enum.with_index() |> Map.new()

    in_degree =
      Enum.reduce(edges, Map.new(node_order, &{&1, 0}), fn {_from, to}, acc ->
        Map.update!(acc, to, &(&1 + 1))
      end)

    adjacency =
      Enum.reduce(edges, Map.new(node_order, &{&1, []}), fn {from, to}, acc ->
        Map.update!(acc, from, &(&1 ++ [to]))
      end)

    queue =
      node_order
      |> Enum.filter(&(Map.fetch!(in_degree, &1) == 0))

    kahn_loop(queue, in_degree, adjacency, order_index, [], length(node_order))
  end

  defp kahn_loop([], in_degree, _adjacency, _order_index, sorted, total) do
    if length(sorted) == total do
      {:ok, Enum.reverse(sorted)}
    else
      remaining =
        in_degree
        |> Enum.filter(fn {_id, deg} -> deg > 0 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      {:error, {:cycle_detected, remaining}}
    end
  end

  defp kahn_loop([current | rest], in_degree, adjacency, order_index, sorted, total) do
    neighbors = Map.fetch!(adjacency, current)

    {next_in_degree, newly_ready} =
      Enum.reduce(neighbors, {in_degree, []}, fn neighbor, {deg_acc, ready_acc} ->
        new_deg = Map.fetch!(deg_acc, neighbor) - 1
        deg_acc = Map.put(deg_acc, neighbor, new_deg)

        if new_deg == 0 do
          {deg_acc, [neighbor | ready_acc]}
        else
          {deg_acc, ready_acc}
        end
      end)

    next_queue =
      (rest ++ newly_ready)
      |> Enum.sort_by(&Map.fetch!(order_index, &1))

    kahn_loop(next_queue, next_in_degree, adjacency, order_index, [current | sorted], total)
  end

  defp build_parents_map(edges) do
    Enum.reduce(edges, %{}, fn {from, to}, acc ->
      Map.update(acc, to, [from], &(&1 ++ [from]))
    end)
  end

  defp resolve_step_input(node_id, parents_by_id, outputs, initial_input) do
    case Map.get(parents_by_id, node_id, []) do
      [] ->
        initial_input

      [single_parent] ->
        Map.get(outputs, single_parent, initial_input)

      parents ->
        parents
        |> Enum.map_join("\n\n", fn parent_id ->
          "#{parent_id}: #{Map.get(outputs, parent_id, "")}"
        end)
    end
  end

  defp extract_step_output(response) when is_binary(response), do: response

  defp extract_step_output(response) when is_map(response) do
    cond do
      is_binary(Map.get(response, :output)) -> Map.get(response, :output)
      is_binary(Map.get(response, "output")) -> Map.get(response, "output")
      is_binary(Map.get(response, :text)) -> Map.get(response, :text)
      is_binary(Map.get(response, "text")) -> Map.get(response, "text")
      true -> ""
    end
  end

  defp extract_step_output(_), do: ""
end

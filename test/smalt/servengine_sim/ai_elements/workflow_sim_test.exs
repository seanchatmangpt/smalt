defmodule Smalt.ServengineSim.AiElements.WorkflowSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.AiElements.WorkflowSim

  @sample_wo "Main rooftop HVAC unit #2 is blowing warm air in Building B; tenant reports 81F on floor 3."

  describe "canonical 5-node ServEngine DAG" do
    test "defines Intake -> Triage -> Dispatch -> Proposal -> QA with Vertex global models" do
      dag = WorkflowSim.default_dag()

      assert WorkflowSim.workflow_route() == "/ai/workflow"
      assert WorkflowSim.vertex_step_endpoint() == "/api/ai/vertex/workflow/step"
      assert WorkflowSim.default_location() == "global"

      assert Enum.map(dag.nodes, & &1.id) == ["intake", "triage", "dispatch", "proposal", "qa"]
      assert Enum.map(dag.nodes, & &1.label) == ["Intake", "Triage", "Dispatch", "Proposal", "QA"]

      assert dag.edges == [
               {"intake", "triage"},
               {"triage", "dispatch"},
               {"dispatch", "proposal"},
               {"proposal", "qa"}
             ]

      assert Enum.all?(dag.nodes, &(&1.model in WorkflowSim.supported_models()))
      assert {:ok, ["intake", "triage", "dispatch", "proposal", "qa"]} = WorkflowSim.validate_dag(dag)
    end
  end

  describe "sequential Vertex step chaining" do
    test "executes all 5 nodes in topological order and chains outputs through {{input}} and previous_outputs" do
      assert {:ok, result} = WorkflowSim.run(@sample_wo)

      assert result.route == "/ai/workflow"
      assert result.location == "global"
      assert result.status == :completed
      assert result.execution_order == ["intake", "triage", "dispatch", "proposal", "qa"]
      assert result.total_duration_ms == 600

      assert Enum.all?(result.nodes, &(&1.status == :completed))
      assert length(result.trace) == 5

      [intake, triage, dispatch, proposal, qa] = result.trace

      # Step 1: Intake receives raw initial input and empty previous_outputs
      assert intake.step_id == "intake"
      assert intake.model == "gemini-4-neon"
      assert intake.location == "global"
      assert intake.request.input == @sample_wo
      assert intake.request.previous_outputs == %{}
      assert String.contains?(intake.request.instruction, @sample_wo)

      # Step 2: Triage receives Intake output
      assert triage.step_id == "triage"
      assert triage.request.input == result.outputs["intake"]
      assert Map.keys(triage.request.previous_outputs) == ["intake"]
      assert String.contains?(triage.request.instruction, result.outputs["intake"])

      # Step 3: Dispatch uses gemini-4-neon and receives Triage output
      assert dispatch.step_id == "dispatch"
      assert dispatch.model == "gemini-4-neon"
      assert dispatch.request.input == result.outputs["triage"]
      assert MapSet.new(Map.keys(dispatch.request.previous_outputs)) == MapSet.new(["intake", "triage"])

      # Step 4: Proposal uses gemini-4-neon and receives Dispatch output
      assert proposal.step_id == "proposal"
      assert proposal.model == "gemini-4-neon"
      assert proposal.request.input == result.outputs["dispatch"]

      # Step 5: QA receives Proposal output and all 4 prior outputs
      assert qa.step_id == "qa"
      assert qa.model == "gemini-4-neon"
      assert qa.request.input == result.outputs["proposal"]
      assert map_size(qa.request.previous_outputs) == 4
      assert result.final_output == result.outputs["qa"]
      assert String.contains?(result.final_output, "Verdict: PASS")
    end

    test "supports custom injectable Vertex step_executor and preserves strict sequential order" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      executor = fn req ->
        Agent.update(agent, fn calls -> calls ++ [req.step_id] end)

        {:ok,
         %{
           text: "step:#{req.step_id}|prev:#{map_size(req.previous_outputs)}",
           output: "step:#{req.step_id}|prev:#{map_size(req.previous_outputs)}",
           step_id: req.step_id,
           status: "completed",
           model: req.model,
           project: req.project,
           location: req.location,
           latency_ms: 42
         }}
      end

      assert {:ok, result} =
               WorkflowSim.run(@sample_wo,
                 workflow_id: "wf-custom-01",
                 project: "srve-staging",
                 step_executor: executor
               )

      assert Agent.get(agent, & &1) == ["intake", "triage", "dispatch", "proposal", "qa"]
      assert result.workflow_id == "wf-custom-01"
      assert result.final_output == "step:qa|prev:4"
      assert result.total_duration_ms == 210
    end

    test "fails closed on step error and skips downstream nodes" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      failing_executor = fn req ->
        Agent.update(agent, fn calls -> calls ++ [req.step_id] end)

        if req.step_id == "dispatch" do
          {:error, {:vertex_http_error, 503, "model temporarily unavailable"}}
        else
          WorkflowSim.default_vertex_executor(req)
        end
      end

      assert {:error, failure} = WorkflowSim.run(@sample_wo, step_executor: failing_executor)

      assert failure.status == :error
      assert failure.failed_step == "dispatch"
      assert failure.reason == {:vertex_http_error, 503, "model temporarily unavailable"}
      assert failure.completed_steps == ["intake", "triage"]
      assert failure.skipped_steps == ["proposal", "qa"]
      assert Agent.get(agent, & &1) == ["intake", "triage", "dispatch"]

      statuses = Map.new(failure.nodes, &{&1.id, &1.status})
      assert statuses == %{
               "intake" => :completed,
               "triage" => :completed,
               "dispatch" => :error,
               "proposal" => :skipped,
               "qa" => :skipped
             }
    end
  end

  describe "DAG and Vertex AI validation" do
    test "rejects cyclic DAGs" do
      dag = WorkflowSim.default_dag()
      cyclic_dag = %{dag | edges: dag.edges ++ [{"qa", "intake"}]}

      assert {:error, {:cycle_detected, remaining}} = WorkflowSim.validate_dag(cyclic_dag)
      assert length(remaining) == 5
      assert {:error, {:cycle_detected, _}} = WorkflowSim.run(@sample_wo, dag: cyclic_dag)
    end

    test "rejects self-loops and unknown edge endpoints" do
      dag = WorkflowSim.default_dag()

      assert {:error, {:self_loop, "triage"}} =
               WorkflowSim.validate_dag(%{dag | edges: dag.edges ++ [{"triage", "triage"}]})

      assert {:error, {:unknown_edge_node, "ghost"}} =
               WorkflowSim.validate_dag(%{dag | edges: dag.edges ++ [{"qa", "ghost"}]})
    end

    test "rejects unsupported Vertex models" do
      dag = WorkflowSim.default_dag()

      bad_nodes =
        Enum.map(dag.nodes, fn
          %{id: "dispatch"} = n -> %{n | model: "gemini-1.5-pro"}
          n -> n
        end)

      assert {:error, {:unsupported_model, "dispatch", "gemini-1.5-pro"}} =
               WorkflowSim.run(@sample_wo, dag: %{dag | nodes: bad_nodes})
    end

    test "enforces Vertex AI global location" do
      assert {:error, {:invalid_vertex_location, "us-central1", expected: "global"}} =
               WorkflowSim.run(@sample_wo, location: "us-central1")
    end
  end
end

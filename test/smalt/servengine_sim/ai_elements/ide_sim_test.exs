defmodule Smalt.ServengineSim.AiElements.IdeSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.AiElements.IdeSim

  describe "workspace initialization and Vertex AI model selection" do
    test "boots with canonical starter files and Vertex global / gemini-4-neon" do
      state = IdeSim.new()

      assert state.location == "global"
      assert state.model == "gemini-4-neon"
      assert IdeSim.supported_models() == ["gemini-4-neon"]
      assert length(state.files) == 4
      assert state.active_path == "lib/xaas/work_orders/work_order.ex"
      assert length(state.open_paths) == 4
      assert MapSet.size(state.dirty_paths) == 0
    end

    test "switches to gemini-4-neon and rejects unsupported models" do
      state = IdeSim.new()

      assert {:ok, pro_state} = IdeSim.set_model(state, "gemini-4-neon")
      assert pro_state.model == "gemini-4-neon"

      assert {:error, {:unsupported_model, "gpt-4o"}} = IdeSim.set_model(pro_state, "gpt-4o")
    end
  end

  describe "file tree operations" do
    test "build_tree/1 sorts directories before files alphabetically" do
      state = IdeSim.new()
      {:ok, state} = IdeSim.create_file(state, "README.md", "# ServEngine IDE")

      tree = IdeSim.build_tree(state)
      names = Enum.map(tree, &{&1.name, &1.is_dir})

      assert names == [
               {"lib", true},
               {"playwright", true},
               {"src", true},
               {"README.md", false}
             ]
    end

    test "create_file/3 infers language, opens tab, sets active, and validates input" do
      state = IdeSim.new()

      assert {:error, :empty_path} = IdeSim.create_file(state, "   ")
      assert {:error, :directory_path} = IdeSim.create_file(state, "lib/xaas/")

      assert {:error, :already_exists} =
               IdeSim.create_file(state, "lib/xaas/work_orders/work_order.ex")

      assert {:ok, next} = IdeSim.create_file(state, "/lib/xaas/ai/notes.ex", "# notes\n")
      assert next.active_path == "lib/xaas/ai/notes.ex"
      assert "lib/xaas/ai/notes.ex" in next.open_paths

      created = IdeSim.active_file(next)
      assert created.name == "notes.ex"
      assert created.language == "elixir"
      assert created.content == "# notes\n"
    end

    test "delete_file/2 removes file, tab, and dirty marker, and refuses deleting last file" do
      state = IdeSim.new()
      target = "lib/xaas/work_orders/work_order.ex"

      {:ok, state} = IdeSim.edit_content(state, target, "edited")
      assert IdeSim.dirty?(state, target)

      {:ok, state} = IdeSim.delete_file(state, target)
      refute Enum.any?(state.files, &(&1.path == target))
      refute target in state.open_paths
      refute IdeSim.dirty?(state, target)
      assert state.active_path == "lib/xaas_web/controllers/ai_elements_controller.ex"

      single_file_state =
        IdeSim.new(
          files: [%{path: "only.ex", name: "only.ex", language: "elixir", content: ""}]
        )

      assert {:error, :cannot_delete_last_file} = IdeSim.delete_file(single_file_state, "only.ex")
      assert {:error, :file_not_found} = IdeSim.delete_file(single_file_state, "missing.ex")
    end

    test "close_tab/2 closes tab without deleting file and select_file/2 reopens it" do
      state = IdeSim.new()
      target = "lib/xaas/work_orders/work_order.ex"

      closed = IdeSim.close_tab(state, target)
      refute target in closed.open_paths
      assert Enum.any?(closed.files, &(&1.path == target))
      assert closed.active_path == "playwright/e2e/ai-elements.spec.ts"

      assert {:ok, reopened} = IdeSim.select_file(closed, target)
      assert reopened.active_path == target
      assert target in reopened.open_paths
    end
  end

  describe "editor dirty state" do
    test "edit_content/3 marks file dirty, updates line count, and save_file/2 clears dirty" do
      state = IdeSim.new()
      target = "lib/xaas/work_orders/work_order.ex"

      refute IdeSim.dirty?(state, target)

      {:ok, edited} = IdeSim.edit_content(state, target, "line1\nline2\nline3")
      assert IdeSim.dirty?(edited, target)

      tab = Enum.find(IdeSim.open_tabs(edited), &(&1.path == target))
      assert tab.is_dirty == true
      assert tab.line_count == 3

      {:ok, saved} = IdeSim.save_file(edited, target)
      refute IdeSim.dirty?(saved, target)
    end
  end

  describe "Vertex AI Copilot (Explain / Refactor / Add Tests) and Apply-to-Editor" do
    test "Explain quick action sends explain request and returns explanation without code" do
      state = IdeSim.new()

      assert {:ok, next, msg} = IdeSim.quick_action(state, :explain)
      assert msg.role == :assistant
      assert msg.action == "explain"
      assert msg.model == "gemini-4-neon"
      assert msg.location == "global"
      assert msg.suggested_code == nil
      assert msg.applied == false
      assert length(next.messages) == 2

      # Cannot apply an explain-only response that has no suggested_code
      assert {:error, :no_suggested_code} = IdeSim.apply_to_editor(next, msg.id)
    end

    test "Refactor quick action produces suggested_code and apply_to_editor/2 updates buffer and marks dirty" do
      {:ok, state} = IdeSim.new() |> IdeSim.set_model("gemini-4-neon")
      target = state.active_path

      assert {:ok, state, msg} = IdeSim.quick_action(state, :refactor)
      assert msg.action == "refactor"
      assert msg.model == "gemini-4-neon"
      assert msg.location == "global"
      assert is_binary(msg.suggested_code)
      assert String.contains?(msg.suggested_code, "gemini-4-neon")
      assert msg.applied == false

      # Close the tab first to verify apply_to_editor reopens and focuses it
      state = IdeSim.close_tab(state, target)
      refute target in state.open_paths

      assert {:ok, applied_state} = IdeSim.apply_to_editor(state, msg.id)
      assert applied_state.active_path == target
      assert target in applied_state.open_paths
      assert IdeSim.dirty?(applied_state, target)
      assert IdeSim.active_file(applied_state).content == msg.suggested_code

      updated_msg = Enum.find(applied_state.messages, &(&1.id == msg.id))
      assert updated_msg.applied == true
    end

    test "Add Tests quick action maps to Vertex action \"test\" and generates runnable tests" do
      parent = self()

      runner = fn req ->
        send(parent, {:vertex_req, req})
        IdeSim.default_vertex_runner(req)
      end

      state = IdeSim.new(vertex_runner: runner)
      assert {:ok, _next, msg} = IdeSim.quick_action(state, :add_tests)

      assert_received {:vertex_req, req}
      assert req.action == "test"
      assert req.location == "global"
      assert req.model == "gemini-4-neon"
      assert String.contains?(req.prompt, "Write comprehensive, runnable unit tests")

      assert msg.action == "test"
      assert is_binary(msg.suggested_code)
      assert String.contains?(msg.suggested_code, "ExUnit.Case")
    end

    test "extracts fenced code block when Vertex response omits explicit code field" do
      runner = fn req ->
        {:ok,
         %{
           text: "Here is the fix:\n```elixir\ndefmodule Patched do\n  def ok, do: :ok\nend\n```",
           model: req.model,
           location: req.location
         }}
      end

      state = IdeSim.new(vertex_runner: runner)
      assert {:ok, next, msg} = IdeSim.run_assist(state, "fix", "Fix edge case")
      assert msg.suggested_code == "defmodule Patched do\n  def ok, do: :ok\nend"

      assert {:ok, applied} = IdeSim.apply_to_editor(next, msg.id)
      assert IdeSim.active_file(applied).content == msg.suggested_code
    end

    test "records last_error when Vertex AI runner fails" do
      runner = fn _req -> {:error, {:http_error, 502, "vertex_unavailable"}} end
      state = IdeSim.new(vertex_runner: runner)

      assert {:error, {:http_error, 502, "vertex_unavailable"}, err_state} =
               IdeSim.quick_action(state, :refactor)

      assert is_binary(err_state.last_error)
      assert String.contains?(err_state.last_error, "vertex_unavailable")
    end
  end
end

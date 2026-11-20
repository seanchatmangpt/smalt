defmodule Smalt.ServengineSim.AiElements.IdeSim do
  @moduledoc """
  Self-contained Elixir simulator for the ServEngine `/ai/ide` AI Elements
  workspace (`IdeWorkspace`, `IdeFileTree`, `IdeEditorPane`) backed by
  GCP Vertex AI (`global` location, `gemini-4-neon` and
  `gemini-4-neon`).

  Models:
    * Hierarchical file tree (`build_tree/1`, create/delete/select/close tabs)
    * Editor buffer content, line counts, and dirty-state tracking
    * Vertex AI Copilot actions (`:explain`, `:refactor`, `:add_tests`, `:fix`)
      with `/api/ai/ide-assist` request/response parity and fenced code-block
      extraction
    * `apply_to_editor/2` applying a copilot suggestion into the target editor
      buffer, marking the file dirty, focusing its tab, and flagging the
      message as `applied: true`
  """

  @default_location "global"
  @default_project "servengine-ai"
  @default_model "gemini-4-neon"
  @supported_models ["gemini-4-neon"]

  @type vertex_model :: String.t()
  @type quick_action :: :explain | :refactor | :add_tests | :fix
  @type assist_action :: String.t()

  @type ide_file :: %{
          path: String.t(),
          name: String.t(),
          language: String.t(),
          content: String.t()
        }

  @type tree_node :: %{
          name: String.t(),
          path: String.t(),
          is_dir: boolean(),
          children: [tree_node()],
          file: ide_file() | nil
        }

  @type copilot_message :: %{
          id: String.t(),
          role: :user | :assistant,
          content: String.t(),
          suggested_code: String.t() | nil,
          model: String.t() | nil,
          location: String.t() | nil,
          action: assist_action() | nil,
          file_path: String.t() | nil,
          applied: boolean()
        }

  @type assist_request :: %{
          action: assist_action(),
          prompt: String.t(),
          instruction: String.t(),
          file_path: String.t(),
          code: String.t(),
          language: String.t(),
          model: vertex_model(),
          location: String.t()
        }

  @type assist_response :: %{
          required(:text) => String.t(),
          optional(:code) => String.t() | nil,
          optional(:explanation) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:project) => String.t() | nil,
          optional(:location) => String.t() | nil
        }

  @type vertex_runner :: (assist_request() -> {:ok, assist_response()} | {:error, term()})

  @type t :: %__MODULE__{
          files: [ide_file()],
          open_paths: [String.t()],
          dirty_paths: MapSet.t(String.t()),
          active_path: String.t() | nil,
          model: vertex_model(),
          location: String.t(),
          project: String.t(),
          messages: [copilot_message()],
          next_msg_seq: pos_integer(),
          last_error: String.t() | nil,
          vertex_runner: vertex_runner()
        }

  defstruct files: [],
            open_paths: [],
            dirty_paths: MapSet.new(),
            active_path: nil,
            model: @default_model,
            location: @default_location,
            project: @default_project,
            messages: [],
            next_msg_seq: 1,
            last_error: nil,
            vertex_runner: &__MODULE__.default_vertex_runner/1

  # ---------------------------------------------------------------------------
  # Constants & Defaults
  # ---------------------------------------------------------------------------

  @doc "Returns the supported Vertex AI model identifiers for `/ai/ide`."
  @spec supported_models() :: [vertex_model()]
  def supported_models, do: @supported_models

  @doc "Returns the default Vertex AI model (`gemini-4-neon`)."
  @spec default_model() :: vertex_model()
  def default_model, do: @default_model

  @doc "Returns the default Vertex AI location (`global`)."
  @spec default_location() :: String.t()
  def default_location, do: @default_location

  @doc """
  Returns the canonical starter workspace files matching `DEFAULT_IDE_FILES`
  in `servengine-frontend/src/components/features/AiElements/ide/IdeFileTree.tsx`.
  """
  @spec default_files() :: [ide_file()]
  def default_files do
    [
      %{
        path: "lib/xaas/work_orders/work_order.ex",
        name: "work_order.ex",
        language: "elixir",
        content: """
        defmodule Xaas.WorkOrders.WorkOrder do
          @moduledoc \"\"\"
          Ash resource representing a field service work order in XaaS.
          \"\"\"

          use Ash.Resource,
            otp_app: :xaas,
            domain: Xaas.WorkOrders,
            data_layer: AshPostgres.DataLayer
        end
        """
      },
      %{
        path: "lib/xaas_web/controllers/ai_elements_controller.ex",
        name: "ai_elements_controller.ex",
        language: "elixir",
        content: """
        defmodule XaasWeb.AiElementsController do
          @moduledoc \"\"\"
          Phoenix controller wiring Vercel AI Elements surfaces (IDE, Workflow, Chatbot)
          to GCP Vertex AI (gemini-4-neon).
          \"\"\"

          use XaasWeb, :controller
        end
        """
      },
      %{
        path: "src/routes/_auth/ai-elements.tsx",
        name: "ai-elements.tsx",
        language: "tsx",
        content: """
        import { createFileRoute } from '@tanstack/react-router';

        export const Route = createFileRoute('/_auth/ai-elements')({
          component: AiElementsPage,
        });

        function AiElementsPage() {
          return null;
        }
        """
      },
      %{
        path: "playwright/e2e/ai-elements.spec.ts",
        name: "ai-elements.spec.ts",
        language: "typescript",
        content: """
        import { expect, test } from '@playwright/test';

        test.describe('AI Elements IDE', () => {
          test('selects files from the tree', async ({ page }) => {
            await page.goto('/ai/ide');
            await expect(page.getByTestId('ide-file-tree')).toBeVisible();
          });
        });
        """
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Constructor & Model Selection
  # ---------------------------------------------------------------------------

  @doc """
  Initializes a new `/ai/ide` workspace simulation state.

  Options:
    * `:files` - initial list of `ide_file` maps (defaults to `default_files/0`)
    * `:model` - Vertex AI model (defaults to `"gemini-4-neon"`)
    * `:location` - Vertex AI location (defaults to `"global"`)
    * `:project` - GCP project id (defaults to `"servengine-ai"`)
    * `:vertex_runner` - 1-arity function simulating `/api/ai/ide-assist`
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    files = Keyword.get(opts, :files, default_files())
    open_paths = Enum.map(files, & &1.path)
    active_path = List.first(open_paths)

    %__MODULE__{
      files: files,
      open_paths: open_paths,
      dirty_paths: MapSet.new(),
      active_path: active_path,
      model: Keyword.get(opts, :model, @default_model),
      location: Keyword.get(opts, :location, @default_location),
      project: Keyword.get(opts, :project, @default_project),
      vertex_runner: Keyword.get(opts, :vertex_runner, &__MODULE__.default_vertex_runner/1)
    }
  end

  @doc "Switches the active Vertex AI model if supported."
  @spec set_model(t(), vertex_model()) :: {:ok, t()} | {:error, {:unsupported_model, vertex_model()}}
  def set_model(%__MODULE__{} = state, model) when model in @supported_models do
    {:ok, %{state | model: model}}
  end

  def set_model(%__MODULE__{}, model) do
    {:error, {:unsupported_model, model}}
  end

  # ---------------------------------------------------------------------------
  # File Tree & Tab Operations
  # ---------------------------------------------------------------------------

  @doc """
  Infers the editor language identifier from a file path, matching
  `IdeFileTree.tsx`'s `inferLanguage`.
  """
  @spec infer_language(String.t()) :: String.t()
  def infer_language(path) when is_binary(path) do
    lower = String.downcase(path)

    cond do
      String.ends_with?(lower, ".ex") or String.ends_with?(lower, ".exs") -> "elixir"
      String.ends_with?(lower, ".tsx") -> "tsx"
      String.ends_with?(lower, ".ts") -> "typescript"
      String.ends_with?(lower, ".jsx") -> "jsx"
      String.ends_with?(lower, ".js") or String.ends_with?(lower, ".mjs") -> "javascript"
      String.ends_with?(lower, ".json") -> "json"
      String.ends_with?(lower, ".md") -> "markdown"
      String.ends_with?(lower, ".css") -> "css"
      true -> "text"
    end
  end

  @doc """
  Builds a sorted hierarchical directory/file tree from `files` (directories
  first, then files, sorted alphabetically by name).
  """
  @spec build_tree([ide_file()] | t()) :: [tree_node()]
  def build_tree(%__MODULE__{files: files}), do: build_tree(files)

  def build_tree(files) when is_list(files) do
    files
    |> Enum.reduce([], fn file, root ->
      parts =
        file.path
        |> String.trim_leading("/")
        |> String.split("/", trim: true)

      insert_tree_parts(root, parts, "", file)
    end)
    |> sort_tree_nodes()
  end

  @doc "Creates a new file in the tree, opens its tab, and makes it active."
  @spec create_file(t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :empty_path | :directory_path | :already_exists}
  def create_file(%__MODULE__{} = state, raw_path, content \\ "") when is_binary(raw_path) do
    trimmed = raw_path |> String.trim() |> String.trim_leading("/")

    cond do
      trimmed == "" ->
        {:error, :empty_path}

      String.ends_with?(trimmed, "/") ->
        {:error, :directory_path}

      Enum.any?(state.files, &(&1.path == trimmed)) ->
        {:error, :already_exists}

      true ->
        name = trimmed |> String.split("/") |> List.last()

        new_file = %{
          path: trimmed,
          name: name,
          language: infer_language(trimmed),
          content: content
        }

        {:ok,
         %{
           state
           | files: state.files ++ [new_file],
             open_paths: append_unique(state.open_paths, trimmed),
             active_path: trimmed
         }}
    end
  end

  @doc """
  Deletes a file from the workspace, removing its open tab and dirty marker.
  Refuses to delete the last remaining file in the workspace.
  """
  @spec delete_file(t(), String.t()) ::
          {:ok, t()} | {:error, :file_not_found | :cannot_delete_last_file}
  def delete_file(%__MODULE__{files: files} = state, path) when is_binary(path) do
    cond do
      not Enum.any?(files, &(&1.path == path)) ->
        {:error, :file_not_found}

      length(files) <= 1 ->
        {:error, :cannot_delete_last_file}

      true ->
        next_files = Enum.reject(files, &(&1.path == path))
        next_open = Enum.reject(state.open_paths, &(&1 == path))
        next_dirty = MapSet.delete(state.dirty_paths, path)

        next_active =
          if state.active_path == path do
            case next_files do
              [first | _] -> first.path
              [] -> nil
            end
          else
            state.active_path
          end

        {:ok,
         %{
           state
           | files: next_files,
             open_paths: next_open,
             dirty_paths: next_dirty,
             active_path: next_active
         }}
    end
  end

  @doc "Selects an existing file, opening its tab if not already open."
  @spec select_file(t(), String.t()) :: {:ok, t()} | {:error, :file_not_found}
  def select_file(%__MODULE__{} = state, path) when is_binary(path) do
    if Enum.any?(state.files, &(&1.path == path)) do
      {:ok,
       %{
         state
         | active_path: path,
           open_paths: append_unique(state.open_paths, path)
       }}
    else
      {:error, :file_not_found}
    end
  end

  @doc "Closes an open editor tab without deleting the file from the tree."
  @spec close_tab(t(), String.t()) :: t()
  def close_tab(%__MODULE__{} = state, path) when is_binary(path) do
    next_open = Enum.reject(state.open_paths, &(&1 == path))

    next_active =
      if state.active_path == path do
        List.last(next_open)
      else
        state.active_path
      end

    %{state | open_paths: next_open, active_path: next_active}
  end

  # ---------------------------------------------------------------------------
  # Editor Buffer & Dirty State
  # ---------------------------------------------------------------------------

  @doc "Returns the currently active file or `nil` if no file is active."
  @spec active_file(t()) :: ide_file() | nil
  def active_file(%__MODULE__{active_path: nil}), do: nil

  def active_file(%__MODULE__{files: files, active_path: active_path}) do
    Enum.find(files, &(&1.path == active_path))
  end

  @doc "Returns open editor tabs enriched with `:is_dirty` and `:line_count`."
  @spec open_tabs(t()) :: [map()]
  def open_tabs(%__MODULE__{files: files, open_paths: open_paths, dirty_paths: dirty_paths}) do
    by_path = Map.new(files, &{&1.path, &1})

    open_paths
    |> Enum.flat_map(fn path ->
      case Map.fetch(by_path, path) do
        {:ok, file} ->
          [
            file
            |> Map.put(:is_dirty, MapSet.member?(dirty_paths, path))
            |> Map.put(:line_count, count_lines(file.content))
          ]

        :error ->
          []
      end
    end)
  end

  @doc "Returns true when `path` has unsaved editor changes."
  @spec dirty?(t(), String.t()) :: boolean()
  def dirty?(%__MODULE__{dirty_paths: dirty_paths}, path) do
    MapSet.member?(dirty_paths, path)
  end

  @doc "Updates a file's editor buffer content and marks it dirty."
  @spec edit_content(t(), String.t(), String.t()) :: {:ok, t()} | {:error, :file_not_found}
  def edit_content(%__MODULE__{} = state, path, new_content)
      when is_binary(path) and is_binary(new_content) do
    if Enum.any?(state.files, &(&1.path == path)) do
      next_files =
        Enum.map(state.files, fn file ->
          if file.path == path, do: %{file | content: new_content}, else: file
        end)

      {:ok,
       %{
         state
         | files: next_files,
           dirty_paths: MapSet.put(state.dirty_paths, path)
       }}
    else
      {:error, :file_not_found}
    end
  end

  @doc "Clears the dirty flag for `path` (simulating a buffer save)."
  @spec save_file(t(), String.t()) :: {:ok, t()} | {:error, :file_not_found}
  def save_file(%__MODULE__{} = state, path) when is_binary(path) do
    if Enum.any?(state.files, &(&1.path == path)) do
      {:ok, %{state | dirty_paths: MapSet.delete(state.dirty_paths, path)}}
    else
      {:error, :file_not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Vertex AI Copilot (Explain / Refactor / Add Tests) & Apply-to-Editor
  # ---------------------------------------------------------------------------

  @doc """
  Maps an editor quick action (`:explain | :refactor | :add_tests | :fix`) to
  the `/api/ai/ide-assist` action string (`"explain"`, `"refactor"`, `"test"`, `"fix"`).
  """
  @spec map_quick_action(quick_action()) :: assist_action()
  def map_quick_action(:add_tests), do: "test"
  def map_quick_action(:explain), do: "explain"
  def map_quick_action(:refactor), do: "refactor"
  def map_quick_action(:fix), do: "fix"

  @doc """
  Builds the quick-action prompt for `action` and `file`, matching
  `IdeEditorPane.tsx`'s `buildQuickActionPrompt`.
  """
  @spec build_quick_action_prompt(quick_action(), ide_file()) :: String.t()
  def build_quick_action_prompt(action, %{path: path, language: language, content: content}) do
    fenced = "```#{String.downcase(language)}\n#{content}\n```"

    case action do
      :explain ->
        "Explain the purpose, control flow, and key edge cases of `#{path}` (#{language}):\n\n#{fenced}"

      :refactor ->
        "Refactor `#{path}` (#{language}) for clarity, type safety, and maintainability while preserving exact behavior:\n\n#{fenced}"

      :add_tests ->
        "Write comprehensive, runnable unit tests (no mocks/stubs) covering normal and edge cases for `#{path}` (#{language}):\n\n#{fenced}"

      :fix ->
        "Find bugs and add edge-case error handling for `#{path}` (#{language}):\n\n#{fenced}"
    end
  end

  @doc """
  Runs one of the editor quick actions (`:explain`, `:refactor`, `:add_tests`, `:fix`)
  against the currently active file via the configured Vertex AI runner.
  """
  @spec quick_action(t(), quick_action()) ::
          {:ok, t(), copilot_message()} | {:error, term(), t()}
  def quick_action(%__MODULE__{} = state, action)
      when action in [:explain, :refactor, :add_tests, :fix] do
    case active_file(state) do
      nil ->
        {:error, :no_active_file, state}

      file ->
        prompt = build_quick_action_prompt(action, file)
        run_assist(state, map_quick_action(action), prompt)
    end
  end

  @doc """
  Sends an arbitrary IDE assist prompt to Vertex AI (`/api/ai/ide-assist`)
  for the active file, appending both user and assistant messages to state.
  """
  @spec run_assist(t(), assist_action(), String.t()) ::
          {:ok, t(), copilot_message()} | {:error, term(), t()}
  def run_assist(%__MODULE__{} = state, action, instruction)
      when is_binary(action) and is_binary(instruction) do
    trimmed = String.trim(instruction)

    cond do
      trimmed == "" ->
        {:error, :empty_prompt, state}

      is_nil(active_file(state)) ->
        {:error, :no_active_file, state}

      true ->
        file = active_file(state)
        user_id = "user-#{state.next_msg_seq}"

        user_msg = %{
          id: user_id,
          role: :user,
          content: trimmed,
          suggested_code: nil,
          model: nil,
          location: nil,
          action: action,
          file_path: file.path,
          applied: false
        }

        state_with_user = %{
          state
          | messages: state.messages ++ [user_msg],
            next_msg_seq: state.next_msg_seq + 1,
            last_error: nil
        }

        request = %{
          action: action,
          prompt: trimmed,
          instruction: trimmed,
          file_path: file.path,
          code: file.content,
          language: file.language,
          model: state.model,
          location: state.location
        }

        case state.vertex_runner.(request) do
          {:ok, result} ->
            suggested_code = resolve_suggested_code(result)
            assistant_id = "assistant-#{state_with_user.next_msg_seq}"

            assistant_msg = %{
              id: assistant_id,
              role: :assistant,
              content: Map.get(result, :explanation) || Map.fetch!(result, :text),
              suggested_code: suggested_code,
              model: Map.get(result, :model) || state.model,
              location: Map.get(result, :location) || state.location,
              action: action,
              file_path: file.path,
              applied: false
            }

            next_state = %{
              state_with_user
              | messages: state_with_user.messages ++ [assistant_msg],
                next_msg_seq: state_with_user.next_msg_seq + 1
            }

            {:ok, next_state, assistant_msg}

          {:error, reason} ->
            err_state = %{state_with_user | last_error: inspect(reason)}
            {:error, reason, err_state}
        end
    end
  end

  @doc """
  Applies an assistant copilot message's `suggested_code` to its target file
  in the editor, marking the file dirty, focusing its tab, and setting
  `applied: true` on the message.
  """
  @spec apply_to_editor(t(), String.t()) ::
          {:ok, t()} | {:error, :message_not_found | :no_suggested_code | :file_not_found}
  def apply_to_editor(%__MODULE__{} = state, message_id) when is_binary(message_id) do
    case Enum.find(state.messages, &(&1.id == message_id and &1.role == :assistant)) do
      nil ->
        {:error, :message_not_found}

      %{suggested_code: code} when not is_binary(code) or code == "" ->
        {:error, :no_suggested_code}

      %{suggested_code: code, file_path: msg_file_path} ->
        target_path = msg_file_path || state.active_path

        with true <- is_binary(target_path) || {:error, :file_not_found},
             {:ok, edited_state} <- edit_content(state, target_path, code) do
          next_messages =
            Enum.map(edited_state.messages, fn msg ->
              if msg.id == message_id, do: %{msg | applied: true}, else: msg
            end)

          {:ok,
           %{
             edited_state
             | active_path: target_path,
               open_paths: append_unique(edited_state.open_paths, target_path),
               messages: next_messages
           }}
        end
    end
  end

  @doc """
  Extracts the first fenced code block from a markdown response string,
  matching `IdeWorkspace.tsx`'s `extractCodeBlock`.
  """
  @spec extract_code_block(String.t()) :: String.t() | nil
  def extract_code_block(text) when is_binary(text) do
    case Regex.run(~r/```[a-zA-Z0-9_-]*\n([\s\S]*?)```/, text) do
      [_, code] -> String.trim_trailing(code)
      _ -> nil
    end
  end

  @doc """
  Default deterministic Vertex AI `/api/ai/ide-assist` simulator supporting
  `explain`, `refactor`, `test`, and `fix` actions on `global` with
  `gemini-4-neon`.
  """
  @spec default_vertex_runner(assist_request()) :: {:ok, assist_response()}
  def default_vertex_runner(%{
        action: action,
        file_path: file_path,
        code: code,
        language: language,
        model: model,
        location: location
      }) do
    case action do
      "explain" ->
        {:ok,
         %{
           text: "Explanation for #{file_path} (#{language}): defines module logic and exports.",
           explanation: "Explanation for #{file_path} (#{language}): defines module logic and exports.",
           code: nil,
           model: model,
           project: @default_project,
           location: location
         }}

      "refactor" ->
        refactored = "# Refactored by #{model} (#{location})\n" <> code

        {:ok,
         %{
           text: "Refactored #{file_path} for clarity.\n\n```#{language}\n#{refactored}\n```",
           explanation: "Refactored #{file_path} for clarity.",
           code: refactored,
           model: model,
           project: @default_project,
           location: location
         }}

      "test" ->
        test_code =
          case language do
            "elixir" ->
              """
              defmodule GeneratedTest do
                use ExUnit.Case, async: true

                test "#{file_path} loads cleanly" do
                  assert true
                end
              end
              """
              |> String.trim_trailing()

            _ ->
              """
              describe('#{file_path}', () => {
                it('passes generated test', () => {
                  expect(true).toBe(true);
                });
              });
              """
              |> String.trim_trailing()
          end

        {:ok,
         %{
           text: "Generated unit tests for #{file_path}:\n\n```#{language}\n#{test_code}\n```",
           explanation: "Generated unit tests for #{file_path}.",
           code: test_code,
           model: model,
           project: @default_project,
           location: location
         }}

      _ ->
        updated = "# Updated (#{action}) by #{model}\n" <> code

        {:ok,
         %{
           text: "Applied #{action} to #{file_path}:\n\n```#{language}\n#{updated}\n```",
           explanation: "Applied #{action} to #{file_path}.",
           code: updated,
           model: model,
           project: @default_project,
           location: location
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp resolve_suggested_code(result) do
    case Map.get(result, :code) do
      code when is_binary(code) ->
        trimmed = String.trim(code)
        if trimmed == "", do: extract_code_block(Map.get(result, :text, "")), else: trimmed

      _ ->
        extract_code_block(Map.get(result, :text, ""))
    end
  end

  defp append_unique(list, item) do
    if item in list, do: list, else: list ++ [item]
  end

  defp count_lines(""), do: 1
  defp count_lines(content), do: content |> String.split("\n") |> length()

  defp insert_tree_parts(nodes, [], _prefix, _file), do: nodes

  defp insert_tree_parts(nodes, [name], _prefix, file) do
    if Enum.any?(nodes, &(&1.name == name and not &1.is_dir)) do
      nodes
    else
      nodes ++
        [
          %{
            name: name,
            path: file.path,
            is_dir: false,
            children: [],
            file: file
          }
        ]
    end
  end

  defp insert_tree_parts(nodes, [dir | rest], prefix, file) do
    dir_path = if prefix == "", do: dir, else: "#{prefix}/#{dir}"

    case Enum.find_index(nodes, &(&1.name == dir and &1.is_dir)) do
      nil ->
        new_dir = %{
          name: dir,
          path: dir_path,
          is_dir: true,
          children: insert_tree_parts([], rest, dir_path, file),
          file: nil
        }

        nodes ++ [new_dir]

      idx ->
        List.update_at(nodes, idx, fn node ->
          %{node | children: insert_tree_parts(node.children, rest, dir_path, file)}
        end)
    end
  end

  defp sort_tree_nodes(nodes) do
    nodes
    |> Enum.map(fn node ->
      if node.is_dir do
        %{node | children: sort_tree_nodes(node.children)}
      else
        node
      end
    end)
    |> Enum.sort_by(fn node -> {if(node.is_dir, do: 0, else: 1), node.name} end)
  end
end

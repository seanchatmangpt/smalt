defmodule Smalt.DataPlane.Acr do
  @moduledoc """
  Azure Container Registry (ACR) plane engine (T-01, window v26.10.28).

  Owns the `Microsoft.ContainerRegistry/registries` family: registry records,
  admin credentials, ACR Tasks runs and their recorded synthetic log output.
  The wire seam is `Smalt.ArmGateway.Providers.AcrRouter` — this module is
  deliberately wire-free so the court drives the plane in-process against the
  real store (Chicago discipline: no mocks).

  Store contract: every row lives in `:smalt_resources` under the DOWNCASED
  resource-id key (the generic ARM convention — mirrors how
  `test/integration/sb_arm_rules_test.exs` seeds `:smalt_resources`); the
  wire-case id rides inside the record as `"id"`.

  Run state machine (simulated — NO container execution, README design law):
  a scheduled run stores its queue wall-clock stamp (`_acr_queued_ms`) and
  LAZILY walks Queued → Running (after #{@running_after_ms} ms) → Succeeded
  (after #{@succeeded_after_ms} ms) on the first GET/LIST observation,
  persisting the advanced status. The terminal log line
  ("Run ID: … was successful after Ns") lands exactly when the flip to
  Succeeded is observed, never before. Logs are recorded synthetic step output
  (typology matches real ACR's "Executing step ID: …" lines); step content is
  parsed from the task YAML with YamlElixir (`read_from_string/1`) —
  yaml_elixir is a TRANSITIVE dep today (present and compiled via `reactor`;
  promote to a direct mix.exs entry at integration — see
  docs/jira/v26.10.28/receipts/r14-t01-acr.md). Unknown task-file fields are
  mapped verbatim into the recorded run body under `_acr_task`.

  Private members (`_acr_queued_ms`, `_acr_task`, `logs`) are smalt-side
  state: the router strips them from wire renders (real ACR carries logs
  out-of-band via the run's logLink).

  Divergence (typed, honest dev face): the admin user is always enabled and
  credential material is deterministic sha256 (same values `list_keys/1`
  lists) — never real secret material.
  """

  alias Smalt.Store

  @registry_type "Microsoft.ContainerRegistry/registries"
  @run_type "Microsoft.ContainerRegistry/registries/runs"

  # Metadata DNS suffix (arm_gateway/router.ex:4220 "containerRegistry").
  @dns_suffix "registry.smalt.local"

  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }

  @running_after_ms 300
  @succeeded_after_ms 800

  # ===========================================================================
  # Credentials
  # ===========================================================================

  @doc """
  Admin login seat for a registry account (downcased full resource id).

  Returns `{:ok, %{server: binary, username: binary, password: binary}}` when
  the registry row exists, `:error` otherwise. The server is the registry's
  loginServer on the smalt DNS suffix; the password is the SAME deterministic
  material `list_keys/1` lists under "password" (single source of truth).
  """
  def credentials(account) do
    case get_registry(account) do
      {:ok, record} ->
        name = record["name"]

        {:ok,
         %{
           server: login_server_of(record, name),
           username: name,
           password: password(name)
         }}

      :error ->
        :error
    end
  end

  # ===========================================================================
  # Registry control plane (registries CRUD)
  # ===========================================================================

  @doc """
  PUT a registry account. `account` is the downcased full resource id;
  `attrs` is the decoded PUT body with the wire `"id"` and `"name"` members
  overlaid by the router. Returns `{:ok, record, existed?}` — the router maps
  `existed?` to the idempotent 200/201 faces. Re-PUT preserves the original
  `creationDate` (real ACR PUT update semantics).
  """
  def create_registry(account, attrs) when is_binary(account) and is_map(attrs) do
    key = down(account)
    name = attrs["name"] || name_of(account)
    existing = existing_registry(key)
    existed? = match?({:ok, _}, existing)

    creation_date =
      case existing do
        {:ok, %{"properties" => %{"creationDate" => d}}} when is_binary(d) -> d
        _ -> iso_now()
      end

    sku_name = sku_name(attrs)

    record = %{
      "id" => attrs["id"] || account,
      "name" => name,
      "type" => @registry_type,
      "location" => attrs["location"] || "eastus",
      "tags" => attrs["tags"] || %{},
      "sku" => %{"name" => sku_name, "tier" => sku_name},
      "systemData" => @system_data,
      "properties" => %{
        "adminUserEnabled" => admin_user_enabled?(attrs),
        "creationDate" => creation_date,
        "loginServer" => "#{down(name)}.#{@dns_suffix}",
        "networkRuleSet" => %{
          "defaultAction" => "Allow",
          "virtualNetworkRules" => [],
          "ipRules" => []
        },
        "provisioningState" => "Succeeded"
      }
    }

    Store.put(:smalt_resources, key, record)
    {:ok, record, existed?}
  end

  @doc "`{:ok, record} | :error` for a registry account (downcased id)."
  def get_registry(account) do
    case Store.get(:smalt_resources, down(account)) do
      {:ok, %{"type" => @registry_type} = record} -> {:ok, record}
      _ -> :error
    end
  end

  @doc """
  Deletes a registry account and CASCADES its children (runs, webhooks) by
  key prefix. `:ok` when the registry existed, `:error` when not.
  """
  def delete_registry(account) do
    key = down(account)

    case Store.get(:smalt_resources, key) do
      {:ok, _} ->
        Enum.each(Store.prefix_keys(:smalt_resources, key <> "/"), fn child_key ->
          Store.delete(:smalt_resources, child_key)
        end)

        Store.delete(:smalt_resources, key)
        :ok

      :error ->
        :error
    end
  end

  @doc """
  listKeys face: the real `RegistryListCredentialsResult` wire shape —
  `{"username": …, "passwords": [{"name": "password", …}, {"name": "password2", …}]}`.
  `:error` when the registry account does not exist.
  """
  def list_keys(account) do
    case credentials(account) do
      {:ok, %{username: name, password: primary}} ->
        {:ok,
         %{
           "username" => name,
           "passwords" => [
             %{"name" => "password", "value" => primary},
             %{"name" => "password2", "value" => password2(name)}
           ]
         }}

      :error ->
        :error
    end
  end

  # ===========================================================================
  # ACR Tasks runs (simulated state machine)
  # ===========================================================================

  @doc """
  Schedules a run. `run_id` is the full run resource id
  (`…/registries/<name>/runs/<hex>`); `body` is the decoded scheduleRun
  request (RunRequest). Accepted request types: `FileTaskRunRequest`
  (requires `taskPath`; an inline base64 task file may ride
  `encodedTaskContent` — smalt has no source-control fetch) and
  `EncodedTaskRunRequest` (requires base64 `encodedTaskContent`).

  The task YAML parses through YamlElixir; `{{.Values.<name>}}` placeholders
  substitute from the request's `values` before parsing. Returns
  `{:ok, run_row}` (row includes the private `logs` member) or
  `{:error, code, message}` — codes: `RegistryNotFound` (404 face),
  `ValidationError` / `UnsupportedRunRequestType` / `InvalidEncodedTaskContent`
  / `InvalidTaskContent` (400 face).
  """
  def put_run(run_id, body) when is_binary(run_id) do
    key = down(run_id)

    with {:ok, creds} <- require_credentials(registry_account_of(run_id)),
         {:ok, spec} <- run_request_spec(body),
         {:ok, task} <- parse_task_spec(spec, body) do
      record = build_run(run_id, creds, body, spec, task)
      Store.put(:smalt_resources, key, record)
      {:ok, record}
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  @doc """
  `{:ok, run_row} | :error`, with the state machine ADVANCED to the status the
  clock says (Queued → Running → Succeeded) and the advanced row persisted.
  """
  def get_run(run_id) do
    key = down(run_id)

    case Store.get(:smalt_resources, key) do
      {:ok, %{"type" => @run_type} = row} -> {:ok, advance_run(key, row)}
      _ -> :error
    end
  end

  @doc """
  Every run row in the store, each state-advanced (and persisted) in key
  order. The router prefix-filters per registry.
  """
  def list_runs do
    Store.prefix_keys(:smalt_resources, "/")
    |> Enum.flat_map(fn key ->
      case Store.get(:smalt_resources, key) do
        {:ok, %{"type" => @run_type} = row} -> [advance_run(key, row)]
        _ -> []
      end
    end)
  end

  @doc """
  Appends a line to the run's recorded log transcript.
  `{:ok, run_row} | :error`.
  """
  def append_log(run_id, line) when is_binary(run_id) and is_binary(line) do
    key = down(run_id)

    case Store.get(:smalt_resources, key) do
      {:ok, %{"type" => @run_type} = row} ->
        row = Map.update(row, "logs", [line], &(&1 ++ [line]))
        Store.put(:smalt_resources, key, row)
        {:ok, row}

      _ ->
        :error
    end
  end

  # ===========================================================================
  # Run request validation
  # ===========================================================================

  defp run_request_spec(body) when is_map(body) do
    case body["type"] do
      "FileTaskRunRequest" -> file_task_spec(body)
      "EncodedTaskRunRequest" -> encoded_task_spec(body)

      nil ->
        {:error, "ValidationError",
         "The runRequest 'type' member is required (FileTaskRunRequest | EncodedTaskRunRequest)."}

      other ->
        {:error, "UnsupportedRunRequestType",
         "Run request type '#{other}' is not supported; smalt accepts " <>
           "FileTaskRunRequest and EncodedTaskRunRequest (no container execution)."}
    end
  end

  defp run_request_spec(_),
    do: {:error, "ValidationError", "The request body must be a runRequest object."}

  defp file_task_spec(body) do
    case binary_member(body, "taskPath") do
      nil ->
        {:error, "ValidationError",
         "FileTaskRunRequest requires a non-empty string 'taskPath' member."}

      task_path ->
        # The task FILE itself rides an inline base64 copy under the family's
        # 'encodedTaskContent' member when the caller wants parsed steps —
        # smalt has no source-control fetch (ticket non-goal). Absent content
        # simulates against the taskPath alone (no parsed steps).
        case optional_encoded_content(body) do
          {:ok, content} -> {:ok, %{run_type: "FileTask", content: content, task_path: task_path}}
          error -> error
        end
    end
  end

  defp encoded_task_spec(body) do
    case binary_member(body, "encodedTaskContent") do
      nil ->
        {:error, "ValidationError",
         "EncodedTaskRunRequest requires a non-empty base64 string 'encodedTaskContent' member."}

      encoded ->
        case Base.decode64(encoded) do
          {:ok, content} -> {:ok, %{run_type: "EncodedTask", content: content, task_path: nil}}
          :error -> {:error, "InvalidEncodedTaskContent", "The 'encodedTaskContent' member is not valid base64."}
        end
    end
  end

  defp optional_encoded_content(body) do
    case binary_member(body, "encodedTaskContent") do
      nil -> {:ok, nil}
      encoded ->
        case Base.decode64(encoded) do
          {:ok, content} -> {:ok, content}
          :error -> {:error, "InvalidEncodedTaskContent", "The 'encodedTaskContent' member is not valid base64."}
        end
    end
  end

  # Task YAML: values substitution -> YamlElixir parse -> step extraction.
  defp parse_task_spec(%{content: nil}, _body), do: {:ok, %{steps: [], raw: nil}}

  defp parse_task_spec(%{content: content}, body) do
    substituted = apply_values(content, values_of(body))

    case YamlElixir.read_from_string(substituted) do
      {:ok, parsed} -> {:ok, %{steps: steps_of(parsed), raw: parsed}}

      {:error, reason} ->
        {:error, "InvalidTaskContent", "The task YAML could not be parsed: #{inspect(reason)}"}
    end
  end

  defp values_of(body) do
    case body["values"] do
      values when is_list(values) ->
        Enum.flat_map(values, fn
          %{"name" => name, "value" => value} when is_binary(name) -> [{name, value}]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp apply_values(content, values) do
    Enum.reduce(values, content, fn {name, value}, acc ->
      String.replace(acc, "{{.Values.#{name}}}", to_string(value))
    end)
  end

  # Steps: the common ACR task-file shape ("steps:" list with id + one of
  # build/push/cmd/task/login/logout). Tolerated fields: id carries the step
  # id; the first recognized verb key carries the command detail; unknown
  # fields ride into the recorded raw body (_acr_task) and the log detail.
  @step_verbs ["build", "push", "cmd", "task", "login", "logout"]

  defp steps_of(%{"steps" => steps}) when is_list(steps), do: Enum.map(steps, &step_pair/1)
  defp steps_of(_), do: []

  defp step_pair(step) when is_map(step) do
    verb = Enum.find(@step_verbs, fn v -> is_binary(step[v]) or is_list(step[v]) end)
    id = step["id"] || verb || "step"
    detail = step[verb] || Map.delete(step, "id")
    {to_string(id), render_detail(detail)}
  end

  defp step_pair(step), do: {to_string(step), inspect(step)}

  defp render_detail(detail) when is_binary(detail), do: detail
  defp render_detail(detail), do: inspect(detail)

  # ===========================================================================
  # Run record build + state machine
  # ===========================================================================

  defp build_run(run_id, creds, body, spec, task) do
    run_name = name_of(run_id)
    ts = ts_now()

    step_lines =
      task.steps
      |> Enum.flat_map(fn {id, detail} ->
        [
          "#{ts} Executing step ID: #{id}. #{detail}",
          "#{ts} Step ID: #{id} elapsed: 00:00:00 (simulated)"
        ]
      end)

    header = "#{ts} Queued run #{run_name} on #{creds.server} (#{spec.run_type})"
    logs = [header | step_lines]

    %{
      "id" => run_id,
      "name" => run_name,
      "type" => @run_type,
      "systemData" => @system_data,
      # smalt-private state (stripped from wire renders by the router):
      "_acr_queued_ms" => System.system_time(:millisecond),
      # Recorded run body: parsed task steps + unknown YAML fields verbatim.
      "_acr_task" => %{
        "runType" => spec.run_type,
        "taskPath" => spec.task_path,
        "steps" => task.raw || %{},
        "values" => values_of(body)
      },
      "logs" => logs,
      "properties" => %{
        "runId" => run_name,
        "runType" => spec.run_type,
        "status" => "Queued",
        "createTime" => iso_now(),
        "startTime" => nil,
        "finishTime" => nil,
        "lastUpdateTime" => iso_now(),
        "platform" => platform_of(body),
        "timeout" => timeout_of(body),
        "isArchiveEnabled" => body["isArchiveEnabled"] == true,
        # credentials/1 seat — the logLink lives on the registry login server.
        "logLink" => "https://#{creds.server}/runlogs/#{run_name}",
        "errorMessage" => nil
      }
    }
  end

  # Lazy Queued -> Running -> Succeeded advance on read; persisted only on a
  # status change (terminal rows are read-only after the flip).
  defp advance_run(key, row) do
    now_ms = System.system_time(:millisecond)
    queued = row["_acr_queued_ms"]
    props = row["properties"] || %{}
    current = props["status"]

    {next, flip} =
      cond do
        not is_integer(queued) ->
          # A row minted outside put_run/2 never advances — fail-stable Queued.
          {current || "Queued", :none}

        now_ms - queued >= @succeeded_after_ms ->
          {"Succeeded", :finish}

        now_ms - queued >= @running_after_ms ->
          {"Running", :start}

        true ->
          {"Queued", :none}
      end

    if next == current do
      row
    else
      props =
        props
        |> Map.put("status", next)
        |> Map.put("lastUpdateTime", iso_now())
        |> fill_time("startTime", flip in [:start, :finish])
        |> fill_time("finishTime", flip == :finish)

      row =
        row
        |> Map.put("properties", props)
        |> maybe_append_terminal_log(next, queued)

      Store.put(:smalt_resources, key, row)
      row
    end
  end

  # Fill lifecycle timestamps at the flip observation, never overwriting a
  # previously recorded value (a run observed Running then Succeeded keeps its
  # original startTime).
  defp fill_time(props, _member, false), do: props

  defp fill_time(props, member, true) do
    case Map.get(props, member) do
      nil -> Map.put(props, member, iso_now())
      _ -> props
    end
  end

  defp maybe_append_terminal_log(row, "Succeeded", queued) when is_integer(queued) do
    secs = div(System.system_time(:millisecond) - queued, 1000)
    line = "#{ts_now()} Run ID: #{row["name"]} was successful after #{secs}s"
    Map.update(row, "logs", [line], &(&1 ++ [line]))
  end

  defp maybe_append_terminal_log(row, _status, _queued), do: row

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp require_credentials(account) do
    case credentials(account) do
      {:ok, creds} ->
        {:ok, creds}

      :error ->
        {:error, "RegistryNotFound",
         "The registry '#{account}' could not be found; schedule its run through " <>
           "an existing Microsoft.ContainerRegistry/registries account."}
    end
  end

  defp existing_registry(key) do
    case Store.get(:smalt_resources, key) do
      {:ok, %{"type" => @registry_type} = record} -> {:ok, record}
      _ -> :error
    end
  end

  defp sku_name(attrs) do
    case attrs["sku"] do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> "Basic"
    end
  end

  defp admin_user_enabled?(attrs) do
    case attrs["properties"] do
      %{"adminUserEnabled" => value} when is_boolean(value) -> value
      _ -> true
    end
  end

  defp login_server_of(record, name) do
    case record["properties"] do
      %{"loginServer" => server} when is_binary(server) -> server
      _ -> "#{down(name)}.#{@dns_suffix}"
    end
  end

  # Deterministic dev-mode credential material (mirrors the SB authorization
  # rule derivation style in arm_gateway/router.ex handle_authorization_rule_list_keys).
  defp password(name), do: Base.encode64(:crypto.hash(:sha256, "acr/#{name}/password"))
  defp password2(name), do: Base.encode64(:crypto.hash(:sha256, "acr/#{name}/password2"))

  defp platform_of(body) do
    case body["platform"] do
      %{"os" => os} = platform when is_binary(os) ->
        case platform["architecture"] do
          arch when is_binary(arch) -> %{"os" => os, "architecture" => arch}
          _ -> %{"os" => os}
        end

      _ ->
        %{"os" => "Linux"}
    end
  end

  defp timeout_of(body) do
    case body["timeout"] do
      t when is_integer(t) and t > 0 -> t
      _ -> 3600
    end
  end

  defp binary_member(body, key) do
    case body[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # "…/registries/<name>/runs/<run>" -> the registry account (downcased by
  # credentials/1 internally).
  defp registry_account_of(run_id) do
    case String.split(run_id, "/runs/") do
      [prefix | _] -> prefix
      _ -> run_id
    end
  end

  defp down(value) when is_binary(value), do: String.downcase(value)
  defp name_of(id), do: id |> String.split("/") |> List.last()

  defp iso_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # ACR log timestamps render "YYYY/MM/DD HH:MM:SS" (real acr-run log typology).
  defp ts_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> Calendar.strftime("%Y/%m/%d %H:%M:%S")
  end
end

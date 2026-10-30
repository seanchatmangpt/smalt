defmodule Smalt.ArmGateway.Providers.AcrRouter do
  @moduledoc """
  Wire seam for the Microsoft.ContainerRegistry family (T-01, window
  v26.10.28) — a PASS-THROUGH Plug mounted in the ArmGateway.Router pipeline:
  every conn the ACR plane owns is answered here and handed to the client;
  every other conn returns UNCHANGED so the rest of the pipeline composes
  unaffected (mount point: receipts/r14-t01-acr.md — immediately before
  `plug(:match)`).

  Surfaces (all dispatched via `Smalt.DataPlane.Acr` against the real store):

  - ARM `Microsoft.ContainerRegistry/registries` CRUD: PUT (201 create /
    200 idempotent re-put), GET echo, GET LIST (resource-group scope),
    DELETE (typed 202 LRO — Azure-AsyncOperation/Location/Retry-After —
    completing through the real `Smalt.ArmGateway.LRO` seam).
  - POST `…/registries/:name/listKeys` (plus the real-API `listCredentials`
    alias): RegistryListCredentialsResult shape from credentials/1.
  - ACR Tasks: POST `…/registries/:name/scheduleRun` (FileTaskRunRequest /
    EncodedTaskRunRequest, 201 with the run in Queued), GET
    `…/runs/:run` (poll face: Queued → Running → Succeeded), GET `…/runs`
    (LIST), GET `…/runs/:run/logs` (text stream — the logLink target face,
    the run's recorded synthetic log output).
  - Registry webhooks CRUD (child resources under the registry, stored on the
    downcased resource-id key convention).
  - Registry data-plane metadata, simulated (ticket scope item 2) and mounted
    under `/acr/:registry/v2`: GET `/v2/_catalog` and GET
    `/v2/:repo/tags/list` read the blob-backed store (repositories = blob
    containers of the registry-named account, tags = blob names), gated by
    docker Basic auth against `credentials/1` (401 challenge, docker error
    envelopes).

  api-version: the ACR plane requires the parameter's PRESENCE (typed 400
  MissingApiVersionParameter) AND monotonic admission against the registered
  family top (KD-78, via `Smalt.ArmGateway.Plug.Common.check_api_version/2`):
  `Microsoft.ContainerRegistry/registries` and `…/webhooks` are Registry
  individuals with latest 2023-06-01, so any version whose date base is <=
  2023-06-01 is admitted (including `YYYY-MM` bases like "2023-06-preview",
  normalized via version_base) and anything above is refused with the SAME
  typed 400 InvalidApiVersionParameter envelope the generic face emits
  (message names the latest supported version). /acr/v2 is the docker data
  plane and carries no api-version.
  """

  import Plug.Conn

  alias Smalt.ArmGateway.LRO
  alias Smalt.ArmGateway.Plug.Common
  alias Smalt.DataPlane.Acr
  alias Smalt.Store

  @registry_type "Microsoft.ContainerRegistry/registries"
  @webhook_type "Microsoft.ContainerRegistry/registries/webhooks"

  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }

  def init(opts), do: opts || []

  # ===========================================================================
  # Pass-through dispatch: match path_info/method; non-ACR conns return
  # UNCHANGED (no fetch_query_params, no body read) so the pipeline composes.
  # ===========================================================================

  def call(conn, _opts) do
    case own?(conn) do
      nil ->
        conn

      {:arm, [sub, _rg_seg, rg | rest]} ->
        handle_arm(conn, String.downcase(to_string(conn.method)), sub, rg, rest)

      {:v2, [name | rest]} ->
        handle_v2(conn, String.downcase(to_string(conn.method)), name, rest)
    end
  end

  defp own?(conn) do
    case conn.path_info do
      ["subscriptions", sub, rg_seg, rg, "providers", ns | rest]
      when rg_seg in ["resourceGroups", "resourcegroups"] and
             ns in ["Microsoft.ContainerRegistry", "microsoft.containerregistry"] ->
        {:arm, [sub, rg_seg, rg | rest]}

      ["acr", name, "v2" | rest] ->
        {:v2, [name | rest]}

      _ ->
        nil
    end
  end

  # ===========================================================================
  # ARM surface
  # ===========================================================================

  defp handle_arm(conn, method, sub, rg, rest) do
    conn = Plug.Conn.fetch_query_params(conn)

    case {method, rest} do
      {m, ["registries", name]} when m in ["put", "get", "delete"] ->
        case m do
          "put" -> registry_put(conn, sub, rg, name)
          "get" -> registry_get(conn, sub, rg, name)
          "delete" -> registry_delete(conn, sub, rg, name)
        end

      {"get", ["registries"]} ->
        registries_list(conn, sub, rg)

      {"post", ["registries", name, "scheduleRun"]} ->
        schedule_run(conn, sub, rg, name)

      {m, ["registries", name, action]} when m == "post" ->
        # listKeys (ticket vocabulary) + the real-API listCredentials alias;
        # any other ACR-namespaced POST passes through UNCHANGED.
        if is_list_keys_action?(action) do
          registry_list_keys(conn, sub, rg, name)
        else
          conn
        end

      {"get", ["registries", name, "runs"]} ->
        runs_list(conn, sub, rg, name)

      {"get", ["registries", name, "runs", run]} ->
        run_show(conn, sub, rg, name, run)

      {"get", ["registries", name, "runs", run, "logs"]} ->
        run_logs(conn, sub, rg, name, run)

      {"get", ["registries", name, "webhooks"]} ->
        webhooks_list(conn, sub, rg, name)

      {m, ["registries", name, "webhooks", hook]} when m in ["put", "get", "delete"] ->
        case m do
          "put" -> webhook_put(conn, sub, rg, name, hook)
          "get" -> webhook_get(conn, sub, rg, name, hook)
          "delete" -> webhook_delete(conn, sub, rg, name, hook)
        end

      # An ACR-namespaced path this router does not own: pass through UNCHANGED
      # (the pipeline's generic provider routes / catch-all still see it).
      _ ->
        conn
    end
  end

  defp is_list_keys_action?(action), do: String.downcase(action) in ["listkeys", "listcredentials"]

  # -- registries CRUD ---------------------------------------------------------

  defp registry_put(conn, sub, rg, name) do
    with :ok <- require_api_version(conn, @registry_type),
         {:ok, body} <- body_params(conn) do
      reg_id = registry_id(sub, rg, name)
      attrs = Map.merge(body, %{"id" => reg_id, "name" => String.downcase(name)})

      # create is 201; the idempotent re-put is the ARM 200 face.
      case Acr.create_registry(String.downcase(reg_id), attrs) do
        {:ok, record, existed?} -> send_json(conn, if(existed?, do: 200, else: 201), record)
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp registry_get(conn, sub, rg, name) do
    with :ok <- require_api_version(conn, @registry_type) do
      reg_id = registry_id(sub, rg, name)

      case Store.get(:smalt_resources, String.downcase(reg_id)) do
        {:ok, %{"type" => @registry_type} = record} ->
          send_json(conn, 200, record)

        _ ->
          send_arm_error(conn, 404, "ResourceNotFound", "The Resource '#{name}' was not found.", reg_id)
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp registry_delete(conn, sub, rg, name) do
    with :ok <- require_api_version(conn, @registry_type) do
      reg_id = registry_id(sub, rg, name)

      case Acr.delete_registry(String.downcase(reg_id)) do
        :ok ->
          # Typed 202 LRO face (DoD): the delete is already applied; the
          # operation completes through the real LRO seam (poll to terminal).
          op = LRO.start_op(reg_id)
          async_response(conn, 202, op)

        :error ->
          send_arm_error(conn, 404, "ResourceNotFound", "The Resource '#{name}' was not found.", reg_id)
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp registries_list(conn, sub, rg) do
    with :ok <- require_api_version(conn, @registry_type) do
      prefix =
        String.downcase(
          "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.ContainerRegistry/registries/"
        )

      registries =
        Store.list_prefix(:smalt_resources, prefix)
        |> Enum.filter(fn row -> is_map(row) and row["type"] == @registry_type end)

      send_json(conn, 200, %{"value" => registries})
    else
      {:respond, conn} -> conn
    end
  end

  defp registry_list_keys(conn, sub, rg, name) do
    with :ok <- require_api_version(conn, @registry_type) do
      reg_id = registry_id(sub, rg, name)

      case Acr.list_keys(String.downcase(reg_id)) do
        {:ok, creds} -> send_json(conn, 200, creds)
        :error -> send_arm_error(conn, 404, "ResourceNotFound", "The Resource '#{name}' was not found.", reg_id)
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- ACR Tasks runs -----------------------------------------------------------

  defp schedule_run(conn, sub, rg, name) do
    with :ok <- require_api_version(conn, @registry_type),
         {:ok, request} <- body_params(conn) do
      reg_id = registry_id(sub, rg, name)
      run_id = "#{reg_id}/runs/#{mint_run_name()}"

      case Acr.put_run(run_id, request) do
        {:ok, row} -> send_json(conn, 201, render_run(row))
        {:error, code, message} -> send_arm_error(conn, error_status(code), code, message, reg_id)
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp run_show(conn, sub, rg, name, run) do
    with :ok <- require_api_version(conn, @registry_type) do
      run_id = "#{registry_id(sub, rg, name)}/runs/#{run}"

      case Acr.get_run(run_id) do
        {:ok, row} -> send_json(conn, 200, render_run(row))
        :error -> send_arm_error(conn, 404, "ResourceNotFound", "The run '#{run}' could not be found.", run_id)
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp runs_list(conn, sub, rg, name) do
    with :ok <- require_api_version(conn, @registry_type),
         {:ok, _reg} <- registry_row(sub, rg, name) do
      prefix = String.downcase(registry_id(sub, rg, name)) <> "/runs/"

      runs =
        Acr.list_runs()
        |> Enum.filter(fn row -> String.downcase(row["id"] || "") |> String.starts_with?(prefix) end)
        |> Enum.map(&render_run/1)

      send_json(conn, 200, %{"value" => runs})
    else
      {:respond, conn} -> conn
      :error -> send_arm_error(conn, 404, "ResourceNotFound", "The parent #{name} could not be found.")
    end
  end

  # The logLink target face: the run's recorded synthetic log output as a
  # text stream (real ACR streams logs out-of-band as plain text).
  defp run_logs(conn, sub, rg, name, run) do
    with :ok <- require_api_version(conn, @registry_type) do
      run_id = "#{registry_id(sub, rg, name)}/runs/#{run}"

      case Acr.get_run(run_id) do
        {:ok, %{"logs" => logs}} when is_list(logs) ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, Enum.join(logs, "\n"))

        {:ok, _row} ->
          send_resp(conn, 200, "")

        :error ->
          send_arm_error(conn, 404, "ResourceNotFound", "The run '#{run}' could not be found.", run_id)
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- webhooks -----------------------------------------------------------------

  defp webhook_put(conn, sub, rg, name, hook) do
    with :ok <- require_api_version(conn, @webhook_type),
         {:ok, body} <- body_params(conn),
         {:ok, reg} <- registry_row(sub, rg, name) do
      reg_id = registry_id(sub, rg, name)
      hook_key = String.downcase("#{reg_id}/webhooks/#{hook}")
      existed? = match?({:ok, _}, Store.get(:smalt_resources, hook_key))
      props = body["properties"] || %{}

      record = %{
        "id" => "#{reg_id}/webhooks/#{hook}",
        "name" => hook,
        "type" => @webhook_type,
        "location" => body["location"] || reg["location"] || "eastus",
        "tags" => body["tags"] || %{},
        "systemData" => @system_data,
        "properties" => %{
          "actions" => props["actions"] || ["push", "delete"],
          "provisioningState" => "Succeeded",
          "scope" => props["scope"] || "*",
          "status" => props["status"] || "enabled"
        }
      }

      Store.put(:smalt_resources, hook_key, record)
      send_json(conn, if(existed?, do: 200, else: 201), record)
    else
      {:respond, conn} -> conn
      :error -> send_arm_error(conn, 404, "ResourceNotFound", "The parent #{name} could not be found.")
    end
  end

  defp webhook_get(conn, sub, rg, name, hook) do
    with :ok <- require_api_version(conn, @webhook_type),
         {:ok, _reg} <- registry_row(sub, rg, name) do
      hook_key = String.downcase("#{registry_id(sub, rg, name)}/webhooks/#{hook}")

      case Store.get(:smalt_resources, hook_key) do
        {:ok, %{"type" => @webhook_type} = record} ->
          send_json(conn, 200, record)

        _ ->
          send_arm_error(conn, 404, "ResourceNotFound", "The Webhook '#{hook}' was not found.")
      end
    else
      {:respond, conn} -> conn
      :error -> send_arm_error(conn, 404, "ResourceNotFound", "The parent #{name} could not be found.")
    end
  end

  defp webhook_delete(conn, sub, rg, name, hook) do
    with :ok <- require_api_version(conn, @webhook_type),
         {:ok, _reg} <- registry_row(sub, rg, name) do
      hook_key = String.downcase("#{registry_id(sub, rg, name)}/webhooks/#{hook}")

      case Store.get(:smalt_resources, hook_key) do
        {:ok, %{"type" => @webhook_type}} ->
          :ok = Store.delete(:smalt_resources, hook_key)
          send_json(conn, 200, %{})

        _ ->
          send_arm_error(conn, 404, "ResourceNotFound", "The Webhook '#{hook}' was not found.")
      end
    else
      {:respond, conn} -> conn
      :error -> send_arm_error(conn, 404, "ResourceNotFound", "The parent #{name} could not be found.")
    end
  end

  defp webhooks_list(conn, sub, rg, name) do
    with :ok <- require_api_version(conn, @webhook_type),
         {:ok, _reg} <- registry_row(sub, rg, name) do
      prefix = String.downcase(registry_id(sub, rg, name)) <> "/webhooks/"

      hooks =
        Store.list_prefix(:smalt_resources, prefix)
        |> Enum.filter(fn row -> is_map(row) and row["type"] == @webhook_type end)

      send_json(conn, 200, %{"value" => hooks})
    else
      {:respond, conn} -> conn
      :error -> send_arm_error(conn, 404, "ResourceNotFound", "The parent #{name} could not be found.")
    end
  end

  # ===========================================================================
  # Data-plane metadata surface (simulated): /acr/:registry/v2
  # ===========================================================================

  defp handle_v2(conn, method, name, rest) do
    conn = Plug.Conn.fetch_query_params(conn)

    case {method, rest} do
      {"get", ["_catalog"]} ->
        v2_catalog(conn, name)

      {"get", repo_segs} ->
        repo_parts = Enum.drop(repo_segs, -2)

        case Enum.take(repo_segs, -2) do
          ["tags", "list"] when repo_parts != [] -> v2_tags(conn, name, Enum.join(repo_parts, "/"))
          _ -> conn
        end

      _ ->
        conn
    end
  end

  defp v2_catalog(conn, name) do
    with {:ok, account} <- authenticate_registry(conn, name) do
      repos =
        Store.prefix_keys(:smalt_blob_containers, account <> "/")
        |> Enum.map(fn key -> String.slice(key, byte_size(account) + 1, 100_000) end)
        |> Enum.uniq()
        |> Enum.sort()

      send_json(conn, 200, %{"repositories" => repos})
    else
      {:respond, conn} -> conn
    end
  end

  defp v2_tags(conn, name, repo) do
    with {:ok, account} <- authenticate_registry(conn, name) do
      prefix = "#{account}/#{repo}/"

      tags =
        Store.prefix_keys(:smalt_blobs, prefix)
        |> Enum.map(fn key -> String.slice(key, byte_size(prefix), 100_000) end)
        |> Enum.sort()

      send_json(conn, 200, %{"name" => repo, "tags" => tags})
    else
      {:respond, conn} -> conn
    end
  end

  # Order: the registry seat resolves FIRST (docker 404 NAME_UNKNOWN), then the
  # docker Basic challenge against credentials/1 (401 UNAUTHORIZED).
  defp authenticate_registry(conn, name) do
    case registry_by_name(name) do
      {:ok, reg} ->
        case Acr.credentials(String.downcase(reg["id"] || "")) do
          {:ok, creds} ->
            if basic_auth_matches?(conn, creds) do
              {:ok, String.downcase(reg["name"])}
            else
              {:respond, unauthorized(conn, reg)}
            end

          :error ->
            {:respond, unauthorized(conn, reg)}
        end

      :error ->
        {:respond, name_unknown(conn, name)}
    end
  end

  # ACR registry names are globally unique in real Azure (they ARE the
  # loginServer seat); smalt resolves by name across :smalt_resources.
  defp registry_by_name(name) do
    Store.list(:smalt_resources)
    |> Enum.find(:error, fn
      %{"type" => @registry_type, "name" => n} -> String.downcase(n) == String.downcase(name)
      _ -> false
    end)
    |> case do
      :error -> :error
      reg -> {:ok, reg}
    end
  end

  defp basic_auth_matches?(conn, %{username: username, password: password}) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] ->
        case Base.decode64(encoded) do
          {:ok, pair} -> pair == "#{username}:#{password}"
          :error -> false
        end

      _ ->
        false
    end
  end

  defp unauthorized(conn, reg) do
    server =
      case reg["properties"] do
        %{"loginServer" => s} when is_binary(s) -> s
        _ -> "#{reg["name"]}.registry.smalt.local"
      end

    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="#{server}"))
    |> send_json(401, %{
      "errors" => [
        %{
          "code" => "UNAUTHORIZED",
          "message" => "authentication required; docker login with the credentials from listKeys"
        }
      ]
    })
  end

  defp name_unknown(conn, name) do
    send_json(conn, 404, %{
      "errors" => [
        %{"code" => "NAME_UNKNOWN", "message" => "registry '#{name}' is not known to smalt"}
      ]
    })
  end

  # ===========================================================================
  # Shared helpers
  # ===========================================================================

  # KD-78 monotonic gate, delegated to the shared family seam: presence
  # (MissingApiVersionParameter) + value admission against the Registry top
  # (InvalidApiVersionParameter, identical envelope to the generic face).
  defp require_api_version(conn, type) do
    Common.check_api_version(conn, type)
  end

  # In the mounted pipeline Plug.Parsers already decoded the body into
  # body_params; the court (and any standalone seat) hands the raw binary
  # through instead — decode via the JsonCompat seam either way.
  defp body_params(conn) do
    case conn.body_params do
      params when is_map(params) ->
        {:ok, params}

      raw when is_binary(raw) and raw != "" ->
        case Smalt.JsonCompat.decode(raw) do
          {:ok, %{} = map} -> {:ok, map}
          {:ok, _non_map} -> {:respond, send_arm_error(conn, 400, "InvalidRequestBody", "The request body must be a JSON object.")}
          {:error, _reason} -> {:respond, send_arm_error(conn, 400, "InvalidRequestBody", "The request body could not be decoded as JSON.")}
        end

      _ ->
        {:ok, %{}}
    end
  end

  defp error_status("RegistryNotFound"), do: 404
  defp error_status(_), do: 400

  defp registry_row(sub, rg, name) do
    case Acr.get_registry(String.downcase(registry_id(sub, rg, name))) do
      {:ok, record} -> {:ok, record}
      :error -> :error
    end
  end

  defp registry_id(sub, rg, name) do
    "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.ContainerRegistry/registries/#{name}"
  end

  # Real ACR run ids are opaque hex.
  defp mint_run_name, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # Strip the smalt-private members (real ACR carries logs out-of-band and
  # never exposes scheduling internals on the run resource).
  defp render_run(row), do: Map.drop(row, ["logs", "_acr_queued_ms", "_acr_task"])

  # LRO async face (mirrors arm_gateway/router.ex async_put_response): polling
  # URLs resolve from the client's seat via the request authority.
  defp async_response(conn, status, op) do
    authority = Smalt.Auth.Bearer.request_authority(conn)

    conn
    |> put_resp_header("azure-asyncoperation", "#{authority}#{op["id"]}")
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(status, op)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_arm_error(conn, status, code, message, target \\ nil) do
    error =
      if target do
        %{
          "code" => code,
          "message" => message,
          "target" => target,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest.
          "innererror" => %{}
        }
      else
        %{"code" => code, "message" => message, "innererror" => %{}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => error}))
  end
end

defmodule Smalt.ArmGateway.Providers.ContainerAppsRouter do
  @moduledoc """
  Pass-through provider plug for the ARM `Microsoft.App` runtime plane
  (lane S2, v26.10.29). Same composition as the T-10 ContainerGroupsRouter:
  mounted BEFORE `plug(:match)`, answers the containerApps +
  managedEnvironments path shapes via
  `Smalt.ArmGateway.Providers.ContainerApps`, returns the conn UNCHANGED
  for any other path. Every answer HALTS; api-version is gated against the
  real Microsoft.App GA ladder the engine pins (latest 2023-05-01).
  App/env DELETE is the ARM LRO face (202 + Location + Retry-After);
  `listLogs` answers the typed `NotSupportedOnSubstrate` refusal.
  """

  @behaviour Plug

  alias Smalt.ArmGateway.LRO
  alias Smalt.ArmGateway.Providers.ContainerApps

  @page_size 100

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: path} = conn, _opts) do
    case shape(Enum.map(path, &String.downcase/1), path) do
      nil -> conn
      shape -> dispatch(conn, shape)
    end
  end

  def call(conn, _opts), do: conn

  # --- path shapes ---------------------------------------------------------------------

  defp shape(
         ["subscriptions", _sub, "resourcegroups", _rg, "providers", "microsoft.app", "containerapps" | _rest],
         orig
       ) do
    {:rg_apps, Enum.at(orig, 1), Enum.at(orig, 3), Enum.slice(orig, 7..-1//1)}
  end

  defp shape(
         ["subscriptions", _sub, "resourcegroups", _rg, "providers", "microsoft.app", "managedenvironments" | _rest],
         orig
       ) do
    {:rg_envs, Enum.at(orig, 1), Enum.at(orig, 3), Enum.slice(orig, 7..-1//1)}
  end

  defp shape(["subscriptions", _sub, "providers", "microsoft.app", "containerapps"], orig) do
    {:sub_apps, Enum.at(orig, 1)}
  end

  defp shape(["subscriptions", _sub, "providers", "microsoft.app", "managedenvironments"], orig) do
    {:sub_envs, Enum.at(orig, 1)}
  end

  defp shape(_down, _orig), do: nil

  # --- dispatch ---------------------------------------------------------------------------

  defp dispatch(conn, {:rg_apps, sub, rg, rest}) do
    conn = Plug.Conn.fetch_query_params(conn)

    case rest do
      [] ->
        if conn.method == "GET",
          do: api_gate(conn, fn c -> send_list(c, ContainerApps.list_apps(sub, rg)) end),
          else: method_not_allowed(conn)

      [name] ->
        case conn.method do
          "PUT" -> api_gate(conn, fn c -> put_app(c, sub, rg, name) end)
          "PATCH" -> api_gate(conn, fn c -> patch_app(c, sub, rg, name) end)
          "GET" -> api_gate(conn, fn c -> get_app(c, sub, rg, name) end)
          "DELETE" -> api_gate(conn, fn c -> delete_app(c, sub, rg, name) end)
          _ -> method_not_allowed(conn)
        end

      [name, "listlogs"] ->
        if conn.method == "POST",
          do: api_gate(conn, fn c -> list_logs(c, sub, rg, name) end),
          else: method_not_allowed(conn)

      [name, "revisions" | r] ->
        revisions(conn, sub, rg, name, r)

      _ ->
        arm_error(conn, 404, "ResourceNotFound",
          "The requested containerApps resource shape is not served by this control plane.",
          conn.request_path)
    end
  end

  defp dispatch(conn, {:rg_envs, sub, rg, rest}) do
    conn = Plug.Conn.fetch_query_params(conn)

    case rest do
      [] ->
        if conn.method == "GET",
          do: api_gate(conn, fn c -> send_list(c, ContainerApps.list_envs(sub, rg)) end),
          else: method_not_allowed(conn)

      [env] ->
        case conn.method do
          "PUT" -> api_gate(conn, fn c -> put_env(c, sub, rg, env) end)
          "GET" -> api_gate(conn, fn c -> get_env(c, sub, rg, env) end)
          "DELETE" -> api_gate(conn, fn c -> delete_env(c, sub, rg, env) end)
          _ -> method_not_allowed(conn)
        end

      [env, "certificates" | r] ->
        certificates(conn, sub, rg, env, r, :cert)

      [env, "managedcertificates" | r] ->
        certificates(conn, sub, rg, env, r, :managed_cert)

      _ ->
        arm_error(conn, 404, "ResourceNotFound",
          "The requested managedEnvironments resource shape is not served by this control plane.",
          conn.request_path)
    end
  end

  defp dispatch(conn, {:sub_apps, sub}) do
    conn = Plug.Conn.fetch_query_params(conn)

    if conn.method == "GET",
      do: api_gate(conn, fn c -> send_list(c, ContainerApps.list_apps_subscription(sub)) end),
      else: method_not_allowed(conn)
  end

  defp dispatch(conn, {:sub_envs, sub}) do
    conn = Plug.Conn.fetch_query_params(conn)

    if conn.method == "GET",
      do: api_gate(conn, fn c -> send_list(c, ContainerApps.list_envs_subscription(sub)) end),
      else: method_not_allowed(conn)
  end

  # --- app verbs -----------------------------------------------------------------------------

  defp revisions(conn, sub, rg, name, []) do
    if conn.method == "GET",
      do: api_gate(conn, fn c -> send_list(c, ContainerApps.list_revisions(sub, rg, name)) end),
      else: method_not_allowed(conn)
  end

  defp revisions(conn, sub, rg, name, [rev]) do
    if conn.method == "GET",
      do:
        api_gate(conn, fn c ->
          case ContainerApps.get_revision(sub, rg, name, rev) do
            {:ok, revision} -> send_json(c, 200, revision)
            :error -> not_found(c, ContainerApps.app_wire_id(sub, rg, name) <> "/revisions/" <> rev)
          end
        end),
      else: method_not_allowed(conn)
  end

  defp revisions(conn, sub, rg, name, [rev, action]) when action in ["restart", "activate", "deactivate"] do
    if conn.method == "POST",
      do: api_gate(conn, fn c -> revision_action(c, sub, rg, name, rev, action) end),
      else: method_not_allowed(conn)
  end

  defp revisions(conn, sub, rg, name, [rev, "replicas"]) do
    if conn.method == "GET",
      do:
        api_gate(conn, fn c ->
          case ContainerApps.list_replicas(sub, rg, name, rev) do
            replicas when is_list(replicas) -> send_json(c, 200, %{"value" => replicas})
            :error -> not_found(c, ContainerApps.app_wire_id(sub, rg, name) <> "/revisions/" <> rev)
          end
        end),
      else: method_not_allowed(conn)
  end

  defp revisions(conn, _sub, _rg, _name, _other) do
    arm_error(conn, 404, "ResourceNotFound",
      "The requested revisions shape is not served by this control plane.", conn.request_path)
  end

  defp revision_action(conn, sub, rg, name, rev, "restart") do
    case ContainerApps.restart_revision(sub, rg, name, rev) do
      :ok ->
        reread_revision(conn, sub, rg, name, rev)

      :error ->
        not_found(conn, ContainerApps.app_wire_id(sub, rg, name) <> "/revisions/" <> rev)
    end
  end

  defp revision_action(conn, sub, rg, name, rev, action) do
    active? = action == "activate"

    case ContainerApps.set_revision_active(sub, rg, name, rev, active?) do
      :ok ->
        reread_revision(conn, sub, rg, name, rev)

      {:error, code, message, target} ->
        arm_error(conn, 400, code, message, target)

      :error ->
        not_found(conn, ContainerApps.app_wire_id(sub, rg, name) <> "/revisions/" <> rev)
    end
  end

  defp reread_revision(conn, sub, rg, name, rev) do
    case ContainerApps.get_revision(sub, rg, name, rev) do
      {:ok, revision} -> send_json(conn, 200, revision)
      :error -> not_found(conn, ContainerApps.app_wire_id(sub, rg, name) <> "/revisions/" <> rev)
    end
  end

  # --- env + certificate verbs ---------------------------------------------------------------

  defp certificates(conn, sub, rg, env, [], kind) do
    if conn.method == "GET",
      do:
        api_gate(conn, fn c ->
          send_list(c,
            if(kind == :cert,
              do: ContainerApps.list_certificates(sub, rg, env),
              else: ContainerApps.list_managed_certificates(sub, rg, env)
            )
          )
        end),
      else: method_not_allowed(conn)
  end

  defp certificates(conn, sub, rg, env, [name], kind) do
    case conn.method do
      "PUT" -> api_gate(conn, fn c -> put_cert(c, sub, rg, env, name, kind) end)
      "GET" -> api_gate(conn, fn c -> get_cert(c, sub, rg, env, name, kind) end)
      "DELETE" -> api_gate(conn, fn c -> delete_cert(c, sub, rg, env, name, kind) end)
      _ -> method_not_allowed(conn)
    end
  end

  defp certificates(conn, _sub, _rg, _env, _other, _kind) do
    arm_error(conn, 404, "ResourceNotFound",
      "The requested certificates shape is not served by this control plane.", conn.request_path)
  end

  # --- verb handlers --------------------------------------------------------------------------

  defp put_app(conn, sub, rg, name) do
    with {:ok, body, conn} <- request_body(conn),
         {:ok, view, created?} <- ContainerApps.put_app(sub, rg, name, body) do
      send_json(conn, if(created?, do: 201, else: 200), view)
    else
      {:error, code, message, target} -> arm_error(conn, 400, code, message, target)
      {:error, conn} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid and could not be deserialized.")
      :error -> not_found_or_bad(conn, sub, rg, name)
    end
  end

  defp patch_app(conn, sub, rg, name) do
    with {:ok, body, conn} <- request_body(conn),
         {:ok, view, _created?} <- ContainerApps.patch_app(sub, rg, name, body) do
      send_json(conn, 200, view)
    else
      {:error, code, message, target} -> arm_error(conn, 400, code, message, target)
      {:error, conn} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid and could not be deserialized.")
      :error -> not_found_or_bad(conn, sub, rg, name)
    end
  end

  # ARM PATCH law: PATCH against a missing app is 404 ResourceNotFound.
  defp not_found_or_bad(conn, sub, rg, name) do
    case ContainerApps.get_app(sub, rg, name) do
      {:ok, _} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid and could not be deserialized.")

      :error ->
        not_found(conn, ContainerApps.app_wire_id(sub, rg, name))
    end
  end

  defp get_app(conn, sub, rg, name) do
    case ContainerApps.get_app(sub, rg, name) do
      {:ok, view} -> send_json(conn, 200, view)
      :error -> not_found(conn, ContainerApps.app_wire_id(sub, rg, name))
    end
  end

  # DELETE is the ARM LRO face: record gone BEFORE the answer leaves,
  # 202 + Location + Retry-After (the T-10 law; az containerapp delete
  # polls and completes).
  defp delete_app(conn, sub, rg, name) do
    case ContainerApps.delete_app(sub, rg, name) do
      :ok ->
        op = LRO.start_op(ContainerApps.app_wire_id(sub, rg, name))
        authority = Smalt.Auth.Bearer.request_authority(conn)

        conn
        |> Plug.Conn.put_resp_header("location", "#{authority}#{op["id"]}")
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> send_json(202, "")

      :error ->
        not_found(conn, ContainerApps.app_wire_id(sub, rg, name))
    end
  end

  # THE LAW: never fabricate a log stream (T-10 logs law family). A
  # missing app is an honest 404; an existing app answers the typed
  # NotSupportedOnSubstrate constant verbatim.
  defp list_logs(conn, sub, rg, name) do
    with {:ok, body, conn} <- request_body(conn) do
      case ContainerApps.get_app(sub, rg, name) do
        {:ok, _} ->
          container = body["containerName"] || "unknown"
          send_json(conn, 400, %{"error" => ContainerApps.logs_refusal(name, container)})

        :error ->
          not_found(conn, ContainerApps.app_wire_id(sub, rg, name))
      end
    else
      {:error, conn} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid and could not be deserialized.")
    end
  end

  defp put_env(conn, sub, rg, env) do
    with {:ok, body, conn} <- request_body(conn),
         {:ok, view, created?} <- ContainerApps.put_env(sub, rg, env, body) do
      send_json(conn, if(created?, do: 201, else: 200), view)
    else
      {:error, conn} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid and could not be deserialized.")
    end
  end

  defp get_env(conn, sub, rg, env) do
    case ContainerApps.get_env(sub, rg, env) do
      {:ok, view} -> send_json(conn, 200, view)
      :error -> not_found(conn, ContainerApps.env_wire_id(sub, rg, env))
    end
  end

  defp delete_env(conn, sub, rg, env) do
    case ContainerApps.delete_env(sub, rg, env) do
      :ok ->
        op = LRO.start_op(ContainerApps.env_wire_id(sub, rg, env))
        authority = Smalt.Auth.Bearer.request_authority(conn)

        conn
        |> Plug.Conn.put_resp_header("location", "#{authority}#{op["id"]}")
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> send_json(202, "")

      :error ->
        not_found(conn, ContainerApps.env_wire_id(sub, rg, env))
    end
  end

  defp put_cert(conn, sub, rg, env, name, kind) do
    with {:ok, body, conn} <- request_body(conn),
         {:ok, view, created?} <-
           if(kind == :cert,
             do: ContainerApps.put_certificate(sub, rg, env, name, body),
             else: ContainerApps.put_managed_certificate(sub, rg, env, name, body)
           ) do
      send_json(conn, if(created?, do: 201, else: 200), view)
    else
      {:error, code, message, target} when is_binary(code) ->
        arm_error(conn, 400, code, message, target)

      {:error, conn} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid and could not be deserialized.")
    end
  end

  defp get_cert(conn, sub, rg, env, name, kind) do
    result =
      if kind == :cert,
        do: ContainerApps.get_certificate(sub, rg, env, name),
        else: ContainerApps.get_managed_certificate(sub, rg, env, name)

    case result do
      {:ok, view} -> send_json(conn, 200, view)
      :error -> not_found(conn, cert_wire_id(sub, rg, env, name, kind))
    end
  end

  defp delete_cert(conn, sub, rg, env, name, kind) do
    result =
      if kind == :cert,
        do: ContainerApps.delete_certificate(sub, rg, env, name),
        else: ContainerApps.delete_managed_certificate(sub, rg, env, name)

    case result do
      :ok -> send_json(conn, 204, "")
      :error -> not_found(conn, cert_wire_id(sub, rg, env, name, kind))
    end
  end

  defp cert_wire_id(sub, rg, env, name, :cert),
    do: ContainerApps.cert_wire_id(sub, rg, env, name)

  defp cert_wire_id(sub, rg, env, name, :managed_cert),
    do: ContainerApps.managed_cert_wire_id(sub, rg, env, name)

  # --- api-version gate ----------------------------------------------------------------------

  defp api_gate(conn, fun) do
    version = conn.query_params["api-version"]

    cond do
      is_nil(version) ->
        arm_error(conn, 400, "MissingApiVersionParameter",
          "The api-version query parameter is required.")

      version in ContainerApps.api_versions() ->
        fun.(conn)

      true ->
        arm_error(conn, 400, "InvalidApiVersionParameter",
          "The api-version '#{version}' is invalid. The latest supported api-version for " <>
            "'#{ContainerApps.full_type()}' is '#{ContainerApps.latest_api_version()}'.")
    end
  end

  # --- wire helpers ---------------------------------------------------------------------------

  defp request_body(conn) do
    case conn.body_params do
      params when is_map(params) and map_size(params) > 0 ->
        {:ok, params, conn}

      _ ->
        case Plug.Conn.read_body(conn) do
          {:ok, raw, conn} ->
            case Smalt.JsonCompat.decode(raw) do
              {:ok, decoded} -> {:ok, decoded, conn}
              {:error, _} -> {:error, conn}
            end

          _other ->
            {:error, conn}
        end
    end
  end

  defp send_list(conn, items) do
    skip = int_query_param(conn, "$skip", 0)
    pages = max(int_query_param(conn, "maxitempages", 1), 1)
    page = Enum.slice(items, skip, @page_size * pages)

    body =
      if length(items) > skip + length(page) do
        %{"value" => page, "nextLink" => next_link(conn, skip + length(page))}
      else
        %{"value" => page}
      end

    send_json(conn, 200, body)
  end

  defp int_query_param(conn, name, default) do
    case conn.query_params[name] do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> default
        end
    end
  end

  defp next_link(conn, skip) do
    query =
      conn.query_params
      |> Map.take(["api-version"])
      |> Map.put("maxitempages", Integer.to_string(max(int_query_param(conn, "maxitempages", 1), 1)))
      |> Map.put("$skip", skip)
      |> URI.encode_query()

    "#{Smalt.Auth.Bearer.request_authority(conn)}#{conn.request_path}?#{query}"
  end

  defp arm_error(conn, status, code, message, target \\ nil)

  defp arm_error(conn, status, code, message, nil) do
    send_json(conn, status,
      Jason.encode!(%{"error" => %{"code" => code, "message" => message, "innererror" => %{}}}))
  end

  defp arm_error(conn, status, code, message, target) do
    send_json(conn, status,
      Jason.encode!(%{
        "error" => %{"code" => code, "message" => message, "target" => target, "innererror" => %{}}
      }))
  end

  defp not_found(conn, target) do
    arm_error(conn, 404, "ResourceNotFound", "The Resource was not found.", target)
  end

  defp method_not_allowed(conn) do
    arm_error(conn, 405, "MethodNotAllowed", "The method is not allowed on this resource.",
      conn.request_path)
  end

  defp send_json(conn, status, body) when is_map(body) do
    send_json(conn, status, Jason.encode!(body))
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end
end

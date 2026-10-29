defmodule Smalt.ArmGateway.Providers.FunctionsRouter do
  @moduledoc """
  Pass-through Plug for the T-11 Functions surfaces, mounted in
  `Smalt.ArmGateway.Router` immediately BEFORE `plug(:match)` (exact wiring
  patch: docs/jira/v26.10.28/receipts/r13-t11-functions.md — the integrator
  applies it; this file ships unchanged either way, since `call/2` passes
  unmatched conns through untouched).

  Claimed prefixes (this plug OWNS them; it answers and HALTS — Plug.Builder
  skips the rest of the chain on a halted conn, so the gateway's `:match` /
  `:dispatch` never double-dispatch):

    * ARM `Microsoft.Web/sites` (kind `functionapp`), case-insensitive on
      the `resourceGroups` / `Microsoft.Web` / `sites` segments:
      - `PUT/GET/DELETE /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.Web/sites/:name`
        (registry pattern: `:smalt_resources`, downcased full ARM id)
      - rg-scoped + subscription-scoped `GET .../sites` LIST (`{"value": [...]}`)
      - `PUT/GET .../sites/:name/config/appSettings` (StringDictionary shape)
      - `POST .../sites/:name/listHostKeys`
      - `POST .../sites/:name/functions/:fn/listFunctionKeys`
      - `POST .../sites/:name/functions/:fn/invocations` -> 400 typed
        `FunctionRuntimeNotEmulated` (scope 4: never a fake 200)
    * SCM-lite admin surface on the site host (`/admin/...`; the real host
      admin API carries no api-version, so none is required here). The SITE
      is resolved from the request the way Core Tools resolves it: the Host
      header (`<name>.azurewebsites.net` or `scm.<name>.azurewebsites.net`),
      or an explicit `?sitename=<name>` override for single-host dev:
      - `GET /admin/host/status`
      - `GET/POST /admin/host/keys` (POST renews a host-level function key)
      - `GET /admin/functions`, `GET /admin/functions/:name` (real shapes)
      - `POST /admin/functions/:name` -> typed invocation refusal
      - `POST/PUT /admin/host/synctriggers` — the sync/publish PUT:
        `host.json` parse + validation with the portal-style typed 400s
        (`InvalidHostJson` / `UnknownHostJsonExtension` /
        `InvalidHostJsonVersion`) plus function-record publish.

  Dispatch law: once this router claims the `.../Microsoft.Web/sites/:name`
  prefix it ANSWERS — unknown actions under the prefix get typed 404
  envelopes instead of falling through to the generic
  `:provider_ns/:resource_type/:resource_name` ARM face, which would
  otherwise store a junk resource row for a Functions action it cannot
  interpret. The ONE exception: nested provider faces
  (`.../sites/:name/providers/...` — metrics, tags, locks,
  availabilityStatuses) pass through UNCHANGED so the gateway's existing
  generic handlers for those lanes stay in ownership (no regression).
  """

  @behaviour Plug

  import Plug.Conn, only: [
    fetch_query_params: 1,
    get_req_header: 2,
    halt: 1,
    put_resp_content_type: 2,
    read_body: 1,
    send_resp: 3
  ]

  alias Smalt.DataPlane.Functions

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    case classify(conn.path_info) do
      nil -> conn
      route -> handle(conn, route)
    end
  end

  # ===========================================================================
  # Prefix classification (the ONLY place path shapes are inspected; nil =
  # not ours, pass through with the conn untouched).
  # ===========================================================================

  defp classify(["subscriptions", sub, rg_seg, rg, "providers", ns, "sites" | rest]) do
    if String.downcase(rg_seg) == "resourcegroups" and String.downcase(ns) == "microsoft.web" do
      # Nested ARM provider faces (metrics/tags/locks/health under a site)
      # stay with the gateway's generic handlers — NOT ours.
      case rest do
        [_name, "providers" | _] -> nil
        rest -> {:sites, sub, rg, rest}
      end
    else
      nil
    end
  end

  defp classify(["subscriptions", sub, "providers", ns, "sites"]) do
    if String.downcase(ns) == "microsoft.web", do: {:site_list_sub, sub}, else: nil
  end

  defp classify(["admin" | rest]), do: {:admin, rest}

  defp classify(_other), do: nil

  # ===========================================================================
  # Dispatch
  # ===========================================================================

  defp handle(conn, {:sites, sub, rg, rest}) do
    conn = fetch_query_params(conn)

    case require_api_version(conn) do
      :ok -> site_route(conn, conn.method, sub, rg, rest)
      {:respond, conn} -> conn
    end
  end

  defp handle(conn, {:site_list_sub, sub}) do
    conn = fetch_query_params(conn)

    case require_api_version(conn) do
      :ok ->
        if conn.method == "GET" do
          sites = sub |> Functions.list_sites() |> Enum.map(&Functions.public_site/1)
          send_json(conn, 200, %{"value" => sites})
        else
          arm_error(
            conn,
            405,
            "MethodNotAllowed",
            "'#{conn.method}' is not supported on the sites listing route"
          )
        end

      {:respond, conn} ->
        conn
    end
  end

  defp handle(conn, {:admin, rest}) do
    conn = fetch_query_params(conn)
    admin_route(conn, conn.method, rest)
  end

  # --- ARM Microsoft.Web/sites ------------------------------------------------

  defp site_route(conn, "PUT", sub, rg, [name]) do
    case Functions.create_site(sub, rg, name, body_json(conn)) do
      {:ok, site, created?} ->
        send_json(conn, if(created?, do: 201, else: 200), Functions.public_site(site))

      {:error, {:arm_error, status, code, msg}} ->
        arm_error(conn, status, code, msg)
    end
  end

  defp site_route(conn, "GET", sub, rg, [name]) do
    case Functions.get_site(sub, rg, name) do
      {:ok, site} -> send_json(conn, 200, Functions.public_site(site))
      :error -> arm_error(conn, 404, "NotFound", "Site '#{name}' not found")
    end
  end

  defp site_route(conn, "DELETE", sub, rg, [name]) do
    case Functions.delete_site(sub, rg, name) do
      {:ok, deleted} -> send_json(conn, 200, Functions.public_site(deleted))
      :error -> arm_error(conn, 404, "NotFound", "Site '#{name}' not found")
    end
  end

  # rg-scoped LIST (GET .../sites).
  defp site_route(conn, "GET", sub, rg, []) do
    sites = Functions.list_sites(sub, rg) |> Enum.map(&Functions.public_site/1)
    send_json(conn, 200, %{"value" => sites})
  end

  defp site_route(conn, method, sub, rg, [name, "config", seg]) do
    if String.downcase(seg) == "appsettings" do
      case method do
        m when m in ["PUT", "POST"] ->
          app_settings_put(conn, sub, rg, name)

        "GET" ->
          app_settings_get(conn, sub, rg, name)

        _ ->
          arm_error(
            conn,
            405,
            "MethodNotAllowed",
            "'#{method}' is not supported on config/appSettings"
          )
      end
    else
      arm_error(conn, 404, "NotFound", "unknown Microsoft.Web/sites config child '#{seg}'")
    end
  end

  defp site_route(conn, "POST", sub, rg, [name, seg]) when seg != "functions" do
    if String.downcase(seg) == "listhostkeys" do
      case Functions.get_site(sub, rg, name) do
        {:ok, site} -> send_json(conn, 200, %{"properties" => Functions.host_keys(site)})
        :error -> arm_error(conn, 404, "NotFound", "Site '#{name}' not found")
      end
    else
      arm_error(conn, 404, "NotFound", "unknown Microsoft.Web/sites action '#{seg}'")
    end
  end

  defp site_route(conn, method, sub, rg, [name, "functions", fn_name, action]) do
    cond do
      String.downcase(action) == "listfunctionkeys" and method == "POST" ->
        with {:ok, site} <- Functions.get_site(sub, rg, name) do
          case Functions.function_keys(site, fn_name) do
            {:ok, keys} -> send_json(conn, 200, %{"properties" => keys})
            :error -> function_not_found(conn, fn_name, name)
          end
        else
          :error -> arm_error(conn, 404, "NotFound", "Site '#{name}' not found")
        end

      String.downcase(action) == "invocations" and method == "POST" ->
        # Typed honest refusal — constant, existence-independent: there is
        # NO runtime behind ANY invoke URL (ticket scope 4).
        send_json(conn, 400, Functions.invocation_refused())

      true ->
        arm_error(conn, 404, "NotFound", "unknown Microsoft.Web/sites function action '#{action}'")
    end
  end

  # Claimed-prefix catch-all: typed 404, never a fall-through into the
  # generic provider face (which would store junk rows for Function
  # actions it cannot interpret).
  defp site_route(conn, method, _sub, _rg, rest) do
    arm_error(
      conn,
      404,
      "NotFound",
      "no '#{method}' route under Microsoft.Web/sites#{route_suffix(rest)}"
    )
  end

  defp app_settings_put(conn, sub, rg, name) do
    case Functions.get_site(sub, rg, name) do
      {:ok, site} ->
        case app_settings_body(conn) do
          :invalid ->
            arm_error(
              conn,
              400,
              "InvalidResourceShape",
              "app settings body must be a StringDictionary: {\"properties\": {\"NAME\": \"value\"}}"
            )

          settings ->
            case Functions.set_app_settings(site, settings) do
              {:ok, updated} -> send_json(conn, 200, Functions.app_settings(updated))
              {:error, {:arm_error, status, code, msg}} -> arm_error(conn, status, code, msg)
            end
        end

      :error ->
        arm_error(conn, 404, "NotFound", "Site '#{name}' not found")
    end
  end

  defp app_settings_get(conn, sub, rg, name) do
    case Functions.get_site(sub, rg, name) do
      {:ok, site} -> send_json(conn, 200, Functions.app_settings(site))
      :error -> arm_error(conn, 404, "NotFound", "Site '#{name}' not found")
    end
  end

  defp function_not_found(conn, fn_name, site_name) do
    arm_error(conn, 404, "NotFound", "Function '#{fn_name}' not found on site '#{site_name}'")
  end

  # --- SCM-lite admin surface (site host; no api-version) ----------------------

  defp admin_route(conn, method, rest) do
    case resolve_site(conn) do
      {:ok, site} ->
        admin_site_route(conn, method, rest, site)

      {:error, {:arm_error, status, code, msg}} ->
        arm_error(conn, status, code, msg)

      {:error, :unresolved} ->
        arm_error(
          conn,
          404,
          "SiteNotFound",
          "cannot resolve the site host from this request: call the site's host surface as " <>
            "<name>.azurewebsites.net (or scm.<name>.azurewebsites.net) or pass ?sitename=<name>"
        )
    end
  end

  # Real GET /admin/host/status shape: id / state / version.
  defp admin_site_route(conn, "GET", ["host", "status"], site) do
    send_json(conn, 200, Functions.host_status(site))
  end

  # Real GET /admin/host/keys shape: masterKey / functionKeys / systemKeys.
  defp admin_site_route(conn, "GET", ["host", "keys"], site) do
    send_json(conn, 200, Functions.host_keys(site))
  end

  # POST /admin/host/keys: renew a host-level function key ({"name": ...},
  # default "default"). The master key is NOT renewable through this face
  # (real Azure keeps it fixed; renewal is the ARM keys API's job).
  defp admin_site_route(conn, "POST", ["host", "keys"], site) do
    name = Map.get(body_json(conn), "name") || "default"

    case Functions.renew_host_key(site, name) do
      {:ok, _updated, key} -> send_json(conn, 200, key)
      {:error, {:arm_error, status, code, msg}} -> arm_error(conn, status, code, msg)
    end
  end

  # Real GET /admin/functions shape: a JSON array of function records.
  defp admin_site_route(conn, "GET", ["functions"], site) do
    records = site |> Functions.list_functions() |> Enum.map(&Functions.admin_function_record/1)
    send_json(conn, 200, records)
  end

  defp admin_site_route(conn, "GET", ["functions", fn_name], site) do
    case Functions.get_function(site, fn_name) do
      {:ok, record} -> send_json(conn, 200, Functions.admin_function_record(record))
      :error -> arm_error(conn, 404, "FunctionNotFound", "Function '#{fn_name}' not found")
    end
  end

  # POST /admin/functions/:name is the real host invocation face — typed
  # honest refusal, never a fake 200.
  defp admin_site_route(conn, "POST", ["functions", _fn_name], _site) do
    send_json(conn, 400, Functions.invocation_refused())
  end

  # The sync/publish PUT (Core Tools' sync-triggers face): host.json parse +
  # validation + function publish. Envelope: {"hostJson": <json text or
  # object, optional>, "functions": [{"name": ..., "config": ...}]}. smalt
  # carries host.json as a field because zip payload storage is a ticket
  # non-goal (documented divergence in the receipt).
  defp admin_site_route(conn, m, ["host", "synctriggers"], site) when m in ["POST", "PUT"] do
    body = body_json(conn)
    host_json = Map.get(body, "hostJson")

    functions =
      case Map.get(body, "functions") do
        fns when is_list(fns) -> fns
        nil -> []
        _other -> :invalid
      end

    if functions == :invalid do
      arm_error(conn, 400, "InvalidResourceShape", "functions must be a JSON array")
    else
      case Functions.sync_triggers(site, host_json, functions) do
        {:ok, _updated, published?} ->
          names = Enum.map(functions, &Map.get(&1, "name"))
          send_json(conn, 200, %{"functions" => names, "hostJsonValidated" => published?})

        {:error, {:arm_error, status, code, msg}} ->
          arm_error(conn, status, code, msg)
      end
    end
  end

  defp admin_site_route(conn, method, rest, _site) do
    arm_error(
      conn,
      404,
      "NotFound",
      "no '#{method}' route on the functions admin surface: /admin#{route_suffix(rest)}"
    )
  end

  # --- site resolution for the admin surface -----------------------------------

  defp resolve_site(conn) do
    case resolve_site_name(conn) do
      {:ok, name} ->
        case Functions.find_site(name) do
          {:ok, site} -> {:ok, site}
          :error -> {:error, {:arm_error, 404, "SiteNotFound", "Site '#{name}' not found"}}
        end

      :unresolved ->
        {:error, :unresolved}
    end
  end

  defp resolve_site_name(conn) do
    case conn.query_params["sitename"] do
      name when is_binary(name) and name != "" -> {:ok, name}
      _other -> site_name_from_host(conn)
    end
  end

  defp site_name_from_host(conn) do
    case get_req_header(conn, "host") do
      [host | _] ->
        case host_site_name(host) do
          nil -> :unresolved
          name -> {:ok, name}
        end

      [] ->
        :unresolved
    end
  end

  # "<name>.azurewebsites.net" (default-host face) and
  # "scm.<name>.azurewebsites.net" (Kudu/SCM face) both resolve; the port
  # suffix and a trailing dot are stripped first.
  defp host_site_name(host) do
    host = host |> String.split(":") |> hd() |> String.downcase() |> String.trim_trailing(".")
    host = String.trim_prefix(host, "scm.")

    if String.ends_with?(host, ".azurewebsites.net") do
      case String.replace_suffix(host, ".azurewebsites.net", "") do
        "" -> nil
        name -> name
      end
    else
      nil
    end
  end

  # --- shared helpers -----------------------------------------------------------

  # ARM gate on the claimed provider faces (mounted BEFORE :match, so the
  # gateway's own api-version gate never runs for them): missing
  # api-version -> the gateway's envelope and message, byte-identical.
  defp require_api_version(conn) do
    case conn.query_params["api-version"] do
      nil ->
        {:respond,
         arm_error(
           conn,
           400,
           "MissingApiVersionParameter",
           "The api-version query parameter is required."
         )}

      _version ->
        :ok
    end
  end

  # Parsed JSON body (Plug.Parsers runs earlier in the gateway chain and
  # leaves the decoded object in body_params); the read fallback covers
  # callers that POST a JSON body with no/other content-type.
  defp body_json(conn) do
    case conn.body_params do
      params when is_map(params) and map_size(params) > 0 ->
        params

      _other ->
        case read_body(conn) do
          {:ok, raw, _conn} when is_binary(raw) and raw != "" ->
            case Jason.decode(raw) do
              {:ok, %{} = params} -> params
              _other -> %{}
            end

          _empty ->
            %{}
        end
    end
  end

  # Real Update Application Settings is a StringDictionary PUT:
  # {"properties": {flat name/value map}} (az wraps it exactly like this).
  # An empty object clears all settings (the replace-all semantics).
  defp app_settings_body(conn) do
    case body_json(conn) do
      %{"properties" => props} when is_map(props) -> props
      %{} = empty when map_size(empty) == 0 -> %{}
      _other -> :invalid
    end
  end

  defp route_suffix([]), do: ""

  defp route_suffix(rest) when is_list(rest),
    do: "/" <> Enum.map_join(rest, "/", &to_string/1)

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    # Pass-through protocol: a HALTED conn makes Plug.Builder skip the rest
    # of the gateway chain (:match / :dispatch never run on an answered
    # conn — dispatching again would be an AlreadySentError crash).
    |> halt()
  end

  # The gateway's ARM error envelope shape (code / message / innererror,
  # target only when a specific path is named) — mounted routers render the
  # same face so the wire carries one error idiom.
  defp arm_error(conn, status, code, message) do
    send_json(conn, status, %{
      "error" => %{"code" => code, "message" => message, "innererror" => %{}}
    })
  end
end

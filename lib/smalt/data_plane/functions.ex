defmodule Smalt.DataPlane.Functions do
  @moduledoc """
  Azure Functions engine (T-11, window v26.10.28): site records for the
  `Microsoft.Web/sites` (kind `functionapp`) ARM face plus the SCM-lite
  admin management API, sharing ONE row per site in `:smalt_resources`
  (key = downcased full ARM id, `/providers/` segment included — the
  generic ARM registry convention, same as the SB namespace parent rows).

  The stored record is ARM-shaped (`id` / `name` / `type` / `kind` /
  `location` / `properties`); the engine-only state lives INSIDE
  `properties` under reserved keys (`appSettings`, `hostJson`, `hostKeys`,
  `functionKeys`, `functions`, `hostId`). `public_site/1` drops those on
  the ARM wire face, so a plain site GET never leaks engine internals,
  while one row = one site keeps `delete_site/3` atomic. User-supplied
  `properties` are stripped of the reserved keys at create/update (no
  forgery of keys or host state through the ARM PUT face).

  Honest simulation law (ticket scope 4): there is NO function host
  runtime — `invocation_refused/0` is the typed, constant refusal every
  invocation endpoint must answer with, never a fake 200. `host.json` is
  parsed + validated (`validate_host_json/1`) with the portal-style
  validation errors for the three malformed classes: malformed JSON,
  unknown top-level extension key, `version` < 2.0 (or absent, which the
  real Functions host treats as schema v1).

  Registry pattern notes: rows key on the downcased ARM id, so the
  gateway's existing RG-delete cascade sweep (`cascade_sweep/2` on the
  downcased RG id prefix) removes site rows with the rest of the resource
  group, and generic `:smalt_resources` inventory consumers (resource
  graph, export template) see `Microsoft.Web/sites` rows like any other
  resource — no shadow copy.
  """

  alias Smalt.Store

  @table :smalt_resources
  @site_type "Microsoft.Web/sites"
  @kind "functionapp"

  # host.json top-level allowlist (ticket scope 3). Anything else at the
  # top level is the portal's unknown-extension validation error.
  @host_json_top_level_keys MapSet.new([
                              "version",
                              "functionTimeout",
                              "extensions",
                              "extensionBundle",
                              "logging",
                              "concurrency"
                            ])

  @host_json_version_min 2.0

  # Engine-reserved keys inside properties: dropped from user-supplied
  # properties (create/update — no forgery) and from the wire render
  # (public_site/1 — no leak).
  @engine_props ["appSettings", "hostJson", "hostKeys", "functionKeys", "functions", "hostId"]

  @typedoc "Stored site record (ARM-shaped row of :smalt_resources)."
  @type site :: map()

  @typedoc "Typed ARM error: {status, code, message} for the router envelope."
  @type arm_error :: {:arm_error, pos_integer(), String.t(), String.t()}

  # ===========================================================================
  # Site records: create/update (ARM PUT upsert) / delete / get / list
  # ===========================================================================

  @doc """
  The ARM PUT face for `Microsoft.Web/sites` (kind `functionapp`): upsert
  semantics, exactly like real ARM — the FIRST PUT creates (`{:ok, site,
  true}` -> 201), a re-PUT merges (`{:ok, site, false}` -> 200) preserving
  the engine state (app settings, host.json, keys, published functions).
  Returns `{:error, {:arm_error, 400, "InvalidResourceShape", _}}` for an
  invalid site name or a non-object body.
  """
  @spec create_site(String.t(), String.t(), String.t(), map()) ::
          {:ok, site(), created? :: boolean()} | {:error, arm_error()}
  def create_site(sub, rg, name, body) when is_binary(sub) and is_binary(rg) do
    with :ok <- validate_site_name(name),
         :ok <- validate_body(body) do
      key = site_key(sub, rg, name)

      case Store.get(@table, key) do
        {:ok, existing} ->
          {:ok, merge_update(existing, body), false}

        :error ->
          site = new_site(sub, rg, name, body)
          Store.put(@table, key, site)
          {:ok, site, true}
      end
    end
  end

  @doc """
  ARM update face: PUT is an upsert on `Microsoft.Web/sites` (same as
  create_site/4 — the merge path preserves engine-owned properties).
  Kept as a named entry point so call sites read create vs update.
  """
  @spec update_site(String.t(), String.t(), String.t(), map()) ::
          {:ok, site(), created? :: boolean()} | {:error, arm_error()}
  def update_site(sub, rg, name, body), do: create_site(sub, rg, name, body)

  @doc """
  Fetches one site's stored record; `:error` when absent.
  """
  @spec get_site(String.t(), String.t(), String.t()) :: {:ok, site()} | :error
  def get_site(sub, rg, name) when is_binary(sub) and is_binary(rg) and is_binary(name) do
    Store.get(@table, site_key(sub, rg, name))
  end

  @doc """
  Deletes the site row (app settings, host.json, keys and published
  functions live INSIDE the row, so one delete removes everything);
  `{:ok, deleted_site}` for the router's 200 body, `:error` (404) when
  absent.
  """
  @spec delete_site(String.t(), String.t(), String.t()) :: {:ok, site()} | :error
  def delete_site(sub, rg, name) when is_binary(sub) and is_binary(rg) and is_binary(name) do
    key = site_key(sub, rg, name)

    case Store.get(@table, key) do
      {:ok, site} ->
        Store.delete(@table, key)
        {:ok, site}

      :error ->
        :error
    end
  end

  @doc """
  Lists the sites under one resource group (rg-scoped ARM LIST face),
  sorted by name.
  """
  @spec list_sites(String.t(), String.t()) :: [site()]
  def list_sites(sub, rg) when is_binary(sub) and is_binary(rg) do
    base =
      String.downcase(
        "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Web/sites/"
      )

    @table
    |> Store.list_prefix(base)
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == @site_type))
    |> Enum.sort_by(fn %{"name" => n} -> n end)
  end

  @doc """
  Lists the sites under one subscription (subscription-scoped ARM LIST
  face, `GET /subscriptions/:sub/providers/Microsoft.Web/sites`), sorted
  by name.
  """
  @spec list_sites(String.t()) :: [site()]
  def list_sites(sub) when is_binary(sub) do
    base = String.downcase("/subscriptions/#{sub}/")

    @table
    |> Store.list_prefix(base)
    |> Enum.filter(&(is_map(&1) and Map.get(&1, "type") == @site_type))
    |> Enum.sort_by(fn %{"name" => n} -> n end)
  end

  @doc """
  Site lookup by NAME only (the SCM-lite admin surface resolves the site
  from the Host header `<name>.azurewebsites.net`, and Azure site names
  are globally unique, so no subscription scoping is available there).
  Returns `{:ok, site}` or `:error`.
  """
  @spec find_site(String.t()) :: {:ok, site()} | :error
  def find_site(name) when is_binary(name) do
    down = String.downcase(name)

    @table
    |> Store.list()
    |> Enum.find(:error, fn record ->
      is_map(record) and Map.get(record, "type") == @site_type and
        is_binary(Map.get(record, "name")) and String.downcase(record["name"]) == down
    end)
    |> case do
      :error -> :error
      site -> {:ok, site}
    end
  end

  @doc """
  The ARM wire render of a site record: drops the engine-reserved
  properties (appSettings / hostJson / hostKeys / functionKeys /
  functions / hostId) so the wire face carries exactly the real
  Microsoft.Web/sites shape (id / name / type / kind / location /
  properties with state, hostNames, ...).
  """
  @spec public_site(site()) :: map()
  def public_site(site) when is_map(site) do
    props = Map.get(site, "properties") || %{}
    Map.put(site, "properties", Map.drop(props, @engine_props))
  end

  # ===========================================================================
  # config/appSettings (StringDictionary face)
  # ===========================================================================

  @doc """
  Replaces the site's application settings (the real Update Application
  Settings API is a wholesale replace — `az functionapp config appsettings
  set` does read-merge-write client-side). `settings` must be a flat map
  of string names to string values. Persists to the site row.
  """
  @spec set_app_settings(site(), %{String.t() => String.t()}) ::
          {:ok, site()} | {:error, arm_error()}
  def set_app_settings(site, settings) when is_map(site) and is_map(settings) do
    if Enum.all?(settings, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      site
      |> put_engine_prop("appSettings", settings)
      |> persist()
      |> then(&{:ok, &1})
    else
      {:error,
       arm_error(
         400,
         "InvalidResourceShape",
         "appSettings must be a flat map of string setting names to string values"
       )}
    end
  end

  @doc """
  The config/appSettings wire body (real StringDictionary shape: a
  `Microsoft.Web/sites/config` sub-resource whose `properties` is the
  flat name/value map).
  """
  @spec app_settings(site()) :: map()
  def app_settings(site) when is_map(site) do
    props = Map.get(site, "properties") || %{}

    %{
      "id" => "#{Map.get(site, "id")}/config/appSettings",
      "name" => "#{Map.get(site, "name")}/appSettings",
      "type" => "Microsoft.Web/sites/config",
      "location" => Map.get(site, "location"),
      "properties" => Map.get(props, "appSettings") || %{}
    }
  end

  # ===========================================================================
  # host.json parse + validation (sync/publish PUT)
  # ===========================================================================

  @doc """
  Validates a raw `host.json` document (JSON text): `:ok`, or
  `{:error, message}` with the portal-style validation message. See
  `validate_host_json_typed/1` for the error-code classes.
  """
  @spec validate_host_json(binary()) :: :ok | {:error, String.t()}
  def validate_host_json(host_json) when is_binary(host_json) do
    case validate_host_json_typed(host_json) do
      :ok -> :ok
      {:error, {_code, msg}} -> {:error, msg}
    end
  end

  def validate_host_json(_other), do: {:error, "host.json must be a JSON text document"}

  @doc """
  Typed host.json validation (Jason decode): `:ok` or
  `{:error, {code, message}}` where code is one of —

    * `"InvalidHostJson"` — malformed JSON (or a non-object document);
    * `"UnknownHostJsonExtension"` — a top-level key outside the Functions
      host allowlist (version, functionTimeout, extensions, extensionBundle,
      logging, concurrency);
    * `"InvalidHostJsonVersion"` — `version` absent or < 2.0 (the real
      Functions host treats a missing version as schema v1 and refuses).

  The message is the portal-style validation error text.
  """
  @spec validate_host_json_typed(binary()) :: :ok | {:error, {String.t(), String.t()}}
  def validate_host_json_typed(host_json) when is_binary(host_json) do
    case Jason.decode(host_json) do
      {:ok, %{} = doc} ->
        validate_host_json_doc(doc)

      {:ok, _non_object} ->
        {:error,
         {"InvalidHostJson",
          "Unable to parse 'host.json' as JSON: the document must be a JSON object"}}

      {:error, %Jason.DecodeError{} = err} ->
        {:error,
         {"InvalidHostJson",
          "Unable to parse 'host.json' as JSON: " <> Exception.message(err)}}
    end
  end

  def validate_host_json_typed(_other),
    do: {:error, {"InvalidHostJson", "host.json must be a JSON text document"}}

  @doc """
  The sync/publish PUT face (`POST /admin/host/synctriggers`): validates
  and stores the site's `host.json` (raw JSON text or an already-decoded
  object, `nil` = no host.json in this sync), then upserts the function
  records (`%{"name" => ..., "config" => ...}` entries; a NEW function
  gets its `default` function key minted, an existing one keeps its key
  and gets its config replaced). Fail-closed: a validation error stores
  NOTHING. Returns `{:ok, site, host_json_published?}`.
  """
  @spec sync_triggers(site(), binary() | map() | nil, list()) ::
          {:ok, site(), host_json_published? :: boolean()} | {:error, arm_error()}
  def sync_triggers(site, host_json, functions) when is_map(site) and is_list(functions) do
    with {:ok, site, published?} <- store_host_json(site, host_json),
         {:ok, site} <- upsert_functions(site, functions) do
      {:ok, site, published?}
    end
  end

  # ===========================================================================
  # Keys (listHostKeys / listFunctionKeys class actions + admin key renewal)
  # ===========================================================================

  @doc """
  The host keys of a site in the real HostKeys shape:
  `%{"masterKey" => ..., "functionKeys" => ..., "systemKeys" => ...}`
  (master + host-level function key group + system keys).
  """
  @spec host_keys(site()) :: map()
  def host_keys(site) when is_map(site) do
    hk = engine_prop(site, "hostKeys") || %{}

    %{
      "masterKey" => Map.get(hk, "masterKey"),
      "functionKeys" => Map.get(hk, "functionKeys") || %{},
      "systemKeys" => Map.get(hk, "systemKeys") || %{}
    }
  end

  @doc """
  Renews (creates or replaces) a host-level function key named `key_name`
  (the POST /admin/host/keys face; real Azure keeps the master key
  immutable through this surface). Persists; returns the new key value.
  """
  @spec renew_host_key(site(), String.t()) ::
          {:ok, site(), %{String.t() => String.t()}} | {:error, arm_error()}
  def renew_host_key(site, key_name) when is_binary(key_name) and key_name != "" do
    hk = engine_prop(site, "hostKeys") || %{}
    fks = Map.get(hk, "functionKeys") || %{}
    value = mint_key()

    updated =
      put_engine_prop(
        site,
        "hostKeys",
        Map.put(hk, "functionKeys", Map.put(fks, key_name, value))
      )

    persist(updated)
    {:ok, updated, %{"name" => key_name, "value" => value}}
  end

  def renew_host_key(_site, _other),
    do: {:error, arm_error(400, "InvalidResourceShape", "key name must be a non-empty string")}

  @doc """
  A function's keys in the real listFunctionKeys StringDictionary shape
  (`{"default" => value}` for every synced function). `:error` (404 at the
  router) when the function was never published to the site.
  """
  @spec function_keys(site(), String.t()) :: {:ok, %{String.t() => String.t()}} | :error
  def function_keys(site, fn_name) when is_binary(fn_name) do
    down = String.downcase(fn_name)
    functions = engine_prop(site, "functions") || %{}
    keys = engine_prop(site, "functionKeys") || %{}

    if Map.has_key?(functions, down) do
      {:ok, Map.get(keys, down) || %{}}
    else
      :error
    end
  end

  # ===========================================================================
  # Functions (admin surface: /admin/functions, /admin/functions/:name)
  # ===========================================================================

  @doc """
  The site's published function records, sorted by display name.
  """
  @spec list_functions(site()) :: [map()]
  def list_functions(site) when is_map(site) do
    functions = engine_prop(site, "functions") || %{}

    functions
    |> Map.values()
    |> Enum.sort_by(fn %{"name" => n} -> n end)
  end

  @doc """
  One published function record (case-insensitive lookup — the real host
  resolves function names case-insensitively); `:error` when absent.
  """
  @spec get_function(site(), String.t()) :: {:ok, map()} | :error
  def get_function(site, fn_name) when is_binary(fn_name) do
    case Map.fetch(engine_prop(site, "functions") || %{}, String.downcase(fn_name)) do
      {:ok, record} -> {:ok, record}
      :error -> :error
    end
  end

  @doc """
  The real GET /admin/functions JSON shape for one function record
  (name / status / config + the `function` envelope with enabled flag).
  """
  @spec admin_function_record(map()) :: map()
  def admin_function_record(record) when is_map(record) do
    config = Map.get(record, "config") || %{}

    %{
      "name" => Map.get(record, "name"),
      "status" => "Created",
      "config" => config,
      "function" => %{"enabled" => true, "config" => config}
    }
  end

  # ===========================================================================
  # Admin surface: host status + the typed invocation refusal
  # ===========================================================================

  @doc """
  The GET /admin/host/status body in the real host shape (`id` / `state` /
  `version`). Honest version string: there is no real Functions host
  runtime behind it — the keys and the `Running` state are what tooling
  health checks parse.
  """
  @spec host_status(site()) :: map()
  def host_status(site) when is_map(site) do
    %{
      "id" => engine_prop(site, "hostId"),
      "state" => Map.get(Map.get(site, "properties") || %{}, "state", "Running"),
      "version" => "4.x-smalt-emulated"
    }
  end

  @doc """
  The typed, CONSTANT refusal every function invocation endpoint answers
  with (ticket scope 4: simulation is OUT — an invoke URL must never
  answer a fake 200; there is no executor behind it).
  """
  @spec invocation_refused() :: map()
  def invocation_refused do
    %{
      "error" => %{
        "code" => "FunctionRuntimeNotEmulated",
        "message" =>
          "Function invocation is not emulated: smalt provisions and configures function apps " <>
            "but runs no function host runtime, so there is no executor behind the invoke URL.",
        "innererror" => %{}
      }
    }
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp site_id(sub, rg, name),
    do: "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Web/sites/#{name}"

  defp site_key(sub, rg, name), do: String.downcase(site_id(sub, rg, name))

  # Real Azure app-name law: 2-60 lowercase alphanumeric + hyphen, leading
  # and trailing character alphanumeric.
  defp validate_site_name(name) when is_binary(name) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,58}[a-z0-9]$/, name) do
      :ok
    else
      {:error,
       arm_error(
         400,
         "InvalidResourceShape",
         "invalid site name '#{name}': must be 2-60 lowercase alphanumeric or hyphen characters"
       )}
    end
  end

  defp validate_site_name(_other),
    do: {:error, arm_error(400, "InvalidResourceShape", "site name must be a string")}

  defp validate_body(body) when is_map(body), do: :ok

  defp validate_body(_),
    do: {:error, arm_error(400, "InvalidResourceShape", "request body must be a JSON object")}

  defp new_site(sub, rg, name, body) do
    host = "#{name}.azurewebsites.net"

    %{
      "id" => site_id(sub, rg, name),
      "name" => name,
      "type" => @site_type,
      "kind" => @kind,
      "location" => Map.get(body, "location", "eastus"),
      "properties" =>
        base_props(name, host)
        |> Map.merge(user_props(body))
        |> Map.merge(engine_props_init())
    }
  end

  # The wire-visible property defaults (real site GET shape: state Running
  # is what az functionapp list/show surfaces).
  defp base_props(_name, host) do
    %{
      "state" => "Running",
      "enabled" => true,
      "hostNames" => [host],
      "defaultHostName" => host,
      "provisioningState" => "Succeeded"
    }
  end

  defp engine_props_init do
    %{
      "appSettings" => %{},
      "hostJson" => nil,
      "hostKeys" => %{
        "masterKey" => mint_key(),
        "functionKeys" => %{"default" => mint_key()},
        "systemKeys" => %{}
      },
      "functionKeys" => %{},
      "functions" => %{},
      "hostId" => mint_host_id()
    }
  end

  # Update merge: user's public properties win on overlap; engine-reserved
  # properties survive untouched (a re-PUT must never wipe app settings,
  # host.json or keys).
  defp merge_update(existing, body) do
    props = Map.get(existing, "properties") || %{}

    merged =
      props
      |> Map.merge(user_props(body))
      |> Map.merge(Map.take(props, @engine_props))

    existing
    |> Map.put("properties", merged)
    |> maybe_put_location(body)
  end

  defp user_props(body) do
    case Map.get(body, "properties") do
      props when is_map(props) -> Map.drop(props, @engine_props)
      _ -> %{}
    end
  end

  defp maybe_put_location(site, %{"location" => loc} = _body) when is_binary(loc),
    do: Map.put(site, "location", loc)

  defp maybe_put_location(site, _body), do: site

  defp store_host_json(site, nil), do: {:ok, site, false}

  defp store_host_json(site, raw) when is_binary(raw) do
    case validate_host_json_typed(raw) do
      :ok ->
        {:ok, doc} = Jason.decode(raw)
        {:ok, put_engine_prop(site, "hostJson", doc), true}

      {:error, {code, msg}} ->
        {:error, arm_error(400, code, msg)}
    end
  end

  defp store_host_json(site, %{} = doc) do
    case validate_host_json_doc(doc) do
      :ok -> {:ok, put_engine_prop(site, "hostJson", doc), true}
      {:error, {code, msg}} -> {:error, arm_error(400, code, msg)}
    end
  end

  defp store_host_json(_site, _other) do
    {:error,
     arm_error(
       400,
       "InvalidResourceShape",
       "hostJson must be JSON text or an already-decoded host.json object"
     )}
  end

  defp upsert_functions(site, []), do: {:ok, site}

  defp upsert_functions(site, functions) when is_list(functions) do
    case upsert_functions_walk(site, functions, %{}, %{}) do
      {:ok, fns, keys} ->
        site
        |> put_engine_prop("functions", fns)
        |> put_engine_prop("functionKeys", keys)
        |> persist()
        |> then(&{:ok, &1})

      {:error, _} = err ->
        err
    end
  end

  defp upsert_functions_walk(site, [], fns_acc, keys_acc) do
    props = Map.get(site, "properties") || %{}

    {:ok, Map.merge(props["functions"] || %{}, fns_acc),
     Map.merge(props["functionKeys"] || %{}, keys_acc)}
  end

  defp upsert_functions_walk(site, [item | rest], fns_acc, keys_acc) do
    case fn_entry(item) do
      {:ok, down, record} ->
        props = Map.get(site, "properties") || %{}
        existing_fns = props["functions"] || %{}
        existing_keys = props["functionKeys"] || %{}

        # Mint the default function key ONCE per function (a re-sync keeps
        # the existing key — renewal is the keys API's job, not sync's).
        keys_acc =
          if Map.has_key?(existing_fns, down) or Map.has_key?(keys_acc, down) or
               Map.has_key?(existing_keys, down) do
            keys_acc
          else
            Map.put(keys_acc, down, %{"default" => mint_key()})
          end

        upsert_functions_walk(site, rest, Map.put(fns_acc, down, record), keys_acc)

      {:error, msg} ->
        {:error, arm_error(400, "InvalidResourceShape", msg)}
    end
  end

  defp fn_entry(%{"name" => name} = item) when is_binary(name) and name != "" do
    config = Map.get(item, "config")
    config = if is_map(config), do: config, else: %{}
    {:ok, String.downcase(name), %{"name" => name, "config" => config}}
  end

  defp fn_entry(_other),
    do: {:error, "functions entries must be objects with a non-empty string 'name'"}

  defp validate_host_json_doc(doc) do
    unknown =
      doc
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@host_json_top_level_keys, &1))
      |> Enum.sort()

    if unknown == [] do
      validate_host_json_version(Map.get(doc, "version"))
    else
      {:error,
       {"UnknownHostJsonExtension",
        "Unknown extension '#{hd(unknown)}' found in 'host.json'. Please update the extension " <>
          "bundle version or remove the entry."}}
    end
  end

  defp validate_host_json_version(nil) do
    {:error,
     {"InvalidHostJsonVersion",
      "The 'version' property in 'host.json' must be set to '2.0' or higher (no 'version' " <>
        "property found; the Functions host treats that as schema v1)."}}
  end

  defp validate_host_json_version(raw) do
    case host_json_version_float(raw) do
      {:ok, v} when v >= @host_json_version_min ->
        :ok

      {:ok, v} ->
        {:error,
         {"InvalidHostJsonVersion",
          "The 'version' property in 'host.json' must be set to '2.0' or higher, found " <>
            "'#{version_string(raw, v)}'."}}

      :error ->
        {:error,
         {"InvalidHostJsonVersion",
          "The 'version' property in 'host.json' must be a number or numeric string, found " <>
            "'#{inspect(raw)}'."}}
    end
  end

  defp host_json_version_float(v) when is_number(v), do: {:ok, :erlang.float(v)}

  defp host_json_version_float(v) when is_binary(v) do
    v = String.trim(v)

    case Float.parse(v) do
      {f, ""} ->
        {:ok, f}

      _ ->
        case Integer.parse(v) do
          {i, ""} -> {:ok, :erlang.float(i)}
          _ -> :error
        end
    end
  end

  defp host_json_version_float(_other), do: :error

  defp version_string(raw, _v) when is_binary(raw), do: raw
  defp version_string(raw, v) when is_number(raw), do: to_string(v)

  defp engine_prop(site, key), do: Map.get(Map.get(site, "properties") || %{}, key)

  # Pure property update; persist/1 lands it in the store (single row per
  # site — appSettings/hostJson/keys/functions ride the same row).
  defp put_engine_prop(site, key, value) do
    props = Map.put(Map.get(site, "properties") || %{}, key, value)
    Map.put(site, "properties", props)
  end

  defp persist(site) do
    Store.put(@table, String.downcase(Map.fetch!(site, "id")), site)
    site
  end

  # Real Azure host/function keys: 32 random bytes, base64url, unpadded.
  defp mint_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp mint_host_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> to_string()
  end

  defp arm_error(status, code, message), do: {:arm_error, status, code, message}
end

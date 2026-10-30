defmodule Smalt.ArmGateway.Providers.ContainerApps do
  @moduledoc """
  ARM `Microsoft.App` runtime plane engine (lane S2, v26.10.29): the
  `containerApps` face plus the `managedEnvironments` /
  `certificates` / `managedCertificates` children it binds to. Additive
  beside the T-10 containerGroups face — `container_groups.ex` is NOT
  rewritten.

  Laws: fail-closed real-schema validation BEFORE any store write
  (`EnvironmentNotFound` for a missing managedEnvironmentId row; typed
  400 `InvalidParameter` for ingress/traffic/secrets/probe/scale
  violations; `ipSecurityRestrictions` accept real CIDR ranges — the ACA
  ingress CGNAT range `100.64.0.0/10` is first-class); real revision
  churn (template hash change mints `<app>--<n>` or
  `<app>--<revisionSuffix>`, Single mode routes 100% to the new latest
  and retires the previous active, same-revisionSuffix re-PUT updates in
  place); traffic weights live in `configuration.ingress.traffic` (the
  member the real az CLI writes; sum must be 100; entries must bind real
  revisions); secrets and certificate PFX material NEVER echo on GET;
  `listLogs` is a typed `NotSupportedOnSubstrate` refusal (same logs law
  as the T-10 face — execution is not emulated, no stream is ever
  fabricated); lifecycle renders are the documented simulated
  control-plane-only faces (Succeeded + Running replicas from the
  recorded start). Nothing executes.
  """

  alias Smalt.Store

  @provider_ns "Microsoft.App"
  @resource_type "containerApps"
  @full_type @provider_ns <> "/" <> @resource_type
  @env_full_type @provider_ns <> "/managedEnvironments"
  @cert_full_type @env_full_type <> "/certificates"
  @managed_cert_full_type @env_full_type <> "/managedCertificates"
  @revision_full_type @full_type <> "/revisions"

  @api_versions ["2022-03-01", "2023-05-01"]
  @latest_api_version "2023-05-01"

  @transports ["auto", "http1", "http2", "tcp"]
  @binding_types ["Disabled", "SslEnabled", "Auto"]
  @restriction_actions ["Allow", "Deny"]
  @revision_modes ["Single", "Multiple"]
  @probe_types ["Liveness", "Readiness", "Startup"]

  @cgnat_cidr "100.64.0.0/10"
  @env_not_found_code "EnvironmentNotFound"
  @logs_refusal_code "NotSupportedOnSubstrate"

  def full_type, do: @full_type
  def provider_ns, do: @provider_ns
  def resource_type, do: @resource_type
  def env_full_type, do: @env_full_type
  def cert_full_type, do: @cert_full_type
  def managed_cert_full_type, do: @managed_cert_full_type
  def revision_full_type, do: @revision_full_type
  def api_versions, do: @api_versions
  def latest_api_version, do: @latest_api_version
  def logs_refusal_code, do: @logs_refusal_code
  def env_not_found_code, do: @env_not_found_code
  def cgnat_cidr, do: @cgnat_cidr

  # --- ids / keys ------------------------------------------------------------------

  def app_wire_id(sub, rg, name),
    do: "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{@full_type}/#{name}"

  def app_key(sub, rg, name), do: String.downcase(app_wire_id(sub, rg, name))

  def env_wire_id(sub, rg, name),
    do: "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{@env_full_type}/#{name}"

  def env_key(sub, rg, name), do: String.downcase(env_wire_id(sub, rg, name))

  def cert_wire_id(sub, rg, env, name),
    do: env_wire_id(sub, rg, env) <> "/certificates/#{name}"

  def managed_cert_wire_id(sub, rg, env, name),
    do: env_wire_id(sub, rg, env) <> "/managedCertificates/#{name}"

  def revision_key(sub, rg, app, revision) when is_binary(revision),
    do: app_key(sub, rg, app) <> "/revisions/" <> String.downcase(revision)

  # --- PUT / PATCH app -------------------------------------------------------------

  @doc "Create-or-update; `{:ok, view, created?}` or `{:error, code, message, target}`."
  def put_app(sub, rg, name, body), do: put_or_patch_app(sub, rg, name, body, :put)

  @doc "PATCH deep-merges over the stored record, then re-validates fail-closed."
  def patch_app(sub, rg, name, body), do: put_or_patch_app(sub, rg, name, body, :patch)

  defp put_or_patch_app(sub, rg, name, body, mode) do
    key = app_key(sub, rg, name)
    existing = existing_record(key)

    with {:ok, body} <- body_map(body),
         {:ok, incoming} <- properties_map(body),
         {:ok, merged} <- merge_properties(existing, incoming, mode),
         :ok <- validate_environment_ref(merged),
         :ok <- validate_configuration(merged["configuration"]),
         :ok <- validate_template(merged["template"]),
         :ok <- validate_secret_refs(merged["template"], merged["configuration"]),
         :ok <- validate_certificate_bindings(merged),
         :ok <- validate_traffic_revisions(sub, rg, name, merged),
         {:ok, record} <- persist_app(sub, rg, name, body, merged, existing, key) do
      {:ok, view_app(record), is_nil(existing)}
    end
  end

  defp existing_record(key) do
    case Store.get(:smalt_resources, key) do
      {:ok, record} when is_map(record) -> record
      _ -> nil
    end
  end

  @read_only_property_members ~w(provisioningState latestRevisionName latestReadyRevisionName outboundIpAddresses)

  defp merge_properties(nil, incoming, _mode), do: {:ok, Map.drop(incoming, @read_only_property_members)}

  defp merge_properties(_existing, incoming, :put),
    do: {:ok, Map.drop(incoming, @read_only_property_members)}

  defp merge_properties(existing, incoming, :patch),
    do: {:ok, deep_merge(existing["properties"] || %{}, Map.drop(incoming, @read_only_property_members))}

  defp deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, va, vb -> deep_merge(va, vb) end)
  end

  defp deep_merge(_a, b), do: b

  defp persist_app(sub, rg, name, body, merged, existing, key) do
    configuration = hydrated_configuration(merged["configuration"])
    template = merged["template"] || %{}
    env_id = merged["managedEnvironmentId"]
    env_key = String.downcase(env_id)
    {env_suffix, static_ip} = env_identity(env_key)

    record =
      (existing || %{})
      |> Map.merge(%{
        "id" => app_wire_id(sub, rg, name),
        "name" => name,
        "type" => @full_type,
        "location" => body["location"],
        "tags" => body["tags"],
        "properties" =>
          merged
          |> Map.put("managedEnvironmentId", env_id)
          |> Map.put("configuration", configuration),
        "smalt_template" => template,
        "smalt_template_hash" => :erlang.phash2(template),
        "smalt_env_key" => env_key,
        "smalt_env_suffix" => env_suffix || (existing && existing["smalt_env_suffix"]),
        "smalt_static_ip" => static_ip || (existing && existing["smalt_static_ip"]),
        "smalt_started_at" => (existing && existing["smalt_started_at"]) || now_iso()
      })

    record = apply_revision_law(sub, rg, name, record)

    :ok = Store.put(:smalt_resources, key, record)

    # Server-side mint (not client input): bindingType Auto custom domains
    # auto-provision a managedCertificate under the app's environment.
    :ok = auto_mint_managed_certs(sub, rg, name, env_key, configuration)

    {:ok, record}
  end

  defp hydrated_configuration(nil), do: nil

  defp hydrated_configuration(configuration) when is_map(configuration) do
    Map.put_new(configuration, "activeRevisionsMode", "Single")
  end

  defp env_identity(env_key) do
    case typed_row(Store.get(:smalt_resources, env_key), @env_full_type) do
      {:ok, env} ->
        props = env["properties"] || %{}
        {props["smalt_domain_suffix"], props["smalt_static_ip"]}

      :error ->
        {nil, nil}
    end
  end

  # --- revision churn law ------------------------------------------------------------

  defp apply_revision_law(sub, rg, name, record) do
    template_hash = record["smalt_template_hash"]
    template = record["smalt_template"]
    configuration = record["properties"]["configuration"] || %{}
    single_mode? = Map.get(configuration, "activeRevisionsMode", "Single") == "Single"
    suffix = template["revisionSuffix"]

    revisions = list_revision_records(sub, rg, name)

    case List.last(revisions) do
      nil ->
        mint_revision(sub, rg, name, template, template_hash, suffix, record)

      latest ->
        latest_hash = get_in(latest, ["properties", "smalt_template_hash"])
        latest_suffix = get_in(latest, ["properties", "smalt_revision_suffix"])
        changed? = latest_hash != template_hash
        suffix_reuse? = is_binary(suffix) and is_binary(latest_suffix) and suffix == latest_suffix

        cond do
          changed? and suffix_reuse? ->
            replace_revision(sub, rg, name, latest["name"], template, template_hash, suffix)
            bump_latest_pointer(record, latest["name"])

          changed? ->
            latest_was_active = latest["properties"]["active"] == true
            record = mint_revision(sub, rg, name, template, template_hash, suffix, record)

            if single_mode? and latest_was_active do
              # Single mode: the platform moves traffic off the retired
              # revision (traffic check skipped — it is the platform act)
              # and routes 100% to the new latest.
              :ok = set_revision_active(sub, rg, name, latest["name"], false, skip_traffic_check: true)
              single_mode_traffic(record)
            else
              record
            end

          true ->
            bump_latest_pointer(record, latest["name"])
        end
    end
  end

  defp bump_latest_pointer(record, latest_name) do
    props = record["properties"] || %{}
    Map.put(record, "properties", Map.put(props, "latestRevisionName", latest_name))
  end

  defp single_mode_traffic(record) do
    props = record["properties"] || %{}
    configuration = props["configuration"] || %{}

    ingress =
      Map.put(configuration["ingress"] || %{}, "traffic", [
        %{"latestRevisionName" => true, "weight" => 100}
      ])

    configuration = Map.put(configuration, "ingress", ingress)

    Map.put(record, "properties", Map.put(props, "configuration", configuration))
  end

  defp new_revision_name(app, suffix, _n) when is_binary(suffix), do: "#{app}--#{suffix}"
  defp new_revision_name(app, _suffix, n), do: "#{app}--#{n}"

  defp mint_revision(sub, rg, name, template, template_hash, suffix, record) do
    count = length(list_revision_records(sub, rg, name))
    rev_name = new_revision_name(name, suffix, count + 1)
    now = now_iso()

    revision = %{
      "id" => app_wire_id(sub, rg, name) <> "/revisions/#{rev_name}",
      "name" => rev_name,
      "type" => @revision_full_type,
      "properties" => %{
        "createdTime" => now,
        "active" => true,
        "healthy" => true,
        "provisioningState" => "Succeeded",
        "template" => template,
        "smalt_template_hash" => template_hash,
        "smalt_revision_suffix" => suffix,
        "smalt_restarted_at" => nil
      }
    }

    :ok = Store.put(:smalt_resources, revision_key(sub, rg, name, rev_name), revision)

    record
    |> bump_latest_pointer(rev_name)
    |> Map.put("smalt_started_at", now)
  end

  defp replace_revision(sub, rg, name, rev_name, template, template_hash, suffix) do
    key = revision_key(sub, rg, name, rev_name)

    case Store.get(:smalt_resources, key) do
      {:ok, revision} when is_map(revision) ->
        props =
          (revision["properties"] || %{})
          |> Map.put("template", template)
          |> Map.put("smalt_template_hash", template_hash)
          |> Map.put("smalt_revision_suffix", suffix)

        :ok = Store.put(:smalt_resources, key, Map.put(revision, "properties", props))

      _ ->
        :ok
    end
  end

  # --- GET / LIST app ------------------------------------------------------------------

  @doc "Rendered wire view of one container app, or `:error`."
  def get_app(sub, rg, name) do
    typed_row(Store.get(:smalt_resources, app_key(sub, rg, name)), @full_type)
    |> case do
      {:ok, record} -> {:ok, view_app(record)}
      :error -> :error
    end
  end

  @doc "Rendered container apps under a resource group (revision rows excluded by type)."
  def list_apps(sub, rg) do
    :smalt_resources
    |> Store.list_prefix(app_key(sub, rg, ""))
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(&1["type"] == @full_type))
    |> Enum.map(&view_app/1)
  end

  @doc "Rendered container apps across a subscription (RG-agnostic `az containerapp list`)."
  def list_apps_subscription(sub), do: sub_scoped_rows(@full_type, sub)

  @doc "Rendered managed environments across a subscription."
  def list_envs_subscription(sub), do: sub_scoped_rows(@env_full_type, sub)

  defp sub_scoped_rows(type, sub) do
    prefix = String.downcase("/subscriptions/#{sub}/")
    needle = String.downcase("/providers/#{type}/")

    :smalt_resources
    |> Store.keys()
    |> Enum.filter(fn key ->
      String.starts_with?(key, prefix) and String.contains?(key, needle)
    end)
    |> Enum.flat_map(fn key ->
      case typed_row(Store.get(:smalt_resources, key), type) do
        {:ok, record} -> [render_view(record)]
        :error -> []
      end
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp render_view(%{"type" => @env_full_type} = record), do: view_env(record)
  defp render_view(%{"type" => @full_type} = record), do: view_app(record)
  defp render_view(_), do: %{}

  # --- DELETE ---------------------------------------------------------------------------

  @doc "Deletes the app and its revision rows. `:ok` or `:error`."
  def delete_app(sub, rg, name), do: delete_cascade(app_key(sub, rg, name))

  @doc "Deletes a managed environment and its certificate children. `:ok` or `:error`."
  def delete_env(sub, rg, name), do: delete_cascade(env_key(sub, rg, name))

  defp delete_cascade(key) do
    case Store.get(:smalt_resources, key) do
      {:ok, _record} ->
        for child <- Store.prefix_keys(:smalt_resources, key <> "/") do
          Store.delete(:smalt_resources, child)
        end

        Store.delete(:smalt_resources, key)
        :ok

      :error ->
        :error
    end
  end

  # --- revisions --------------------------------------------------------------------------

  defp list_revision_records(sub, rg, app) do
    :smalt_resources
    |> Store.list_prefix(app_key(sub, rg, app) <> "/revisions/")
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&get_in(&1, ["properties", "createdTime"]))
  end

  @doc "Rendered revisions of an app, oldest first (store-key order, deterministic)."
  def list_revisions(sub, rg, app), do: Enum.map(list_revision_records(sub, rg, app), &view_revision/1)

  defp fetch_revision(sub, rg, app, rev), do: typed_row(Store.get(:smalt_resources, revision_key(sub, rg, app, rev)), @revision_full_type)

  @doc "Rendered single revision, or `:error`."
  def get_revision(sub, rg, app, rev) do
    case fetch_revision(sub, rg, app, rev) do
      {:ok, record} -> {:ok, view_revision(record)}
      :error -> :error
    end
  end

  @doc "Restart refreshes the recorded replica start time. `:ok` or `:error`."
  def restart_revision(sub, rg, app, rev) do
    key = revision_key(sub, rg, app, rev)

    case fetch_revision(sub, rg, app, rev) do
      {:ok, revision} ->
        props = Map.put(revision["properties"] || %{}, "smalt_restarted_at", now_iso())
        :ok = Store.put(:smalt_resources, key, Map.put(revision, "properties", props))
        :ok

      :error ->
        :error
    end
  end

  @doc """
  Activate/deactivate with the real traffic law: a revision still carrying
  traffic weight cannot be deactivated (typed `InvalidParameter`).
  `skip_traffic_check` is the Single-mode platform path.
  """
  def set_revision_active(sub, rg, app, rev, active?, opts \\ []) do
    key = revision_key(sub, rg, app, rev)

    case fetch_revision(sub, rg, app, rev) do
      {:ok, revision} ->
        with :ok <- maybe_traffic_check(sub, rg, app, rev, active?, opts) do
          props = Map.put(revision["properties"] || %{}, "active", active?)
          :ok = Store.put(:smalt_resources, key, Map.put(revision, "properties", props))
          :ok
        end

      :error ->
        :error
    end
  end

  defp maybe_traffic_check(sub, rg, app, rev, false, opts) do
    if Keyword.get(opts, :skip_traffic_check, false) do
      :ok
    else
      if traffic_weight_of(sub, rg, app, rev) > 0 do
        {:error, "InvalidParameter",
         "Revision '#{rev}' cannot be deactivated because it still carries traffic weight.",
         "properties.configuration.ingress.traffic"}
      else
        :ok
      end
    end
  end

  defp maybe_traffic_check(_sub, _rg, _app, _rev, true, _opts), do: :ok

  defp traffic_weight_of(sub, rg, app, rev) do
    case get_app(sub, rg, app) do
      {:ok, app_view} ->
        app_view
        |> get_in(["properties", "configuration", "ingress", "traffic"])
        |> List.wrap()
        |> Enum.reduce(0, fn
          %{"revisionName" => name, "weight" => w}, acc when is_binary(name) ->
            if String.downcase(name) == String.downcase(rev), do: acc + (w || 0), else: acc

          _entry, acc ->
            acc
        end)

      :error ->
        0
    end
  end

  # --- replicas ------------------------------------------------------------------------------

  @doc """
  Replicas of a revision — the simulated control-plane-only face: an
  ACTIVE revision renders `max(scale.minReplicas, 1)` replicas from the
  recorded start; an inactive revision renders none. Nothing executes.
  """
  def list_replicas(sub, rg, app, rev) do
    with {:ok, app_record} <- typed_row(Store.get(:smalt_resources, app_key(sub, rg, app)), @full_type),
         {:ok, rev_record} <- fetch_revision(sub, rg, app, rev) do
      props = rev_record["properties"] || %{}
      started = props["smalt_restarted_at"] || props["createdTime"]

      if props["active"] do
        min = get_in(app_record, ["smalt_template", "scale", "minReplicas"]) || 0

        Enum.map(1..max(min, 1), fn i -> replica_view(app_record, rev_record["name"], i, started) end)
      else
        []
      end
    else
      _ -> :error
    end
  end

  defp replica_view(app_record, rev_name, i, started) do
    containers =
      (get_in(app_record, ["smalt_template", "containers"]) || [])
      |> Enum.map(fn
        %{"name" => n, "image" => img} -> %{"name" => n, "image" => img}
        _ -> %{}
      end)

    name = "#{rev_name}--#{i}"

    %{
      "id" => app_record["id"] <> "/revisions/#{rev_name}/replicas/#{name}",
      "name" => name,
      "type" => @revision_full_type <> "/replicas",
      "properties" => %{"createdTime" => started, "containers" => containers}
    }
  end

  # --- logs refusal (never fake logs) -----------------------------------------------------------

  @doc "Typed `listLogs` refusal — same law family as the T-10 logs face."
  def logs_refusal(app_name, container_name) do
    %{
      "code" => @logs_refusal_code,
      "message" =>
        "Container execution is not emulated by this substrate, so container app " <>
          "'#{app_name}' has never run container '#{container_name}' and no logs exist " <>
          "to read. The ARM control plane (create/show/list/update/delete, revisions, " <>
          "traffic weights, ingress) is fully served; log streaming is permanently " <>
          "out of scope and is never fabricated.",
      "target" => "containerName=#{container_name}",
      "innererror" => %{}
    }
  end

  # --- managed environments ------------------------------------------------------------------------

  @doc "Create-or-replace a managed environment. `{:ok, view, created?}`."
  def put_env(sub, rg, name, body) do
    key = env_key(sub, rg, name)

    with {:ok, body} <- body_map(body) do
      {suffix, static_ip} =
        case typed_row(Store.get(:smalt_resources, key), @env_full_type) do
          {:ok, env} ->
            props = env["properties"] || %{}
            {props["smalt_domain_suffix"], props["smalt_static_ip"]}

          :error ->
            {deterministic_suffix(name, 10), synth_static_ip(name)}
        end

      client_props = Map.drop(body["properties"] || %{}, ~w(smalt_domain_suffix smalt_static_ip))

      record = %{
        "id" => env_wire_id(sub, rg, name),
        "name" => name,
        "type" => @env_full_type,
        "location" => body["location"],
        "tags" => body["tags"],
        "properties" =>
          Map.merge(client_props, %{"smalt_domain_suffix" => suffix, "smalt_static_ip" => static_ip})
      }

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      :ok = Store.put(:smalt_resources, key, record)
      {:ok, view_env(record), not existed?}
    end
  end

  @doc "Rendered managed environment or `:error`."
  def get_env(sub, rg, name) do
    case typed_row(Store.get(:smalt_resources, env_key(sub, rg, name)), @env_full_type) do
      {:ok, record} -> {:ok, view_env(record)}
      :error -> :error
    end
  end

  @doc "Rendered managed environments under a resource group."
  def list_envs(sub, rg) do
    :smalt_resources
    |> Store.list_prefix(env_key(sub, rg, ""))
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(&1["type"] == @env_full_type))
    |> Enum.map(&view_env/1)
  end

  @doc "Deterministic simulated env domain suffix stem."
  def synth_env_suffix(name), do: deterministic_suffix(name, 10)

  defp deterministic_suffix(seed, len) do
    :crypto.hash(:md5, seed) |> Base.encode16(case: :lower) |> binary_part(0, len)
  end

  defp synth_static_ip(name) do
    "10.97.#{:erlang.phash2(name, 254) + 1}.#{:erlang.phash2({name, :ip}, 254) + 1}"
  end

  # --- certificates ------------------------------------------------------------------------------------

  @doc "Create-or-replace an uploaded certificate (`az containerapp ssl upload` face)."
  def put_certificate(sub, rg, env, name, body) do
    key = String.downcase(cert_wire_id(sub, rg, env, name))

    with {:ok, body} <- body_map(body),
         {:ok, secret_props} <- cert_secrets(body, name) do
      record = %{
        "id" => cert_wire_id(sub, rg, env, name),
        "name" => name,
        "type" => @cert_full_type,
        "location" => body["location"],
        "properties" =>
          secret_props
          |> Map.put("provisioningState", "Succeeded")
          |> Map.put("expirationDate", DateTime.add(DateTime.utc_now(), 730, :day) |> DateTime.to_iso8601())
      }

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      :ok = Store.put(:smalt_resources, key, record)
      {:ok, view_certificate(record), not existed?}
    end
  end

  defp cert_secrets(body, name) do
    props = body["properties"]

    cond do
      not is_map(props) ->
        {:error, "InvalidRequestContent", "The request content was invalid and could not be deserialized.",
         "properties"}

      not (is_binary(props["value"]) and props["value"] != "") ->
        {:error, "InvalidParameter", "Certificate '#{name}' must carry the base64 PFX value.", "properties.value"}

      not is_binary(props["password"]) ->
        {:error, "InvalidParameter", "Certificate '#{name}' must carry the PFX password.", "properties.password"}

      true ->
        {:ok, %{"value" => props["value"], "password" => props["password"]}}
    end
  end

  @doc "Rendered certificate (value/password NEVER echo) or `:error`."
  def get_certificate(sub, rg, env, name) do
    case typed_row(Store.get(:smalt_resources, String.downcase(cert_wire_id(sub, rg, env, name))), @cert_full_type) do
      {:ok, record} -> {:ok, view_certificate(record)}
      :error -> :error
    end
  end

  @doc "Rendered certificates under an environment."
  def list_certificates(sub, rg, env) do
    :smalt_resources
    |> Store.list_prefix(String.downcase(cert_wire_id(sub, rg, env, "")))
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(&1["type"] == @cert_full_type))
    |> Enum.map(&view_certificate/1)
  end

  @doc "Deletes a certificate row. `:ok` or `:error`."
  def delete_certificate(sub, rg, env, name) do
    case typed_row(Store.get(:smalt_resources, String.downcase(cert_wire_id(sub, rg, env, name))), @cert_full_type) do
      {:ok, _record} ->
        :ok = Store.delete(:smalt_resources, String.downcase(cert_wire_id(sub, rg, env, name)))
        :ok

      :error ->
        :error
    end
  end

  # --- managed certificates --------------------------------------------------------------------------------

  @doc "Create-or-replace a managedCertificate record (Auto-binding custom domains mint one)."
  def put_managed_certificate(sub, rg, env, name, body) do
    key = String.downcase(managed_cert_wire_id(sub, rg, env, name))

    with {:ok, body} <- body_map(body) do
      props = body["properties"] || %{}

      record = %{
        "id" => managed_cert_wire_id(sub, rg, env, name),
        "name" => name,
        "type" => @managed_cert_full_type,
        "location" => body["location"],
        "properties" => %{
          "subjectName" => props["subjectName"],
          "domainControlValidation" => props["domainControlValidation"] || "HTTP",
          "provisioningState" => "Succeeded"
        }
      }

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      :ok = Store.put(:smalt_resources, key, record)
      {:ok, view_managed_certificate(record), not existed?}
    end
  end

  @doc "Rendered managedCertificate or `:error`."
  def get_managed_certificate(sub, rg, env, name) do
    case typed_row(Store.get(:smalt_resources, String.downcase(managed_cert_wire_id(sub, rg, env, name))), @managed_cert_full_type) do
      {:ok, record} -> {:ok, view_managed_certificate(record)}
      :error -> :error
    end
  end

  @doc "Rendered managedCertificates under an environment."
  def list_managed_certificates(sub, rg, env) do
    :smalt_resources
    |> Store.list_prefix(String.downcase(managed_cert_wire_id(sub, rg, env, "")))
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(&1["type"] == @managed_cert_full_type))
    |> Enum.map(&view_managed_certificate/1)
  end

  @doc "Deletes a managedCertificate row. `:ok` or `:error`."
  def delete_managed_certificate(sub, rg, env, name) do
    key = String.downcase(managed_cert_wire_id(sub, rg, env, name))

    case typed_row(Store.get(:smalt_resources, key), @managed_cert_full_type) do
      {:ok, _record} ->
        :ok = Store.delete(:smalt_resources, key)
        :ok

      :error ->
        :error
    end
  end

  # --- custom-domain auto-mint (bindingType Auto) -----------------------------------------------------------

  @doc "Deterministic managedCertificate name for a bound hostname: `<app>-<hostname dots dashed>`."
  def managed_cert_name(app, hostname) do
    "#{app}-#{String.replace(String.downcase(hostname), ".", "-")}"
  end

  defp auto_mint_managed_certs(sub, rg, app_name, env_key, configuration) do
    domains = get_in(configuration || %{}, ["ingress", "customDomains"]) || []
    env_name = env_key && List.last(String.split(env_key, "/"))

    Enum.each(domains, fn
      %{"name" => host, "bindingType" => "Auto"} when is_binary(host) and env_name != nil ->
        put_managed_certificate(sub, rg, env_name, managed_cert_name(app_name, host), %{
          "properties" => %{"subjectName" => host, "domainControlValidation" => "HTTP"}
        })

      _ ->
        :ok
    end)

    :ok
  end

  # --- validation (real 2023-05-01 schema, fail-closed) --------------------------------------------------------

  defp typed_row({:ok, record}, _type) when not is_map(record), do: :error

  defp typed_row({:ok, record}, type) do
    if record["type"] == type, do: {:ok, record}, else: :error
  end

  defp typed_row(_other, _type), do: :error

  defp body_map(%{} = body), do: {:ok, body}

  defp body_map(_),
    do: {:error, "InvalidRequestContent", "The request content was invalid and could not be deserialized.", nil}

  defp properties_map(%{"properties" => %{} = props}), do: {:ok, props}

  defp properties_map(_),
    do:
      {:error, "InvalidRequestContent", "The request content was invalid and could not be deserialized.",
       "properties"}

  defp validate_environment_ref(merged) do
    case merged["managedEnvironmentId"] do
      env_id when is_binary(env_id) and env_id != "" ->
        case typed_row(Store.get(:smalt_resources, String.downcase(env_id)), @env_full_type) do
          {:ok, _row} ->
            :ok

          :error ->
            {:error, @env_not_found_code,
             "The managed environment '#{env_id}' was not found. Create it first " <>
               "(az containerapp env create).",
             "properties.managedEnvironmentId"}
        end

      _ ->
        {:error, "InvalidParameter", "Container app must reference a managed environment.",
         "properties.managedEnvironmentId"}
    end
  end

  defp validate_configuration(nil), do: :ok

  defp validate_configuration(configuration) when is_map(configuration) do
    with :ok <- validate_active_revisions_mode(configuration["activeRevisionsMode"]),
         :ok <- validate_secrets(configuration["secrets"]),
         :ok <- validate_ingress(configuration["ingress"]) do
      :ok
    end
  end

  defp validate_configuration(_other),
    do: {:error, "InvalidParameter", "configuration must be an object.", "properties.configuration"}

  defp validate_active_revisions_mode(nil), do: :ok
  defp validate_active_revisions_mode(mode) when mode in @revision_modes, do: :ok

  defp validate_active_revisions_mode(_mode),
    do:
      {:error, "InvalidParameter", "activeRevisionsMode must be Single or Multiple.",
       "properties.configuration.activeRevisionsMode"}

  defp validate_secrets(nil), do: :ok

  defp validate_secrets(secrets) when is_list(secrets) do
    cond do
      Enum.any?(secrets, fn s -> not (is_map(s) and is_binary(s["name"]) and s["name"] != "") end) ->
        {:error, "InvalidParameter", "Every secret must carry a name.", "properties.configuration.secrets"}

      Enum.any?(secrets, fn s -> not is_binary(s["value"]) end) ->
        {:error, "InvalidParameter", "Every secret must carry a value.", "properties.configuration.secrets"}

      length(secrets) != length(Enum.uniq_by(secrets, & &1["name"])) ->
        {:error, "InvalidParameter", "Secret names must be unique.", "properties.configuration.secrets"}

      true ->
        :ok
    end
  end

  defp validate_secrets(_other),
    do: {:error, "InvalidParameter", "secrets must be an array.", "properties.configuration.secrets"}

  defp validate_ingress(nil), do: :ok

  defp validate_ingress(ingress) when is_map(ingress) do
    target = "properties.configuration.ingress"

    with :ok <- bool_member(ingress["external"], "#{target}.external"),
         :ok <- bool_member(ingress["allowInsecure"], "#{target}.allowInsecure"),
         :ok <- port_member(ingress["targetPort"], "#{target}.targetPort"),
         :ok <- exposed_port_law(ingress, target),
         :ok <- transport_member(ingress["transport"], target),
         :ok <- validate_restrictions(ingress["ipSecurityRestrictions"], target),
         :ok <- validate_custom_domains(ingress["customDomains"], target),
         :ok <- validate_traffic(ingress["traffic"], target) do
      :ok
    end
  end

  defp validate_ingress(_other),
    do: {:error, "InvalidParameter", "ingress must be an object.", "properties.configuration.ingress"}

  defp bool_member(nil, _target), do: :ok
  defp bool_member(v, _target) when is_boolean(v), do: :ok
  defp bool_member(_v, target), do: {:error, "InvalidParameter", "must be a boolean.", target}

  defp port_member(nil, _target), do: :ok
  defp port_member(port, _target) when is_integer(port) and port >= 1 and port <= 65_535, do: :ok

  defp port_member(_port, target),
    do: {:error, "InvalidParameter", "port must be an integer between 1 and 65535.", target}

  defp transport_member(nil, _target), do: :ok
  defp transport_member(t, _target) when t in @transports, do: :ok

  defp transport_member(_t, target),
    do: {:error, "InvalidParameter", "transport must be one of auto, http1, http2, tcp.", target}

  defp exposed_port_law(%{"exposedPort" => exposed} = ingress, target) do
    with :ok <- port_member(exposed, "#{target}.exposedPort") do
      if ingress["transport"] == "tcp" do
        :ok
      else
        {:error, "InvalidParameter", "exposedPort requires transport tcp.", "#{target}.exposedPort"}
      end
    end
  end

  defp exposed_port_law(_ingress, _target), do: :ok

  defp validate_restrictions(nil, _target), do: :ok

  defp validate_restrictions(restrictions, target) when is_list(restrictions) do
    restrictions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {r, i}, _acc when is_map(r) ->
        rt = "#{target}.ipSecurityRestrictions[#{i}]"

        cond do
          not (is_binary(r["name"]) and r["name"] != "") ->
            {:halt, {:error, "InvalidParameter", "ipSecurityRestriction must carry a name.", "#{rt}.name"}}

          r["action"] not in @restriction_actions ->
            {:halt,
             {:error, "InvalidParameter", "ipSecurityRestriction action must be Allow or Deny.", "#{rt}.action"}}

          true ->
            case validate_cidr(r["ipAddressRange"]) do
              :ok -> {:cont, :ok}
              {:error, msg} -> {:halt, {:error, "InvalidParameter", msg, "#{rt}.ipAddressRange"}}
            end
        end

      {_r, i}, _acc ->
        {:halt, {:error, "InvalidParameter", "ipSecurityRestriction must be an object.",
         "properties.configuration.ingress.ipSecurityRestrictions[#{i}]"}}
    end)
  end

  defp validate_restrictions(_other, target),
    do: {:error, "InvalidParameter", "ipSecurityRestrictions must be an array.", target}

  @doc "CIDR law: `a.b.c.d/prefix` with prefix 0..32; `100.64.0.0/10` (the ACA ingress CGNAT range) is valid."
  def validate_cidr(range) when is_binary(range) do
    case Regex.run(~r"\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})\z", range) do
      [_match, a, b, c, d, p] ->
        octets = Enum.map([a, b, c, d], &String.to_integer/1)
        prefix = String.to_integer(p)

        if Enum.all?(octets, &(&1 <= 255)) and prefix <= 32 do
          :ok
        else
          {:error, "ipAddressRange '#{range}' is not a valid IPv4 CIDR range."}
        end

      nil ->
        {:error, "ipAddressRange '#{range}' is not a valid IPv4 CIDR range."}
    end
  end

  def validate_cidr(_other), do: {:error, "ipAddressRange must be a CIDR string."}

  defp validate_custom_domains(nil, _target), do: :ok

  defp validate_custom_domains(domains, target) when is_list(domains) do
    domains
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {d, i}, _acc when is_map(d) ->
        dt = "#{target}.customDomains[#{i}]"

        cond do
          not (is_binary(d["name"]) and d["name"] != "") ->
            {:halt, {:error, "InvalidParameter", "customDomain must carry a name.", "#{dt}.name"}}

          d["bindingType"] not in @binding_types ->
            {:halt,
             {:error, "InvalidParameter", "bindingType must be Disabled, SslEnabled or Auto.",
              "#{dt}.bindingType"}}

          true ->
            :ok
        end

      {_d, i}, _acc ->
        {:halt, {:error, "InvalidParameter", "customDomain must be an object.",
         "properties.configuration.ingress.customDomains[#{i}]"}}
    end)
  end

  defp validate_custom_domains(_other, target),
    do: {:error, "InvalidParameter", "customDomains must be an array.", target}

  defp validate_certificate_bindings(merged) do
    domains = get_in(merged, ["configuration", "ingress", "customDomains"]) || []
    env_id = merged["managedEnvironmentId"]
    env_prefix = env_id && String.downcase(env_id)

    domains
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%{"bindingType" => "SslEnabled"} = d, i}, _acc ->
        target = "properties.configuration.ingress.customDomains[#{i}].certificateId"
        cert_id = d["certificateId"]

        cond do
          not (is_binary(cert_id) and cert_id != "") ->
            {:halt,
             {:error, "InvalidParameter",
              "customDomain with bindingType SslEnabled requires a certificateId.", target}}

          not is_binary(env_prefix) ->
            {:halt,
             {:error, "InvalidParameter", "customDomain binding requires a managed environment.", target}}

          true ->
            case typed_row(Store.get(:smalt_resources, String.downcase(cert_id)), @cert_full_type) do
              {:ok, _row} ->
                if String.starts_with?(String.downcase(cert_id), env_prefix) do
                  {:cont, :ok}
                else
                  {:halt,
                   {:error, "InvalidParameter",
                    "Certificate '#{cert_id}' does not belong to the app's managed environment.", target}}
                end

              :error ->
                {:halt, {:error, "InvalidParameter", "Certificate '#{cert_id}' was not found.", target}}
            end
        end

      {_d, _i}, acc ->
        acc
    end)
  end

  defp validate_traffic_revisions(sub, rg, app, merged) do
    traffic = get_in(merged, ["configuration", "ingress", "traffic"]) || []

    Enum.reduce_while(traffic, :ok, fn
      %{"revisionName" => rev}, _acc when is_binary(rev) ->
        case fetch_revision(sub, rg, app, rev) do
          {:ok, _} ->
            {:cont, :ok}

          :error ->
            {:halt,
             {:error, "InvalidParameter", "Revision '#{rev}' does not exist for container app '#{app}'.",
              "properties.configuration.ingress.traffic"}}
        end

      _entry, acc ->
        acc
    end)
  end

  defp validate_traffic(nil, _target), do: :ok

  defp validate_traffic(traffic, target) when is_list(traffic) do
    if traffic == [] do
      :ok
    else
      weights = Enum.map(traffic, & &1["weight"])

      sum_ok? =
        Enum.all?(weights, fn w -> is_integer(w) and w >= 0 and w <= 100 end) and
          Enum.sum(weights) == 100

      named? =
        Enum.all?(traffic, fn t ->
          is_map(t) and
            (is_binary(t["revisionName"]) or t["latestRevisionName"] == true or is_binary(t["label"]))
        end)

      latest_count = Enum.count(traffic, fn t -> is_map(t) and t["latestRevisionName"] == true end)

      cond do
        not named? ->
          {:error, "InvalidParameter", "every traffic entry must carry revisionName, latestRevisionName or label.",
           "#{target}.traffic"}

        not sum_ok? ->
          {:error, "InvalidParameter", "The sum of traffic weights must be equal to 100.", "#{target}.traffic"}

        latest_count > 1 ->
          {:error, "InvalidParameter", "only one traffic entry may reference latestRevisionName.",
           "#{target}.traffic"}

        true ->
          :ok
      end
    end
  end

  defp validate_traffic(_other, target),
    do: {:error, "InvalidParameter", "traffic must be an array.", "#{target}.traffic"}

  defp validate_secret_refs(template, configuration) when is_map(template) do
    declared =
      ((configuration && configuration["secrets"]) || [])
      |> List.wrap()
      |> Enum.map(& &1["name"])
      |> Enum.reject(&is_nil/1)

    envs = Enum.flat_map(template["containers"] || [], fn c -> (is_map(c) && c["env"]) || [] end)

    bad =
      Enum.find_index(envs, fn e ->
        is_map(e) and is_binary(e["secretRef"]) and not Enum.member?(declared, e["secretRef"])
      end)

    if bad do
      {:error, "InvalidParameter",
       "Secret reference '#{get_in(envs, [bad, "secretRef"])}' is not defined in configuration.secrets.",
       "properties.template.containers.env[#{bad}].secretRef"}
    else
      :ok
    end
  end

  defp validate_secret_refs(_template, _configuration), do: :ok

  defp validate_template(nil), do: :ok

  defp validate_template(template) when is_map(template) do
    with :ok <- validate_containers(template["containers"]),
         :ok <- validate_scale(template["scale"]) do
      :ok
    end
  end

  defp validate_template(_other),
    do: {:error, "InvalidParameter", "template must be an object.", "properties.template"}

  defp validate_containers(containers) when is_list(containers) and containers != [] do
    containers
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {c, i}, _acc when is_map(c) ->
        target = "properties.template.containers[#{i}]"

        cond do
          not (is_binary(c["name"]) and c["name"] != "") ->
            {:halt, {:error, "InvalidParameter", "container must carry a name.", "#{target}.name"}}

          not (is_binary(c["image"]) and c["image"] != "") ->
            {:halt,
             {:error, "InvalidParameter", "Container '#{c["name"]}' must specify an image.", "#{target}.image"}}

          true ->
            with :ok <- validate_container_resources(c["resources"], target, c["name"]),
                 :ok <- validate_container_env(c["env"], target),
                 :ok <- validate_probes(c["probes"], target, c["name"]) do
              {:cont, :ok}
            else
              error -> {:halt, error}
            end
        end

      {_c, i}, _acc ->
        {:halt,
         {:error, "InvalidParameter", "container must be an object with a name and image.",
          "properties.template.containers[#{i}]"}}
    end)
  end

  defp validate_containers(_other),
    do: {:error, "InvalidParameter", "template must specify at least one container with an image.",
         "properties.template.containers"}

  defp validate_container_resources(nil, _target, _name), do: :ok

  defp validate_container_resources(resources, target, name) when is_map(resources) do
    req = resources["requests"] || resources

    cond do
      req["cpu"] != nil and not (is_number(req["cpu"]) and req["cpu"] > 0) ->
        {:error, "InvalidParameter", "Container '#{name}' cpu must be a positive number.",
         "#{target}.resources.cpu"}

      req["memory"] != nil and not (is_number(req["memory"]) and req["memory"] > 0) ->
        {:error, "InvalidParameter", "Container '#{name}' memory must be a positive number.",
         "#{target}.resources.memory"}

      true ->
        :ok
    end
  end

  defp validate_container_resources(_other, target, _name),
    do: {:error, "InvalidParameter", "resources must be an object.", "#{target}.resources"}

  defp validate_container_env(nil, _target), do: :ok

  defp validate_container_env(env, target) when is_list(env) do
    env
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {e, i}, _acc when is_map(e) ->
        cond do
          not (is_binary(e["name"]) and e["name"] != "") ->
            {:halt, {:error, "InvalidParameter", "env entry must carry a name.", "#{target}.env[#{i}].name"}}

          e["value"] == nil and not is_binary(e["secretRef"]) ->
            {:halt, {:error, "InvalidParameter", "env entry must carry value or secretRef.", "#{target}.env[#{i}]"}}

          true ->
            {:cont, :ok}
        end

      {_e, i}, _acc ->
        {:halt, {:error, "InvalidParameter", "env entry must be an object.", "#{target}.env[#{i}]"}}
    end)
  end

  defp validate_container_env(_other, target),
    do: {:error, "InvalidParameter", "env must be an array.", "#{target}.env"}

  defp validate_probes(nil, _target, _name), do: :ok

  defp validate_probes(probes, target, name) when is_list(probes) do
    probes
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {p, i}, _acc when is_map(p) ->
        pt = "#{target}.probes[#{i}]"

        cond do
          p["type"] not in @probe_types ->
            {:halt,
             {:error, "InvalidParameter", "probe type must be Liveness, Readiness or Startup.", "#{pt}.type"}}

          not probe_timings_ok?(p) ->
            {:halt, {:error, "InvalidParameter", "Probe timings must be non-negative integers.", pt}}

          valid_exec?(p) or valid_http_get?(p) or valid_tcp_socket?(p) ->
            {:cont, :ok}

          true ->
            {:halt,
             {:error, "InvalidParameter", "Probe of container '#{name}' must specify one of httpGet, tcpSocket or exec.",
              pt}}
        end

      {_p, i}, _acc ->
        {:halt, {:error, "InvalidParameter", "probe must be an object.", "#{target}.probes[#{i}]"}}
    end)
  end

  defp validate_probes(_other, target, _name),
    do: {:error, "InvalidParameter", "probes must be an array.", "#{target}.probes"}

  defp valid_exec?(%{"exec" => command}) when is_list(command), do: Enum.all?(command, &is_binary/1)
  defp valid_exec?(_), do: false

  defp valid_http_get?(%{"httpGet" => %{"path" => path, "port" => port}})
       when is_binary(path) and is_integer(port) and port >= 1 and port <= 65_535,
       do: true

  defp valid_http_get?(_), do: false

  defp valid_tcp_socket?(%{"tcpSocket" => %{"port" => port}})
       when is_integer(port) and port >= 1 and port <= 65_535,
       do: true

  defp valid_tcp_socket?(_), do: false

  defp probe_timings_ok?(probe) do
    ~w(initialDelaySeconds periodSeconds timeoutSeconds failureThreshold successThreshold)
    |> Enum.all?(fn field ->
      case probe[field] do
        nil -> true
        n when is_integer(n) and n >= 0 -> true
        _ -> false
      end
    end)
  end

  defp validate_scale(nil), do: :ok

  defp validate_scale(scale) when is_map(scale) do
    target = "properties.template.scale"
    min = scale["minReplicas"]
    max = scale["maxReplicas"]

    cond do
      min != nil and not (is_integer(min) and min >= 0) ->
        {:error, "InvalidParameter", "minReplicas must be a non-negative integer.", "#{target}.minReplicas"}

      max != nil and not (is_integer(max) and max >= 1) ->
        {:error, "InvalidParameter", "maxReplicas must be a positive integer.", "#{target}.maxReplicas"}

      is_integer(min) and is_integer(max) and min > max ->
        {:error, "InvalidParameter", "minReplicas must be less than or equal to maxReplicas.",
         "#{target}.minReplicas"}

      not (is_nil(scale["rules"]) or is_list(scale["rules"])) ->
        {:error, "InvalidParameter", "scale rules must be an array.", "#{target}.rules"}

      true ->
        :ok
    end
  end

  defp validate_scale(_other),
    do: {:error, "InvalidParameter", "scale must be an object.", "properties.template.scale"}

  # --- view renderers (simulated lifecycle, secrets stripped) -----------------------------------------------

  @smalt_internal_members ~w(smalt_template smalt_template_hash smalt_env_key smalt_env_suffix smalt_static_ip smalt_started_at smalt_provisioned_at)

  defp view_app(record) do
    props = record["properties"] || %{}
    configuration = props["configuration"]
    template = record["smalt_template"] || %{}
    latest = props["latestRevisionName"]

    base_properties =
      props
      |> Map.put("provisioningState", "Succeeded")
      |> Map.put("template", template)
      |> Map.put("latestRevisionName", latest)
      |> Map.put("latestReadyRevisionName", latest)
      |> maybe_put_outbound_ips(record)

    properties =
      if is_map(configuration) do
        Map.put(base_properties, "configuration", render_configuration(configuration, record))
      else
        base_properties
      end

    record
    |> Map.drop(@smalt_internal_members)
    |> Map.put("type", @full_type)
    |> Map.put("tags", normalize_tags(record["tags"]))
    |> Map.put("properties", properties)
  end

  defp render_configuration(configuration, record) do
    configuration
    |> strip_secret_values()
    |> render_fqdn(record)
  end

  defp strip_secret_values(configuration) do
    case configuration["secrets"] do
      secrets when is_list(secrets) ->
        Map.put(configuration, "secrets", Enum.map(secrets, &Map.delete(&1, "value")))

      _ ->
        configuration
    end
  end

  defp render_fqdn(configuration, record) do
    case configuration["ingress"] do
      ingress when is_map(ingress) ->
        app = record["name"]
        suffix = record["smalt_env_suffix"] || synth_env_suffix(app)
        region = region_of(record["location"])
        fqdn = "#{String.downcase(app)}.#{suffix}.#{region}.azurecontainerapps.io"

        Map.put(configuration, "ingress", Map.put_new(ingress, "fqdn", fqdn))

      _ ->
        configuration
    end
  end

  defp maybe_put_outbound_ips(props, record) do
    case record["smalt_static_ip"] do
      ip when is_binary(ip) -> Map.put(props, "outboundIpAddresses", [ip])
      _ -> props
    end
  end

  defp region_of(nil), do: "eastus"
  defp region_of(loc) when is_binary(loc), do: String.replace(String.downcase(loc), " ", "")

  defp view_revision(revision) do
    props =
      Map.drop(revision["properties"] || %{}, ~w(smalt_template_hash smalt_revision_suffix smalt_restarted_at))

    Map.put(revision, "type", @revision_full_type) |> Map.put("properties", props)
  end

  defp view_env(record) do
    raw_props = record["properties"] || %{}
    suffix = raw_props["smalt_domain_suffix"] || synth_env_suffix(record["name"])
    region = region_of(record["location"])
    static_ip = raw_props["smalt_static_ip"]

    props =
      raw_props
      |> Map.drop(~w(smalt_domain_suffix smalt_static_ip))
      |> Map.put("provisioningState", "Succeeded")
      |> Map.put_new("defaultDomain", "#{suffix}.#{region}.azurecontainerapps.io")
      |> Map.put("staticIp", static_ip)

    record
    |> Map.drop(@smalt_internal_members)
    |> Map.put("type", @env_full_type)
    |> Map.put("tags", normalize_tags(record["tags"]))
    |> Map.put("properties", props)
  end

  defp view_certificate(record) do
    props = Map.drop(record["properties"] || %{}, ~w(value password))
    Map.put(record, "properties", props)
  end

  defp view_managed_certificate(record), do: record

  defp normalize_tags(nil), do: nil
  defp normalize_tags(%{} = tags), do: if(map_size(tags) == 0, do: nil, else: tags)
  defp normalize_tags(_), do: nil

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

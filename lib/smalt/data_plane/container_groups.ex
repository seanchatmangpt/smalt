defmodule Smalt.DataPlane.ContainerGroups do
  @moduledoc """
  ARM `Microsoft.ContainerInstance/containerGroups` CONTROL PLANE engine (T-10,
  window v26.10.28). Design law: container EXECUTION is out of scope — this
  substrate has no container runtime (README: "no cloud connection, no host
  configuration for the native tier"; the dev box has no Docker), so the
  engine serves the ARM shapes a terraform/azurerm or `az` developer drives
  and NEVER pretends anything ran.

  Wire surface (ARM routes in `Smalt.ArmGateway.Providers.ContainerGroupsRouter`):

      PUT    .../providers/Microsoft.ContainerInstance/containerGroups/<name>
      GET    .../providers/Microsoft.ContainerInstance/containerGroups/<name>
      DELETE .../providers/Microsoft.ContainerInstance/containerGroups/<name>
      GET    .../providers/Microsoft.ContainerInstance/containerGroups                  (RG LIST)
      GET    /subscriptions/<sub>/providers/Microsoft.ContainerInstance/containerGroups (sub LIST)
      GET    .../containerGroups/<name>/containers/<container>/logs                     (typed refusal)

  Laws:

  - PUT validates the REAL containerGroup schema (containers array, image,
    resources.requests cpu/memoryInGB, ports, probes, osType, restartPolicy,
    ipAddress) — a hostile body refuses typed (`InvalidParameter` /
    `InvalidRequestContent`) BEFORE any store write, never a lazy runtime
    crash (same fail-closed face as the router's shacl-fuzz fences).
  - GET/LIST render a SIMULATED lifecycle for control-only groups:
    `provisioningState: Succeeded` + `instanceView.state: Running` with every
    container's `containerStatus.currentState.state: Running` from the
    recorded start time. That is the honest face of a control-plane-only
    group: the record exists and is provisioned; nothing executes. The
    render strips credential secrets (`password` never echoes — real ACI
    returns server + username only on GET).
  - `imageRegistryCredentials` are validated at PUT time against the real
    ACR control-plane rows (T-01): each credential's server must resolve to a
    registry row keyed `.../providers/Microsoft.ContainerRegistry/registries/<name>`
    in `Smalt.Store` (`:smalt_resources`), else the PUT refuses typed
    (`InaccessibleImageRegistry`) — pointing `az container create` at a
    nonexistent registry fails, exactly as Azure refuses the deployment. When
    the registry row publishes keys and the credential carries a password,
    the key must be one of its keys.
  - The `logs` action is a TYPED refusal: `logs_refusal/2` answers the
    `NotSupportedOnSubstrate`-class constant — execution is not emulated, so
    there are no logs to read and none are ever fabricated. Fail-closed, not
    a synthetic log stream.
  """

  alias Smalt.Store

  @provider_ns "Microsoft.ContainerInstance"
  @resource_type "containerGroups"
  @full_type @provider_ns <> "/" <> @resource_type

  # Real ACI api-version ladder (swagger releases); the latest is the pinned
  # ceiling. The type is NOT an admitted Registry type (no map row — the T-10
  # ticket evidence), so the pass-through plug validates against THIS ladder
  # instead of Smalt.Registry.
  @api_versions [
    "2018-10-01",
    "2019-12-01",
    "2020-10-01",
    "2021-03-01",
    "2021-09-01",
    "2021-10-01",
    "2022-09-01",
    "2023-02-01",
    "2023-05-01",
    "2024-03-01"
  ]
  @latest_api_version "2024-03-01"

  @os_types ["Linux", "Windows"]
  @restart_policies ["Always", "OnFailure", "Never"]
  @protocols ["TCP", "UDP"]
  @acr_registry_suffix "/providers/microsoft.containerregistry/registries/"

  # The typed logs-refusal constant (never fake logs). Rendered by the router
  # on the containers/<name>/logs action; asserted verbatim by the court.
  @logs_refusal_code "NotSupportedOnSubstrate"

  def full_type, do: @full_type

  def provider_ns, do: @provider_ns

  def resource_type, do: @resource_type

  def api_versions, do: @api_versions

  def latest_api_version, do: @latest_api_version

  def logs_refusal_code, do: @logs_refusal_code

  # --- ids / keys -----------------------------------------------------------------

  @doc "Full ARM id (wire casing preserved) of a container group."
  def group_wire_id(sub_id, rg, name),
    do: "/subscriptions/#{sub_id}/resourceGroups/#{rg}/providers/#{@full_type}/#{name}"

  @doc "Store key (downcased ARM id) of a container group."
  def group_key(sub_id, rg, name), do: String.downcase(group_wire_id(sub_id, rg, name))

  # --- PUT ---------------------------------------------------------------------------

  @doc """
  Create-or-replace a container group. Returns `{:ok, view, created?}` —
  `created?` false on the idempotent re-PUT (201 vs 200 is the router's
  status decision) — or `{:error, code, message, target}` (typed 400).
  """
  def put_group(sub_id, rg, name, body) do
    key = group_key(sub_id, rg, name)

    with {:ok, body} <- body_map(body),
         {:ok, props} <- properties_map(body),
         :ok <- validate_containers(props, name),
         :ok <- validate_registry_credentials(props, name),
         props = hydrate_defaults(props),
         :ok <- validate_scalars(props),
         record = build_record(sub_id, rg, name, body, props) do
      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      :ok = Store.put(:smalt_resources, key, record)
      {:ok, view(record), not existed?}
    end
  end

  # --- GET / LIST --------------------------------------------------------------------

  @doc "Rendered wire view of one container group, or `:error`."
  def get_group(sub_id, rg, name) do
    case Store.get(:smalt_resources, group_key(sub_id, rg, name)) do
      {:ok, record} when is_map(record) -> {:ok, view(record)}
      _ -> :error
    end
  end

  @doc "Rendered container groups under a resource group (store-key order, deterministic)."
  def list_groups(sub_id, rg) do
    :smalt_resources
    |> Store.list_prefix(group_key(sub_id, rg, ""))
    |> Enum.flat_map(fn record -> if is_map(record), do: [view(record)], else: [] end)
  end

  @doc "Rendered container groups across a subscription (RG-agnostic `az container list`)."
  def list_groups_subscription(sub_id) do
    needle = String.downcase("/providers/#{@full_type}/")
    sub_prefix = String.downcase("/subscriptions/#{sub_id}/")

    :smalt_resources
    |> Store.keys()
    |> Enum.filter(fn key ->
      String.starts_with?(key, sub_prefix) and String.contains?(key, needle)
    end)
    |> Enum.flat_map(fn key ->
      case Store.get(:smalt_resources, key) do
        {:ok, record} when is_map(record) -> [view(record)]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1["id"])
  end

  # --- DELETE ------------------------------------------------------------------------

  @doc """
  Deletes the group and any child rows (store-key prefix cascade, the
  handle_resource_delete law). `:ok` or `:error` (the router renders the 404
  and the LRO-202 faces).
  """
  def delete_group(sub_id, rg, name) do
    key = group_key(sub_id, rg, name)

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

  # --- logs refusal (never fake logs) -------------------------------------------------

  @doc """
  The typed logs refusal for the containers/<name>/logs action.
  `NotSupportedOnSubstrate`: the substrate does not emulate execution, so
  there is no log stream to return — and none is ever fabricated (design
  law, permanent non-goal).
  """
  def logs_refusal(group_name, container_name) do
    %{
      "code" => @logs_refusal_code,
      "message" =>
        "Container execution is not emulated by this substrate, so container group " <>
          "'#{group_name}' has never run container '#{container_name}' and no logs exist " <>
          "to read. The ARM control plane (create/show/list/delete) is fully served; " <>
          "log streaming is permanently out of scope and is never fabricated.",
      "target" => "containers/#{container_name}/logs",
      "innererror" => %{}
    }
  end

  # --- registry credential validation (T-01 seam) --------------------------------------

  @doc """
  Resolves an ACR registry row by login server (e.g. `myreg.azurecr.io`):
  strips the Azure CR DNS suffix to the registry name and looks for a store
  row keyed `.../providers/Microsoft.ContainerRegistry/registries/<name>`
  (downcased, providers segment included). `{:ok, row}` or `:error`.
  """
  def registry_row(server) when is_binary(server) do
    suffix = @acr_registry_suffix <> String.downcase(registry_name_of(server))

    :smalt_resources
    |> Store.keys()
    |> Enum.find(fn key -> String.ends_with?(key, suffix) end)
    |> case do
      nil -> :error
      key -> Store.get(:smalt_resources, key)
    end
  end

  def registry_row(_server), do: :error

  @doc "`myreg.azurecr.io` -> `myreg`; a bare registry name passes through."
  def registry_name_of(server) when is_binary(server) do
    case Regex.run(~r/^([a-z0-9][a-z0-9-]*)\.azurecr\.[a-z]{2,3}(\.[a-z]{2,3})?$/i, server) do
      [_, name] -> name
      nil -> server
    end
  end

  def registry_name_of(_other), do: nil

  # --- simulated lifecycle view --------------------------------------------------------

  @doc """
  The wire view of a stored group record: the ARM envelope with the
  simulated control-plane-only lifecycle rendered — `provisioningState:
  Succeeded`, `instanceView.state: Running`, every container's
  `containerStatus.currentState.state: Running` from the recorded start —
  plus a synthesized deterministic `ipAddress.ip` when the developer did not
  pin one (real ACI assigns an IP at provision). The internal start-time
  member is stripped; empty tags render null (the tags law shared with the
  main router — echoing `{}` drifts every refresh-only plan).
  """
  def view(record) when is_map(record) do
    props = record["properties"] || %{}
    started = record["smalt_started_at"]
    name = record["name"]

    base =
      record
      |> Map.drop(["smalt_started_at"])
      |> Map.put("type", @full_type)
      |> Map.put("tags", normalize_tags(record["tags"]))

    properties =
      props
      |> Map.put("provisioningState", "Succeeded")
      |> Map.put("instanceView", instance_view(props, started))
      |> maybe_assign_ip(name)
      |> strip_credential_passwords()

    Map.put(base, "properties", properties)
  end

  def view(_record), do: %{}

  # Real ACI never echoes the registry credential secret on GET — the wire
  # view carries server + username only.
  defp strip_credential_passwords(%{"imageRegistryCredentials" => creds} = props)
       when is_list(creds) do
    Map.put(props, "imageRegistryCredentials", Enum.map(creds, &strip_password/1))
  end

  defp strip_credential_passwords(props), do: props

  defp strip_password(c) when is_map(c), do: Map.delete(c, "password")
  defp strip_password(c), do: c

  defp instance_view(props, started) do
    containers = props["containers"] || []

    %{
      "events" => [],
      "state" => "Running",
      "containers" =>
        Enum.map(containers, fn c ->
          %{
            "name" => c["name"],
            "containerStatus" => %{
              "currentState" => %{"state" => "Running", "startTime" => started},
              "restartCount" => 0
            }
          }
        end)
    }
  end

  defp maybe_assign_ip(props, name) do
    case props["ipAddress"] do
      ip when is_map(ip) and not is_map_key(ip, "ip") ->
        Map.put(props, "ipAddress", Map.put(ip, "ip", synth_ip(name)))

      _ ->
        props
    end
  end

  defp synth_ip(name) do
    "10.96.#{:erlang.phash2(name, 254) + 1}.#{:erlang.phash2({name, :ip}, 254) + 1}"
  end

  defp normalize_tags(nil), do: nil
  defp normalize_tags(%{} = tags), do: if(map_size(tags) == 0, do: nil, else: tags)
  defp normalize_tags(_), do: nil

  # --- PUT validation (real schema, fail-closed) ---------------------------------------

  defp body_map(%{} = body), do: {:ok, body}

  defp body_map(_),
    do:
      {:error, "InvalidRequestContent",
       "The request content was invalid and could not be deserialized.", nil}

  defp properties_map(%{"properties" => %{} = props}), do: {:ok, props}

  defp properties_map(_),
    do:
      {:error, "InvalidRequestContent",
       "The request content was invalid and could not be deserialized.", "properties"}

  defp hydrate_defaults(props) do
    props
    |> Map.put_new("osType", "Linux")
    |> Map.put_new("restartPolicy", "Always")
  end

  # --- containers array + per-container schema -----------------------------------------

  defp validate_containers(props, group_name) do
    case props["containers"] do
      containers when is_list(containers) and containers != [] ->
        containers
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {container, i}, _acc ->
          case validate_container(container, group_name, i) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      _ ->
        {:error, "InvalidParameter",
         "Container group '#{group_name}' must specify at least one container.",
         "properties.containers"}
    end
  end

  defp validate_container(container, group_name, i) when is_map(container) do
    name = container["name"]
    cp = container["properties"]
    base = "properties.containers[#{i}]"

    cond do
      not (is_binary(name) and name != "") ->
        {:error, "InvalidParameter",
         "Container #{i} of container group '#{group_name}' must specify a name.", base <> ".name"}

      not is_map(cp) ->
        {:error, "InvalidParameter", "Container '#{name}' must carry a properties object.",
         base <> ".properties"}

      true ->
        where = base <> ".properties"

        with :ok <- require_image(cp, name, where),
             :ok <- require_resources(cp, name, where),
             :ok <- validate_ports(cp["ports"], where),
             :ok <- validate_environment(cp["environmentVariables"], where),
             :ok <- validate_probe(cp["livenessProbe"], "livenessProbe", where, name),
             :ok <- validate_probe(cp["readinessProbe"], "readinessProbe", where, name) do
          :ok
        end
    end
  end

  defp validate_container(_other, group_name, i) do
    {:error, "InvalidParameter",
     "Container #{i} of container group '#{group_name}' must be an object with a name and properties.",
     "properties.containers[#{i}]"}
  end

  defp require_image(cp, name, where) do
    case cp["image"] do
      image when is_binary(image) and image != "" ->
        :ok

      _ ->
        {:error, "InvalidParameter", "Container '#{name}' must specify an image.", "#{where}.image"}
    end
  end

  defp require_resources(cp, name, where) do
    case cp["resources"] do
      %{"requests" => req} when is_map(req) ->
        where_req = "#{where}.resources.requests"

        with :ok <- require_number(req["cpu"], name, "#{where_req}.cpu", "cpu"),
             :ok <- require_number(req["memoryInGB"], name, "#{where_req}.memoryInGB", "memoryInGB") do
          :ok
        end

      _ ->
        {:error, "InvalidParameter",
         "Container '#{name}' must specify resources.requests with cpu and memoryInGB.",
         "#{where}.resources.requests"}
    end
  end

  defp require_number(v, _name, _target, _field) when is_number(v) and v > 0, do: :ok

  defp require_number(_v, name, target, field),
    do:
      {:error, "InvalidParameter", "Container '#{name}' must specify a positive number for #{field}.",
       target}

  # --- ports / environment / probes ------------------------------------------------------

  # defguardp (not defp): used inside guard heads of the probe validators
  # below; defguardp macros expand in guards and bodies alike.
  defguardp valid_port?(port) when is_integer(port) and port >= 1 and port <= 65_535

  defp validate_ports(nil, _where), do: :ok

  defp validate_ports(ports, where) when is_list(ports) do
    ports
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {port, i}, _acc ->
        target = "#{where}.ports[#{i}]"

        cond do
          not is_map(port) ->
            {:halt,
             {:error, "InvalidParameter", "Container port must be an object with a port member.",
              target}}

          not valid_port?(port["port"]) ->
            {:halt,
             {:error, "InvalidParameter", "Container port must be an integer between 1 and 65535.",
              target}}

          true ->
            case port["protocol"] do
              nil -> {:cont, :ok}
              p when p in @protocols -> {:cont, :ok}
              _ -> {:halt, {:error, "InvalidParameter", "Container port protocol must be TCP or UDP.", target}}
            end
        end
    end)
  end

  defp validate_ports(_other, where),
    do: {:error, "InvalidParameter", "Container ports must be an array of port objects.", where}

  defp validate_environment(nil, _where), do: :ok

  defp validate_environment(vars, where) when is_list(vars) do
    bad =
      Enum.find_index(vars, fn v ->
        not (is_map(v) and is_binary(v["name"]) and v["name"] != "")
      end)

    if bad do
      {:error, "InvalidParameter", "Every environment variable must carry a name.",
       "#{where}.environmentVariables[#{bad}]"}
    else
      :ok
    end
  end

  defp validate_environment(_other, where),
    do:
      {:error, "InvalidParameter", "environmentVariables must be an array.",
       "#{where}.environmentVariables"}

  # Probes: 80/20 of the real probe schema — a handler (exec | httpGet |
  # tcpSocket) plus non-negative integer timings; anything else refuses
  # typed instead of lazily crashing the lifecycle renderer.
  defp validate_probe(nil, _field, _where, _name), do: :ok

  defp validate_probe(probe, field, where, name) when is_map(probe) do
    target = "#{where}.#{field}"

    cond do
      not probe_timings_ok?(probe) ->
        {:error, "InvalidParameter", "Probe timings must be non-negative integers.", target}

      valid_exec?(probe) or valid_http_get?(probe) or valid_tcp_socket?(probe) ->
        :ok

      true ->
        {:error, "InvalidParameter",
         "Probe of container '#{name}' must specify one of exec, httpGet or tcpSocket.", target}
    end
  end

  defp validate_probe(_other, field, where, name),
    do:
      {:error, "InvalidParameter", "Probe of container '#{name}' must be an object.",
       "#{where}.#{field}"}

  defp valid_exec?(%{"exec" => exec}) when is_list(exec), do: Enum.all?(exec, &is_binary/1)
  defp valid_exec?(_), do: false

  defp valid_http_get?(%{"httpGet" => %{"path" => path, "port" => port}})
       when is_binary(path) and valid_port?(port),
       do: true

  defp valid_http_get?(_), do: false

  defp valid_tcp_socket?(%{"tcpSocket" => %{"port" => port}}) when valid_port?(port), do: true
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

  # --- scalars: osType / restartPolicy / ipAddress ---------------------------------------

  defp validate_scalars(props) do
    with :ok <- one_of(props["osType"], @os_types, "properties.osType", "osType must be Linux or Windows."),
         :ok <- one_of(props["restartPolicy"], @restart_policies, "properties.restartPolicy",
                 "restartPolicy must be Always, OnFailure or Never.") do
      validate_ip_address(props["ipAddress"])
    end
  end

  defp one_of(v, allowed, target, msg) do
    if v in allowed, do: :ok, else: {:error, "InvalidParameter", msg, target}
  end

  defp validate_ip_address(nil), do: :ok

  defp validate_ip_address(ip) when is_map(ip) do
    cond do
      ip["type"] not in ["Public", "Private"] ->
        {:error, "InvalidParameter", "ipAddress.type must be Public or Private.",
         "properties.ipAddress.type"}

      not (is_list(ip["ports"]) and ip["ports"] != []) ->
        {:error, "InvalidParameter", "ipAddress must expose at least one port.",
         "properties.ipAddress.ports"}

      true ->
        validate_ports(ip["ports"], "properties.ipAddress")
    end
  end

  defp validate_ip_address(_other),
    do: {:error, "InvalidParameter", "ipAddress must be an object.", "properties.ipAddress"}

  # --- imageRegistryCredentials: format + registry existence at PUT time -----------------

  defp validate_registry_credentials(props, group_name) do
    case props["imageRegistryCredentials"] do
      nil ->
        :ok

      creds when is_list(creds) ->
        creds
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {cred, i}, _acc ->
          case validate_credential(cred, group_name, i) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      _ ->
        {:error, "InvalidImageRegistryCredentialFormat",
         "The image registry credential format of container group '#{group_name}' is not valid.",
         "properties.imageRegistryCredentials"}
    end
  end

  defp validate_credential(cred, group_name, i) when is_map(cred) do
    target = "properties.imageRegistryCredentials[#{i}]"

    cond do
      not (is_binary(cred["server"]) and cred["server"] != "") ->
        {:error, "InvalidImageRegistryCredentialFormat",
         "The image registry credential format of container group '#{group_name}' is not valid: a server is required.",
         target}

      not (is_binary(cred["username"]) and cred["username"] != "") ->
        {:error, "InvalidImageRegistryCredentialFormat",
         "The image registry credential format of container group '#{group_name}' is not valid: a username is required.",
         target}

      true ->
        validate_credential_registry(cred["server"], cred["password"], target)
    end
  end

  defp validate_credential(_cred, group_name, i) do
    {:error, "InvalidImageRegistryCredentialFormat",
     "The image registry credential format of container group '#{group_name}' is not valid.",
     "properties.imageRegistryCredentials[#{i}]"}
  end

  defp validate_credential_registry(server, password, target) do
    name = registry_name_of(server)

    case registry_row(server) do
      {:ok, row} when is_map(row) ->
        if key_admitted?(row, password) do
          :ok
        else
          {:error, "InvalidImageRegistryCredential",
           "The image registry credential for server '#{server}' is not valid: the supplied key " <>
             "is not one of the registry's listed keys.",
           target}
        end

      _ ->
        {:error, "InaccessibleImageRegistry",
         "The image registry '#{server}' could not be accessed: no registry '#{name}' exists " <>
           "in this substrate (expected a store row keyed .../providers/" <>
           "Microsoft.ContainerRegistry/registries/#{name}).",
         target}
    end
  end

  # No published keys on the registry row -> existence is the law (T-01 rows
  # need not carry admin keys). Keys published AND a password supplied -> the
  # key must be one of them (ticket scope: "key must be one of its keys").
  # No password supplied -> nothing to check.
  defp key_admitted?(_row, nil), do: true

  defp key_admitted?(row, password) do
    case registry_keys(row) do
      nil -> true
      keys -> password in keys
    end
  end

  defp registry_keys(%{"properties" => props}) when is_map(props) do
    cond do
      keys = props["keys"] -> normalize_keys(keys)
      passwords = props["passwords"] -> normalize_keys(passwords)
      true -> nil
    end
  end

  defp registry_keys(_row), do: nil

  defp normalize_keys(keys) when is_list(keys),
    do: for(k <- keys, v = key_value(k), is_binary(v), do: v)

  defp normalize_keys(_), do: nil

  defp key_value(k) when is_binary(k), do: k
  defp key_value(%{"value" => v}), do: v
  defp key_value(_), do: nil

  # --- record -----------------------------------------------------------------------------

  defp build_record(sub_id, rg, name, body, props) do
    %{
      "id" => group_wire_id(sub_id, rg, name),
      "name" => name,
      "type" => @full_type,
      "location" => body["location"],
      "tags" => body["tags"],
      "properties" => props,
      # Internal: the simulated lifecycle start (stripped from wire views).
      "smalt_started_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end
end

defmodule Smalt.ServengineSim.ContainerFsPreflight do
  @moduledoc """
  Simulates non-root `USER nobody` container boot preflight checks for `xaas` /
  ServEngine deployments.

  Models the Cloud Run / Docker release failure classes documented in
  `GAP-SIM-A2A-FILESTORE`, `GAP-SIM-RUNTIME-EKV-CLUSTER`, and
  `GAP-SIM-RUNTIME-PROD-SECRETS`:

    1. Non-root runtime identity (`USER nobody`, uid `65534`, unwritable
       `HOME=/nonexistent`).
    2. `XAAS_A2A_DATA_DIR` must be explicitly configured, canonicalized under
       `/app`, writable by `nobody`, and never `/var/lib/xaas` (or any subpath
       under `/var/lib/xaas`).
    3. `XAAS_PPLAN_DETS_PATH` must be explicitly configured (no silent fallback
       to `~/.xaas/pplan_durable_store`), canonicalized under `/app`, writable
       by `nobody`, and never under `/var/lib/xaas`.
    4. `ash_a2a` EKV quorum requires `cluster_size >= 3` on
       `:receipt_store_ekv_opts` (and on `:authority_broker` EKV opts when
       configured).

  When `:sandbox_root` is passed, container paths under `/` are mapped into
  the temporary directory on disk and verified with real directory creation and
  write/remove probes; otherwise the check evaluates against the simulated
  `USER nobody` container filesystem policy.
  """

  @app_root "/app"
  @refused_root "/var/lib/xaas"
  @min_cluster_size 3
  @nobody_uid 65_534
  @nobody_gid 65_534

  @type violation ::
          {:root_user_forbidden, map()}
          | {:missing_env, String.t()}
          | {:relative_path, String.t(), String.t()}
          | {:refused_var_lib_xaas, String.t(), String.t()}
          | {:outside_app_root, String.t(), String.t()}
          | {:not_writable, String.t(), String.t(), term()}
          | {:path_collision, String.t()}
          | {:insufficient_cluster_size, :receipt_store | :authority_broker, integer()}
          | {:invalid_cluster_size, :receipt_store | :authority_broker, term()}

  @type report :: %{
          status: :ok,
          user: map(),
          xaas_a2a_data_dir: String.t(),
          xaas_pplan_dets_path: String.t(),
          cluster_size: pos_integer(),
          authority_broker_cluster_size: pos_integer() | nil,
          probed_on_disk?: boolean()
        }

  defmodule Error do
    @moduledoc "Raised by `Smalt.ServengineSim.ContainerFsPreflight.check!/1` on preflight refusal."
    defexception [:violations]

    @impl true
    def message(%__MODULE__{violations: violations}) do
      formatted = Enum.map_join(violations, "; ", &inspect/1)
      "container fs preflight refused boot: [#{formatted}]"
    end
  end

  @doc """
  Default `USER nobody` container filesystem specification.
  """
  @spec default_container_spec() :: map()
  def default_container_spec do
    %{
      user: %{name: "nobody", uid: @nobody_uid, gid: @nobody_gid, home: "/nonexistent"},
      app_root: @app_root,
      refused_roots: [@refused_root],
      min_cluster_size: @min_cluster_size,
      writable_roots: [@app_root]
    }
  end

  @doc """
  Runs all simulated `USER nobody` container boot preflight checks.

  Returns `{:ok, report}` when every check passes, or `{:error, violations}`
  listing every failed check.

  ## Options

    * `:env` - Map of environment variables (e.g. `%{"XAAS_A2A_DATA_DIR" => ...}`).
      Unset keys fall back to `System.get_env/1`.
    * `:user` - Simulated user (`"nobody"`, `"root"`, or a map with `:name` / `:uid`).
      Defaults to `%{name: "nobody", uid: 65534, gid: 65534, home: "/nonexistent"}`.
    * `:ash_a2a` - Keyword list or map mirroring `config :ash_a2a`
      (`:receipt_store_ekv_opts`, `:authority_broker`, `:authority_broker_ekv_opts`,
      or `:cluster_size`).
    * `:writable_roots` - List of container paths writable by `:user` in virtual mode.
      Defaults to `["/app"]`.
    * `:readonly_paths` - List of container paths (subtrees) explicitly marked
      read-only / unwritable in virtual mode. Defaults to `[]`.
    * `:sandbox_root` - Optional host directory mapped as container `/`. When set,
      writable paths are probed on disk via `File.mkdir_p/1` and file write/delete.
  """
  @spec check(keyword() | map()) :: {:ok, report()} | {:error, [violation()]}
  def check(opts \\ []) do
    opts = Map.new(opts)
    user = normalize_user(Map.get(opts, :user, default_container_spec().user))
    env = Map.get(opts, :env, %{})
    ash_a2a = Map.get(opts, :ash_a2a, [])
    sandbox_root = Map.get(opts, :sandbox_root)
    writable_roots = Map.get(opts, :writable_roots, [@app_root])
    readonly_paths = Map.get(opts, :readonly_paths, [])

    fs_ctx = %{
      user: user,
      sandbox_root: sandbox_root,
      writable_roots: Enum.map(writable_roots, &Path.expand/1),
      readonly_paths: Enum.map(readonly_paths, &Path.expand/1)
    }

    user_violations = check_user(user)

    {a2a_path, a2a_violations} =
      check_container_path("XAAS_A2A_DATA_DIR", fetch_env(env, "XAAS_A2A_DATA_DIR"), :dir, fs_ctx)

    {pplan_path, pplan_violations} =
      check_container_path(
        "XAAS_PPLAN_DETS_PATH",
        fetch_env(env, "XAAS_PPLAN_DETS_PATH"),
        :path,
        fs_ctx
      )

    collision_violations = check_path_collision(a2a_path, pplan_path)
    {receipt_cs, broker_cs, cluster_violations} = check_cluster_sizes(ash_a2a, env)

    violations =
      user_violations ++
        a2a_violations ++
        pplan_violations ++
        collision_violations ++
        cluster_violations

    if violations == [] do
      {:ok,
       %{
         status: :ok,
         user: user,
         xaas_a2a_data_dir: a2a_path,
         xaas_pplan_dets_path: pplan_path,
         cluster_size: receipt_cs,
         authority_broker_cluster_size: broker_cs,
         probed_on_disk?: not is_nil(sandbox_root)
       }}
    else
      {:error, violations}
    end
  end

  @doc """
  Same as `check/1`, returning the report on `:ok` or raising
  `Smalt.ServengineSim.ContainerFsPreflight.Error` on refusal.
  """
  @spec check!(keyword() | map()) :: report()
  def check!(opts \\ []) do
    case check(opts) do
      {:ok, report} -> report
      {:error, violations} -> raise Error, violations: violations
    end
  end

  @doc """
  True when `path` resolves to `root` or a descendant of `root` after lexical
  normalization (`Path.expand/1`).
  """
  @spec under_dir?(String.t(), String.t()) :: boolean()
  def under_dir?(path, root) when is_binary(path) and is_binary(root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or
      String.starts_with?(expanded_path, String.trim_trailing(expanded_root, "/") <> "/")
  end

  # --- User check ---

  defp normalize_user(name) when is_binary(name) do
    if name == "root" do
      %{name: "root", uid: 0, gid: 0, home: "/root"}
    else
      %{name: name, uid: @nobody_uid, gid: @nobody_gid, home: "/nonexistent"}
    end
  end

  defp normalize_user(user) when is_map(user) do
    %{
      name: Map.get(user, :name, "nobody"),
      uid: Map.get(user, :uid, @nobody_uid),
      gid: Map.get(user, :gid, @nobody_gid),
      home: Map.get(user, :home, "/nonexistent")
    }
  end

  defp check_user(%{name: "root"} = user), do: [{:root_user_forbidden, user}]
  defp check_user(%{uid: 0} = user), do: [{:root_user_forbidden, user}]
  defp check_user(_user), do: []

  # --- Path & writable checks ---

  defp fetch_env(env, key) when is_map(env) do
    case Map.fetch(env, key) do
      {:ok, val} -> val
      :error -> System.get_env(key)
    end
  end

  defp check_container_path(env_name, nil, _kind, _fs_ctx),
    do: {nil, [{:missing_env, env_name}]}

  defp check_container_path(env_name, raw, kind, fs_ctx) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {nil, [{:missing_env, env_name}]}

      not String.starts_with?(trimmed, "/") ->
        {nil, [{:relative_path, env_name, trimmed}]}

      true ->
        expanded = Path.expand(trimmed)

        cond do
          under_dir?(expanded, @refused_root) ->
            {expanded, [{:refused_var_lib_xaas, env_name, expanded}]}

          not under_dir?(expanded, @app_root) ->
            {expanded, [{:outside_app_root, env_name, expanded}]}

          true ->
            case verify_writable(expanded, kind, fs_ctx) do
              :ok -> {expanded, []}
              {:error, reason} -> {expanded, [{:not_writable, env_name, expanded, reason}]}
            end
        end
    end
  end

  defp check_container_path(env_name, other, _kind, _fs_ctx),
    do: {nil, [{:relative_path, env_name, inspect(other)}]}

  defp verify_writable(expanded, kind, %{sandbox_root: nil} = fs_ctx) do
    cond do
      Enum.any?(fs_ctx.readonly_paths, &under_dir?(expanded, &1)) ->
        {:error, :eacces}

      Enum.any?(fs_ctx.writable_roots, &under_dir?(expanded, &1)) ->
        :ok

      true ->
        {:error, {:unwritable_by_user, fs_ctx.user.name, kind}}
    end
  end

  defp verify_writable(expanded, kind, %{sandbox_root: sandbox_root} = fs_ctx)
       when is_binary(sandbox_root) do
    cond do
      Enum.any?(fs_ctx.readonly_paths, &under_dir?(expanded, &1)) ->
        {:error, :eacces}

      not Enum.any?(fs_ctx.writable_roots, &under_dir?(expanded, &1)) ->
        {:error, {:unwritable_by_user, fs_ctx.user.name, kind}}

      true ->
        probe_sandbox_path(expanded, kind, sandbox_root)
    end
  end

  defp probe_sandbox_path(container_path, kind, sandbox_root) do
    rel = String.trim_leading(container_path, "/")
    host_path = Path.join(sandbox_root, rel)

    target_dir =
      case kind do
        :dir -> host_path
        :path -> Path.dirname(host_path)
      end

    with :ok <- ensure_dir_writable(target_dir),
         :ok <- write_and_remove_probe(target_dir) do
      :ok
    end
  end

  defp ensure_dir_writable(dir) do
    case File.mkdir_p(dir) do
      :ok -> check_stat_writable(dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_stat_writable(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{access: access}} when access in [:read_write, :write] -> :ok
      {:ok, %File.Stat{}} -> {:error, :eacces}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_and_remove_probe(dir) do
    probe = Path.join(dir, ".preflight_probe_#{System.unique_integer([:positive])}")

    case File.write(probe, "ok") do
      :ok ->
        _ = File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_path_collision(a2a, pplan) when is_binary(a2a) and is_binary(pplan) do
    if a2a == pplan do
      [{:path_collision, a2a}]
    else
      []
    end
  end

  defp check_path_collision(_a2a, _pplan), do: []

  # --- ash_a2a cluster_size >= 3 checks ---

  defp check_cluster_sizes(ash_a2a, env) do
    ash_map = to_map(ash_a2a)
    ekv_opts = to_map(Map.get(ash_map, :receipt_store_ekv_opts, []))

    raw_receipt_cs =
      Map.get(
        ekv_opts,
        :cluster_size,
        Map.get(ash_map, :cluster_size, parse_env_cluster_size(env))
      )

    {receipt_cs, receipt_violations} = validate_cluster_size(:receipt_store, raw_receipt_cs)

    {broker_cs, broker_violations} =
      case extract_broker_cluster_size(ash_map) do
        :not_configured -> {nil, []}
        {:ok, raw_broker_cs} -> validate_cluster_size(:authority_broker, raw_broker_cs)
      end

    {receipt_cs, broker_cs, receipt_violations ++ broker_violations}
  end

  defp extract_broker_cluster_size(ash_map) do
    cond do
      Map.has_key?(ash_map, :authority_broker_ekv_opts) ->
        opts = to_map(Map.get(ash_map, :authority_broker_ekv_opts))
        {:ok, Map.get(opts, :cluster_size, 1)}

      match?({_mod, opts} when is_list(opts) or is_map(opts), Map.get(ash_map, :authority_broker)) ->
        {_mod, opts} = Map.get(ash_map, :authority_broker)
        {:ok, Map.get(to_map(opts), :cluster_size, 1)}

      true ->
        :not_configured
    end
  end

  defp parse_env_cluster_size(env) do
    case fetch_env(env, "ASH_A2A_EKV_CLUSTER_SIZE") do
      nil ->
        1

      "" ->
        1

      val when is_binary(val) ->
        case Integer.parse(String.trim(val)) do
          {n, ""} -> n
          _ -> val
        end

      other ->
        other
    end
  end

  defp validate_cluster_size(_component, n) when is_integer(n) and n >= @min_cluster_size,
    do: {n, []}

  defp validate_cluster_size(component, n) when is_integer(n),
    do: {n, [{:insufficient_cluster_size, component, n}]}

  defp validate_cluster_size(component, invalid),
    do: {nil, [{:invalid_cluster_size, component, invalid}]}

  defp to_map(val) when is_map(val), do: val
  defp to_map(val) when is_list(val), do: Map.new(val)
  defp to_map(_), do: %{}
end

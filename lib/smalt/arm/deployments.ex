defmodule Smalt.Arm.Deployments do
  @moduledoc """
  ARM deployments faces (wave-6 lane w6i-2, v26.10.20).

  Azure parity surface:

    - PUT/GET/DELETE/LIST deployments at both scopes:
        /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Resources/deployments/{name}
        /subscriptions/{sub}/providers/Microsoft.Resources/deployments/{name}
    - POST .../validate → 200 with an error envelope (code InvalidTemplate +
      details array) on a malformed template; 200 success on a well-formed one.
    - deploymentOperations list child route (echo face over the stored record).

  Storage: shadow ETS `:smalt_arm_deployments` created lazily with a 3-tuple
  `:heir` to the init process, so a request-scoped owner death cannot silently
  disarm the table (the silent-disarm class fixed across v26.10.19). Records
  hold template, parameters, mode, provisioningState (Succeeded on admission).
  """

  @table :smalt_arm_deployments

  @doc "Lazily create the two shadow tables. Heir'd to init (3-tuple option form)."
  @spec ensure_table() :: :ok
  def ensure_table do
    ensure_one(@table)

    ensure_one(ops_table())

    :ok
  end

  defp ensure_one(table) do
    case :ets.info(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :set,
          :public,
          {:read_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])

        :ok

      _ ->
        :ok
    end
  end

  defp ops_table, do: :"#{@table}_ops"

  # scope key: {sub, rg | nil, name}
  defp record_key(sub, rg, name), do: {sub, rg, name}

  @doc """
  PUT a deployment: validates the body, stores template+parameters with
  provisioningState Succeeded. `{:ok, deployment_map}` |
  `{:error, status, error_map}`.
  """
  @spec put_deployment(String.t(), String.t() | nil, String.t(), map()) ::
          {:ok, map()} | {:error, non_neg_integer(), map()}
  def put_deployment(sub, rg, name, body) when is_map(body) do
    ensure_table()

    case validate_template_payload(body) do
      :ok ->
        props = body["properties"] || %{}
        template = props["template"] || %{}

        # AZURE-FIDELITY lane 2: the template's resources must each be an
        # admitted shape (map with binary type/name, registered type) — the
        # same gate validate_deployment runs, enforced on PUT too so a bad
        # template can never half-materialize.
        with :ok <- Smalt.ArmGateway.Deployments.validate_resources(template) do
          accepted_at = DateTime.utc_now() |> DateTime.to_iso8601()
          started_at = accepted_at

          rec = %{
            name: name,
            sub: sub,
            rg: rg,
            template: template,
            parameters: props["parameters"] || %{},
            mode: props["mode"] || "Incremental",
            provisioning_state: "Succeeded",
            created: accepted_at,
            accepted_at: accepted_at,
            started_at: started_at,
            # ARMSTRONG fix 3: correlationId is a minted make_ref stored on the
            # record — referentially stable across GET/PUT renders, unique per
            # admission; no incremental System.unique_integer leakage.
            correlation_id: inspect(make_ref())
          }

          key = record_key(sub, rg, name)

          # Materialize AFTER the record insert, BEFORE the wire answer: the
          # deployed resources land in :smalt_resources (RG listings see them)
          # and each yields a per-resource deploymentOperations entry.
          materialized =
            if is_binary(rg),
              do: Smalt.ArmGateway.Deployments.materialize(sub, rg, name, template),
              else: {:ok, %{ops: []}}

          {:ok, %{ops: ops}} = materialized

          completed_at = DateTime.utc_now() |> DateTime.to_iso8601()

          rec = Map.put(rec, :completed_at, completed_at)
          :ets.insert(@table, {key, rec})

          # Per-resource deploymentOperations (real ARM shape: one entry per
          # template resource with targetResource + timestamp). A template
          # with zero resources keeps the single admission echo op.
          wire_ops =
            if ops == [] do
              [echo_op(name, accepted_at)]
            else
              ops
            end

          :ets.insert(ops_table(), {key, wire_ops})

          {:ok, deployment_map(rec, key)}
        end

      err ->
        err
    end
  end

  defp echo_op(name, now) do
    op_id = "op-" <> inspect(make_ref())

    %{
      "id" => "/deployments/#{name}/operations/#{op_id}",
      "operationId" => op_id,
      "properties" => %{
        "provisioningOperation" => "Create",
        "provisioningState" => "Succeeded",
        "timestamp" => now
      }
    }
  end

  @doc """
  GET one deployment. `{:ok, deployment_map}` | `{:error, 404, error_map}`.
  """
  @spec get_deployment(String.t(), String.t() | nil, String.t()) ::
          {:ok, map()} | {:error, non_neg_integer(), map()}
  def get_deployment(sub, rg, name) do
    ensure_table()

    case :ets.lookup(@table, record_key(sub, rg, name)) do
      [{_key, rec}] -> {:ok, deployment_map(rec, record_key(sub, rg, name))}
      [] -> {:error, 404, not_found(name)}
    end
  end

  @doc """
  LIST deployments at a scope. `{:ok, [deployment_map]}`.
  """
  @spec list_deployments(String.t(), String.t() | nil) :: {:ok, [map()]}
  def list_deployments(sub, rg) do
    ensure_table()

    items =
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {{s, r, _n}, _rec} -> s == sub and r == rg end)
      |> Enum.sort(fn {{_, _, n1}, _}, {{_, _, n2}, _} -> n1 <= n2 end)
      |> Enum.map(fn {key, rec} -> deployment_map(rec, key) end)

    {:ok, items}
  end

  @doc """
  DELETE one deployment: 202 with the location-less async face real ARM uses,
  record removed.
  """
  @spec delete_deployment(String.t(), String.t() | nil, String.t()) ::
          {:ok, :deleted} | {:error, 404, map()}
  def delete_deployment(sub, rg, name) do
    ensure_table()
    key = record_key(sub, rg, name)

    case :ets.lookup(@table, key) do
      [{_key, _rec}] ->
        :ets.delete(@table, key)
        :ets.delete(ops_table(), key)
        {:ok, :deleted}

      [] ->
        {:error, 404, not_found(name)}
    end
  end

  @doc """
  POST validate: the same payload gate as PUT, but writes nothing.
  `{:ok, :valid}` | `{:error, status, error_map}`.
  """
  @spec validate_deployment(map()) :: {:ok, :valid} | {:error, non_neg_integer(), map()}
  def validate_deployment(body) when is_map(body) do
    case validate_template_payload(body) do
      :ok ->
        template = body["properties"]["template"] || %{}

        case Smalt.ArmGateway.Deployments.validate_resources(template) do
          :ok -> {:ok, :valid}
          err -> err
        end

      err ->
        err
    end
  end

  @doc "deploymentOperations list: `{:ok, [op_maps]}` | `{:error, 404, error_map}`."
  @spec list_operations(String.t(), String.t() | nil, String.t()) ::
          {:ok, [map()]} | {:error, non_neg_integer(), map()}
  def list_operations(sub, rg, name) do
    ensure_table()
    key = record_key(sub, rg, name)

    with {:ok, _rec} <- get_deployment(sub, rg, name) do
      ops =
        case :ets.lookup(ops_table(), key) do
          [{_k, ops}] -> ops
          [] -> []
        end

      {:ok, ops}
    end
  end

  # -- what-if face (wave-6 lane w6aq) ----------------------------------------------

  @doc """
  ARM what-if face (module-level): diff a template's resources against the
  REAL current ARM store (`:smalt_resources`, lowercased-armId keyed).

  Per template resource:

    - non-admitted type -> changeType "Ignore" (real what-if semantics).
    - known type, absent in store -> "Create".
    - known type, present, tags + top-level properties keys identical ->
      "NoChange".
    - differs -> "Modify" with a top-level properties delta
      (added/removed/changed keys).

  Scoping (documented choice): Delete entries are computed only for
  `mode: "Complete"`, only over resource types the template itself names,
  within the `:sub`/`:rg` scope passed in `opts`. Incremental mode never
  yields Delete (ARM Incremental law).
  """
  @spec what_if(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, 400, map()}
  def what_if(template, _parameters, opts \\ []) when is_map(template) and is_list(opts) do
    resources = template["resources"] || []
    sub = opts[:sub] || "smalt"
    rg = opts[:rg]
    mode = opts[:mode] || "Incremental"

    if not is_list(resources) do
      {:error, 400, invalid_template("template.resources must be an array", [])}
    else
      changes = resources |> Enum.map(&diff_resource(&1, sub, rg)) |> Enum.concat()

      deletes =
        if mode == "Complete" and is_binary(rg) do
          complete_mode_deletes(resources, sub, rg)
        else
          []
        end

      {:ok, %{"status" => "Succeeded", "changes" => Enum.concat(changes, deletes)}}
    end
  end

  @doc "Azure what-if wire envelope for the post-split router patch."
  def what_if_wire({:ok, result}) do
    %{
      "status" => result["status"],
      "properties" => %{"changes" => real_changes(result["changes"])}
    }
  end

  def what_if_wire({:error, status, error}) do
    {"error", status, error}
  end

  defp real_changes(changes), do: Enum.reject(changes, &(&1["changeType"] == "Ignore"))

  defp diff_resource(%{"type" => type} = res, sub, rg) when is_binary(type) do
    if Smalt.Registry.admitted?(type) do
      id = template_resource_id(res, sub, rg)

      case Smalt.Store.get(:smalt_resources, String.downcase(id)) do
        {:ok, existing} ->
          # AZURE-FIDELITY G1: diff against the projection — what materialize
          # WOULD store for this template resource (Defaults.apply + enrich +
          # record shape) — not the raw template. An identical re-deploy then
          # reads NoChange instead of Modify over enrichment-only keys.
          projected = Smalt.ArmGateway.Deployments.projected(res, sub, rg)

          if records_equal?(existing, projected) do
            [%{"changeType" => "NoChange", "resourceId" => id}]
          else
            [%{"changeType" => "Modify",
               "resourceId" => id,
               "before" => existing,
               "after" => projected,
               "delta" => properties_delta(existing, projected) ++ tags_delta(existing, projected)}]
          end

        _ ->
          [%{"changeType" => "Create",
             "resourceId" => id,
             "before" => nil,
             "after" => Smalt.ArmGateway.Deployments.projected(res, sub, rg),
             "delta" => []}]
      end
    else
      [%{"changeType" => "Ignore", "resourceId" => template_resource_id(res, sub, rg)}]
    end
  end

  # Comparable record surface: identity + the fields materialize writes.
  defp diff_resource(_res, _sub, _rg), do: [%{"changeType" => "Ignore", "resourceId" => ""}]

  # Comparable record surface: identity + the fields materialize writes.
  defp records_equal?(a, b) do
    Map.take(a, ~w(id name type location properties tags sku kind)) ==
      Map.take(b, ~w(id name type location properties tags sku kind))
  end

  defp template_resource_id(res, sub, rg) do
    type = res["type"]
    name = res["name"]
    prefix = if rg, do: "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/", else: "/subscriptions/#{sub}/providers/"

    if is_binary(type) and is_binary(name) do
      segs = String.split(type, "/")
      nsegs = length(segs) - 1
      name_segs = String.split(name, "/")

      if length(name_segs) == nsegs do
        prefix <> type <> "/" <> Enum.join(name_segs, "/")
      else
        prefix <> type <> "/" <> name
      end
    else
      prefix <> "unknown"
    end
  end

  defp properties_delta(existing, res) do
    ep = existing["properties"] || %{}
    rp = res["properties"] || %{}
    keys = MapSet.union(MapSet.new(Map.keys(ep)), MapSet.new(Map.keys(rp)))

    Enum.flat_map(keys, fn k ->
      cond do
        Map.has_key?(ep, k) and not Map.has_key?(rp, k) -> [remove_entry(k, ep[k])]
        not Map.has_key?(ep, k) and Map.has_key?(rp, k) -> [add_entry(k, rp[k])]
        ep[k] != rp[k] -> [update_entry(k, ep[k], rp[k])]
        true -> []
      end
    end)
  end

  defp add_entry(k, v), do: %{"propertyChangeType" => "Add", "path" => "properties." <> k, "before" => nil, "after" => v}

  defp remove_entry(k, v), do: %{"propertyChangeType" => "Remove", "path" => "properties." <> k, "before" => v, "after" => nil}

  defp update_entry(k, prev, next) do
    %{"propertyChangeType" => "Update", "path" => "properties." <> k, "before" => prev, "after" => next}
  end

  defp tags_delta(existing, res) do
    et = existing["tags"] || %{}
    rt = res["tags"] || %{}

    Enum.flat_map(MapSet.union(MapSet.new(Map.keys(et)), MapSet.new(Map.keys(rt))), fn k ->
      cond do
        Map.has_key?(et, k) and not Map.has_key?(rt, k) ->
          [%{"propertyChangeType" => "Remove", "path" => "tags." <> k, "before" => et[k], "after" => nil}]

        not Map.has_key?(et, k) and Map.has_key?(rt, k) ->
          [%{"propertyChangeType" => "Add", "path" => "tags." <> k, "before" => nil, "after" => rt[k]}]

        et[k] != rt[k] ->
          [%{"propertyChangeType" => "Update", "path" => "tags." <> k, "before" => et[k], "after" => rt[k]}]

        true ->
          []
      end
    end)
  end

  defp complete_mode_deletes(resources, sub, rg) do
    types =
      resources
      |> Enum.flat_map(fn
        %{"type" => t} when is_binary(t) -> [t]
        _ -> []
      end)
      |> Enum.uniq()

    Enum.flat_map(types, fn t ->
      prefix =
        ("/subscriptions/" <> sub <> "/resourceGroups/" <> rg <> "/providers/" <> String.downcase(t) <> "/")
        |> String.downcase()

      type_resource_names =
        resources
        |> Enum.filter(&match?(%{"type" => ^t}, &1))
        |> Enum.map(& &1["name"])

      Smalt.Store.list_prefix(:smalt_resources, prefix)
      |> Enum.flat_map(fn {key, row} ->
        if row_template_named?(key, row, type_resource_names) do
          []
        else
          [%{"changeType" => "Delete", "resourceId" => row["id"] || key}]
        end
      end)
    end)
  end

  defp row_template_named?(_key, _row, []), do: true
  defp row_template_named?(_key, row, names) do
    Enum.any?(names, fn n -> is_binary(n) and String.ends_with?(String.downcase(row["id"] || ""), "/" <> String.downcase(n)) end)
  end

  # -- payload gate ---------------------------------------------------------------

  defp validate_template_payload(body) do
    props = body["properties"] || %{}
    template = props["template"]
    mode = props["mode"]

    cond do
      not is_map(template) ->
        {:error, 400,
         invalid_template("template must be an object", [
           invalid_detail("properties.template", "the template must be an object")
         ])}

      not is_list(template["resources"] || []) ->
        {:error, 400,
         invalid_template("template.resources must be an array", [
           invalid_detail("properties.template.resources", "must be an array")
         ])}

      mode not in [nil, "Incremental", "Complete"] ->
        {:error, 400,
         invalid_template("mode must be Incremental or Complete", [
           invalid_detail("properties.mode", "Unknown mode. Valid values are Incremental or Complete")
         ])}

      true ->
        :ok
    end
  end

  # -- render helpers ---------------------------------------------------------------

  defp deployment_map(rec, {sub, rg, name}) do
    id =
      if rg do
        "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Resources/deployments/#{name}"
      else
        "/subscriptions/#{sub}/providers/Microsoft.Resources/deployments/#{name}"
      end

    %{
      "id" => id,
      "name" => name,
      # DIVERGENCE lane D4 (2026-10-25): DeploymentExtended documents a
      # top-level `type` ("Microsoft.Resources/deployments") and carries NO
      # top-level location — the null location was a key-extra divergence.
      "type" => "Microsoft.Resources/deployments",
      "properties" => %{
        "template" => rec.template,
        "parameters" => rec.parameters,
        "mode" => rec.mode,
        "provisioningState" => rec.provisioning_state,
        # Lifecycle timestamps (AZURE-FIDELITY lane 2): Accepted (request
        # receipt), Running (execution start), and timestamp/completedAt
        # (terminal Succeeded). The PUT face is synchronous, so accepted ==
        # started and completed lands in the same request; the fields are
        # kept distinct so an async face can diverge them later.
        "acceptedAt" => rec.accepted_at,
        "startedAt" => rec.started_at,
        "timestamp" => rec.completed_at || rec.created,
        "duration" => duration(rec),
        "correlationId" => rec.correlation_id
      }
    }
  end

  defp duration(rec) do
    completed = rec.completed_at || rec.created

    case {DateTime.from_iso8601(rec.accepted_at), DateTime.from_iso8601(completed)} do
      {{:ok, a, _}, {:ok, c, _}} ->
        ms = max(DateTime.diff(c, a, :millisecond), 0)
        "PT#{div(ms, 1000)}.#{rem(ms, 1000)}S"

      _ ->
        "PT0S"
    end
  end

  defp invalid_template(message, details) do
    %{
      "code" => "InvalidTemplate",
      "message" => message,
      "details" => details
    }
  end

  defp invalid_detail(path, msg) do
    %{"code" => "InvalidTemplate", "message" => "#{path}: #{msg}", "target" => path}
  end

  defp not_found(name) do
    %{
      "code" => "DeploymentNotFound",
      "message" => "Deployment '#{name}' could not be found."
    }
  end
end

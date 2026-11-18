defmodule Smalt.GCP.CloudRun do
  @moduledoc """
  Cloud Run Admin v2 plane engine (GS6). Wire-free: a router maps
  `/v2/projects/{p}/locations/{l}/services[...]` onto these functions.

  Rows live in `:smalt_resources` under keys prefixed `gcp:run:`. Mutations
  (create/replace/delete) return a done `operations/{id}` LRO (simulated:
  completes synchronously; NO container execution). Each template change
  mints a new immutable revision `{service}-{NNNNN}-{suffix}`.

  Typed divergences: ingress defaults to INGRESS_TRAFFIC_ALL; URIs are
  `https://{svc}-{project}.{region}.run.smalt.local`; IAM policy is stored
  per service with `roles/run.invoker` bindings, no condition evaluation.
  """

  alias Smalt.Store

  @table :smalt_resources
  @ingress ~w(INGRESS_TRAFFIC_ALL INGRESS_TRAFFIC_INTERNAL_ONLY
              INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER)

  def valid_ingress, do: @ingress

  defp skey(p, l, s), do: "gcp:run:svc:#{p}/#{l}/#{s}"
  defp rkey(p, l, s, r), do: "gcp:run:rev:#{p}/#{l}/#{s}/#{r}"
  defp okey(id), do: "gcp:run:op:#{id}"
  defp name(p, l, s), do: "projects/#{p}/locations/#{l}/services/#{s}"

  @spec create_service(String.t(), String.t(), String.t(), map) ::
          {:ok, map} | {:error, {integer, String.t(), String.t()}}
  def create_service(project, loc, service_id, body) do
    cond do
      not Regex.match?(~r/^[a-z]([a-z0-9-]{0,47}[a-z0-9])?$/, service_id) ->
        {:error, {400, "INVALID_ARGUMENT", "invalid serviceId"}}

      match?({:ok, _}, Store.get(@table, skey(project, loc, service_id))) ->
        {:error, {409, "ALREADY_EXISTS", "service #{service_id} already exists"}}

      true ->
        ingress = Map.get(body, "ingress") || "INGRESS_TRAFFIC_ALL"

        with :ok <- validate_ingress(ingress),
             :ok <- validate_template(Map.get(body, "template")) do
          svc = build(project, loc, service_id, body, ingress, 1, nil)
          Store.put(@table, skey(project, loc, service_id), svc)
          {:ok, op(name(project, loc, service_id), svc)}
        end
    end
  end

  def get_service(project, loc, service_id) do
    case Store.get(@table, skey(project, loc, service_id)) do
      {:ok, svc} -> {:ok, svc}
      :error -> {:error, {404, "NOT_FOUND", "service #{service_id} not found"}}
    end
  end

  def list_services(project, loc) do
    Store.list_prefix(@table, "gcp:run:svc:#{project}/#{loc}/")
  end

  @doc "Replace (PUT/PATCH semantics of UpdateService); template change => new revision."
  def replace_service(project, loc, service_id, body) do
    with {:ok, old} <- get_service(project, loc, service_id) do
      ingress = Map.get(body, "ingress") || old["ingress"]

      with :ok <- validate_ingress(ingress),
           :ok <- validate_template(Map.get(body, "template")) do
        gen = old["generation"] + 1
        incoming_template = Map.get(body, "template")
        changed = not is_nil(incoming_template) and incoming_template != old["template"]
        seq = if changed, do: old["_revSeq"] + 1, else: old["_revSeq"]
        svc = build(project, loc, service_id, Map.put(body, "iam", old["_iam"]), ingress, seq, old)
        svc = %{svc | "generation" => gen, "observedGeneration" => gen, "createTime" => old["createTime"]}
        Store.put(@table, skey(project, loc, service_id), svc)
        {:ok, op(name(project, loc, service_id), svc)}
      end
    end
  end

  def delete_service(project, loc, service_id) do
    with {:ok, svc} <- get_service(project, loc, service_id) do
      Store.delete(@table, skey(project, loc, service_id))

      for r <- list_revisions(project, loc, service_id) do
        Store.delete(@table, rkey(project, loc, service_id, r["name"] |> Path.basename()))
      end

      {:ok, op(name(project, loc, service_id), Map.put(svc, "deleteTime", now()))}
    end
  end

  def list_revisions(project, loc, service_id),
    do: Store.list_prefix(@table, "gcp:run:rev:#{project}/#{loc}/#{service_id}/")

  def get_revision(project, loc, service_id, rev) do
    case Store.get(@table, rkey(project, loc, service_id, rev)) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, {404, "NOT_FOUND", "revision #{rev} not found"}}
    end
  end

  def get_operation(id) do
    case Store.get(@table, okey(id)) do
      {:ok, o} -> {:ok, o}
      :error -> {:error, {404, "NOT_FOUND", "operation #{id} not found"}}
    end
  end

  # --- invoker IAM -----------------------------------------------------------

  def get_iam_policy(project, loc, service_id) do
    with {:ok, svc} <- get_service(project, loc, service_id) do
      {:ok, svc["_iam"]}
    end
  end

  def set_iam_policy(project, loc, service_id, %{"bindings" => bindings})
      when is_list(bindings) do
    with {:ok, svc} <- get_service(project, loc, service_id) do
      pol = %{"version" => 1, "etag" => etag(bindings), "bindings" => bindings}
      Store.put(@table, skey(project, loc, service_id), %{svc | "_iam" => pol})
      {:ok, pol}
    end
  end

  def set_iam_policy(_, _, _, _), do: {:error, {400, "INVALID_ARGUMENT", "policy.bindings required"}}

  @doc "Invoker check: allUsers or exact member holding roles/run.invoker (or run.admin)."
  def invoker?(project, loc, service_id, member) do
    case get_iam_policy(project, loc, service_id) do
      {:ok, %{"bindings" => bs}} ->
        Enum.any?(bs, fn b ->
          b["role"] in ["roles/run.invoker", "roles/run.admin"] and
            (member in b["members"] or "allUsers" in b["members"])
        end)

      _ ->
        false
    end
  end

  # --- internals -------------------------------------------------------------

  defp validate_ingress(ingress) when ingress in @ingress, do: :ok
  defp validate_ingress(ingress), do: {:error, {400, "INVALID_ARGUMENT", "invalid ingress #{ingress}"}}

  defp validate_template(nil), do: :ok

  defp validate_template(%{"containers" => containers}) when is_list(containers) do
    loopback_names =
      containers
      |> Enum.filter(fn c ->
        c["name"] == "wireproxy" or String.contains?(to_string(c["image"]), "wireproxy")
      end)
      |> MapSet.new(&(&1["name"] || "wireproxy"))

    Enum.reduce_while(containers, :ok, fn c, :ok ->
      cname = c["name"] || ""
      envs = c["env"] || []
      deps = MapSet.new(c["dependsOn"] || c["depends_on"] || [])
      has_probe = not is_nil(c["startupProbe"] || c["startup_probe"])

      cond do
        Enum.any?(envs, &(&1["name"] == "PORT")) ->
          {:halt, {:error, {400, "INVALID_ARGUMENT", "reserved environment variable PORT cannot be set in container #{cname}"}}}

        MapSet.member?(loopback_names, cname) and has_probe ->
          {:halt, {:error, {400, "INVALID_ARGUMENT", "loopback sidecar #{cname} cannot use startup_probe (probes pod IP)"}}}

        not MapSet.disjoint?(deps, loopback_names) ->
          {:halt, {:error, {400, "INVALID_ARGUMENT", "container #{cname} depends_on loopback sidecar without pod-IP probe"}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_template(_), do: :ok

  defp build(project, loc, sid, body, ingress, seq, old) do
    template =
      Map.get(body, "template") ||
        (old && old["template"]) ||
        %{"containers" => [%{"image" => "scratch"}]}

    rev = "#{sid}-#{String.pad_leading(Integer.to_string(seq), 5, "0")}-#{suffix(template)}"
    svc_name = name(project, loc, sid)
    rev_name = svc_name <> "/revisions/" <> rev

    unless match?({:ok, _}, Store.get(@table, rkey(project, loc, sid, rev))) do
      Store.put(@table, rkey(project, loc, sid, rev), %{
        "name" => rev_name,
        "service" => svc_name,
        "containers" => template["containers"],
        "createTime" => now(),
        "conditions" => [%{"type" => "Ready", "state" => "CONDITION_SUCCEEDED"}]
      })
    end

    iam = Map.get(body, "iam", %{"version" => 1, "etag" => etag([]), "bindings" => []})
    uri = "https://#{sid}-#{project}.#{loc}.run.smalt.local"
    cond_ready = [%{"type" => "Ready", "state" => "CONDITION_SUCCEEDED"}]

    traffic =
      Map.get(body, "traffic") ||
        (old && old["traffic"]) ||
        [%{"type" => "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST", "percent" => 100}]

    traffic_statuses = [
      %{
        "type" => "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST",
        "percent" => 100,
        "revision" => rev_name,
        "uri" => uri
      }
    ]

    base = %{
      "name" => svc_name,
      "uid" => uuid(project <> loc <> sid),
      "generation" => 1,
      "observedGeneration" => 1,
      "createTime" => (old && old["createTime"]) || now(),
      "updateTime" => now(),
      "ingress" => ingress,
      "template" => template,
      "traffic" => traffic,
      "trafficStatuses" => traffic_statuses,
      "latestReadyRevision" => rev_name,
      "latestCreatedRevision" => rev_name,
      "uri" => uri,
      "urls" => [uri],
      "reconciling" => false,
      "etag" => etag({svc_name, seq, template, ingress}),
      "conditions" => cond_ready,
      "terminalCondition" => hd(cond_ready),
      "_revSeq" => seq,
      "_iam" => iam
    }

    Enum.reduce(~w(description labels annotations launchStage client clientVersion), base, fn k, acc ->
      case Map.get(body, k) || (old && old[k]) do
        nil -> acc
        v -> Map.put(acc, k, v)
      end
    end)
  end

  defp op(resource_name, svc) do
    id = "op-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
    parts = String.split(resource_name, "/")
    opname = "projects/#{Enum.at(parts, 1)}/locations/#{Enum.at(parts, 3)}/operations/#{id}"

    o = %{
      "name" => opname,
      "done" => true,
      "metadata" => %{"@type" => "type.googleapis.com/google.cloud.run.v2.Service", "name" => resource_name},
      "response" =>
        svc
        |> Map.reject(fn {k, _} -> String.starts_with?(k, "_") end)
        |> Map.put("@type", "type.googleapis.com/google.cloud.run.v2.Service")
    }

    Store.put(@table, okey(id), o)
    o
  end

  defp suffix(t),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(t)) |> Base.encode16(case: :lower) |> binary_part(0, 3)

  defp etag(b), do: :crypto.hash(:sha256, :erlang.term_to_binary(b)) |> Base.url_encode64(padding: false) |> binary_part(0, 12)

  defp uuid(s) do
    <<a::32, b::16, c::16, d::16, e::48, _::binary>> = :crypto.hash(:sha256, s)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> IO.iodata_to_binary()
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

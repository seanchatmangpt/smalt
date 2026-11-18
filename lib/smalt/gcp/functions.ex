defmodule Smalt.GCP.Functions do
  @moduledoc """
  Cloud Functions v2 + Cloud Run invocation engine (lane SM4). Wire-free.

  Closes the "no container execution" gap of `Smalt.GCP.CloudRun`: a function
  (or a Run service, via `invoke_service/5`) names an in-VM handler
  `"Elixir.Mod.fun"` (arity 1, receives a request map, returns
  `{:ok, term}` or `{:error, term}`). Rows live in `:smalt_resources` under
  `gcp:fn:`.

  Typed divergences: handlers are BEAM functions, not containers; no cold
  start, no scaling, no timeouts enforced; `call/4` is the
  `functions:call` analogue and returns `executionId` + `result`/`error`.
  """

  alias Smalt.Store

  @table :smalt_resources

  defp fkey(p, l, f), do: "gcp:fn:#{p}/#{l}/#{f}"
  defp okey(id), do: "gcp:fn:op:#{id}"
  defp name(p, l, f), do: "projects/#{p}/locations/#{l}/functions/#{f}"

  def create_function(project, loc, id, body) when is_map(body) do
    ep = extract_entry_point(body)

    cond do
      not is_binary(ep) or ep == "" ->
        {:error, {400, "INVALID_ARGUMENT", "entryPoint required"}}

      not Regex.match?(~r/^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$/, id) ->
        {:error, {400, "INVALID_ARGUMENT", "invalid functionId"}}

      match?({:ok, _}, Store.get(@table, fkey(project, loc, id))) ->
        {:error, {409, "ALREADY_EXISTS", "function #{id} already exists"}}

      true ->
        fun = build_function(project, loc, id, ep, body, nil)
        Store.put(@table, fkey(project, loc, id), fun)
        {:ok, fun}
    end
  end

  def create_function(_, _, _, _),
    do: {:error, {400, "INVALID_ARGUMENT", "entryPoint required"}}

  def update_function(project, loc, id, body) when is_map(body) do
    with {:ok, old} <- get_function(project, loc, id) do
      ep = extract_entry_point(body) || old["entryPoint"]
      fun = build_function(project, loc, id, ep, body, old)
      Store.put(@table, fkey(project, loc, id), fun)
      {:ok, fun}
    end
  end

  def update_function(_, _, _, _),
    do: {:error, {400, "INVALID_ARGUMENT", "function body must be a JSON object"}}

  def get_function(project, loc, id) do
    case Store.get(@table, fkey(project, loc, id)) do
      {:ok, f} -> {:ok, f}
      :error -> {:error, {404, "NOT_FOUND", "function #{id} not found"}}
    end
  end

  def list_functions(project, loc), do: Store.list_prefix(@table, "gcp:fn:#{project}/#{loc}/")

  def delete_function(project, loc, id) do
    with {:ok, _} <- get_function(project, loc, id) do
      Store.delete(@table, fkey(project, loc, id))
      {:ok, %{}}
    end
  end

  def create_function_lro(project, loc, id, body) do
    with {:ok, fun} <- create_function(project, loc, id, body) do
      {:ok, op(project, loc, name(project, loc, id), "CREATE_FUNCTION", fun)}
    end
  end

  def update_function_lro(project, loc, id, body) do
    with {:ok, fun} <- update_function(project, loc, id, body) do
      {:ok, op(project, loc, name(project, loc, id), "UPDATE_FUNCTION", fun)}
    end
  end

  def delete_function_lro(project, loc, id) do
    with {:ok, _} <- delete_function(project, loc, id) do
      {:ok, op(project, loc, name(project, loc, id), "DELETE_FUNCTION", %{})}
    end
  end

  def get_operation(id) do
    case Store.get(@table, okey(id)) do
      {:ok, o} -> {:ok, o}
      :error -> {:error, {404, "NOT_FOUND", "operation #{id} not found"}}
    end
  end

  defp extract_entry_point(body) do
    Map.get(body, "entryPoint") || get_in(body, ["buildConfig", "entryPoint"])
  end

  defp build_function(project, loc, id, ep, body, old) do
    now = DateTime.to_iso8601(DateTime.utc_now())
    uri = "https://#{loc}-#{project}.cloudfunctions.smalt.local/#{id}"
    old_build = (old && old["buildConfig"]) || %{}
    old_svc = (old && old["serviceConfig"]) || %{}

    build_config =
      old_build
      |> Map.merge(Map.get(body, "buildConfig") || %{})
      |> Map.put("entryPoint", ep)

    service_config =
      %{"uri" => uri, "service" => "projects/#{project}/locations/#{loc}/services/#{id}"}
      |> Map.merge(old_svc)
      |> Map.merge(Map.get(body, "serviceConfig") || %{})

    base = %{
      "name" => name(project, loc, id),
      "state" => "ACTIVE",
      "entryPoint" => ep,
      "environment" => "GEN_2",
      "url" => uri,
      "buildConfig" => build_config,
      "serviceConfig" => service_config,
      "createTime" => (old && old["createTime"]) || now,
      "updateTime" => now
    }

    Enum.reduce(~w(description labels eventTrigger kmsKeyName), base, fn k, acc ->
      case Map.get(body, k) || (old && old[k]) do
        nil -> acc
        v -> Map.put(acc, k, v)
      end
    end)
  end

  defp op(project, loc, target, verb, response) do
    id = "op-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
    opname = "projects/#{project}/locations/#{loc}/operations/#{id}"

    resp =
      if map_size(response) == 0 do
        %{"@type" => "type.googleapis.com/google.protobuf.Empty"}
      else
        Map.put(response, "@type", "type.googleapis.com/google.cloud.functions.v2.Function")
      end

    o = %{
      "name" => opname,
      "done" => true,
      "metadata" => %{
        "@type" => "type.googleapis.com/google.cloud.functions.v2.OperationMetadata",
        "target" => target,
        "verb" => verb,
        "apiVersion" => "v2"
      },
      "response" => resp
    }

    Store.put(@table, okey(id), o)
    o
  end

  @doc "functions:call analogue. `data` is the request payload."
  def call(project, loc, id, data) do
    with {:ok, f} <- get_function(project, loc, id) do
      {:ok, run_handler(f["entryPoint"], data)}
    end
  end

  @doc "Invoke a Cloud Run service by registering a handler entry point on it."
  def invoke_service(project, loc, service, entry_point, data) do
    with {:ok, _svc} <- Smalt.GCP.CloudRun.get_service(project, loc, service) do
      {:ok, run_handler(entry_point, data)}
    end
  end

  @doc false
  def run_handler(entry_point, data) do
    exec = "exec-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    case resolve(entry_point) do
      {:ok, {m, f}} ->
        try do
          case apply(m, f, [data]) do
            {:ok, r} -> %{"executionId" => exec, "result" => r}
            {:error, e} -> %{"executionId" => exec, "error" => inspect(e)}
            other -> %{"executionId" => exec, "result" => other}
          end
        rescue
          e -> %{"executionId" => exec, "error" => Exception.message(e)}
        end

      :error ->
        %{"executionId" => exec, "error" => "entry point #{entry_point} not resolvable"}
    end
  end

  defp resolve(ep) do
    with true <- is_binary(ep),
         parts = String.split(ep, "."),
         true <- length(parts) >= 2,
         {mod_parts, [fun]} = Enum.split(parts, -1),
         mod = Module.concat(mod_parts),
         true <- Code.ensure_loaded?(mod),
         fun_atom = String.to_atom(fun),
         true <- function_exported?(mod, fun_atom, 1) do
      {:ok, {mod, fun_atom}}
    else
      _ -> :error
    end
  end
end

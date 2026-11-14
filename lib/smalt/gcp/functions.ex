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
  defp name(p, l, f), do: "projects/#{p}/locations/#{l}/functions/#{f}"

  def create_function(project, loc, id, %{"entryPoint" => ep} = body) when is_binary(ep) do
    cond do
      not Regex.match?(~r/^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$/, id) ->
        {:error, {400, "INVALID_ARGUMENT", "invalid functionId"}}

      match?({:ok, _}, Store.get(@table, fkey(project, loc, id))) ->
        {:error, {409, "ALREADY_EXISTS", "function #{id} already exists"}}

      true ->
        fun = %{
          "name" => name(project, loc, id),
          "state" => "ACTIVE",
          "entryPoint" => ep,
          "environment" => "GEN_2",
          "buildConfig" => Map.get(body, "buildConfig", %{}),
          "serviceConfig" =>
            Map.merge(
              %{"uri" => "https://#{loc}-#{project}.cloudfunctions.smalt.local/#{id}"},
              Map.get(body, "serviceConfig", %{})
            ),
          "createTime" => DateTime.to_iso8601(DateTime.utc_now())
        }

        Store.put(@table, fkey(project, loc, id), fun)
        {:ok, fun}
    end
  end

  def create_function(_, _, _, _),
    do: {:error, {400, "INVALID_ARGUMENT", "entryPoint required"}}

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

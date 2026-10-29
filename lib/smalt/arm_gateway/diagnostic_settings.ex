defmodule Smalt.ArmGateway.DiagnosticSettings do
  @moduledoc """
  Diagnostic-settings surface law (CONVERGENCE lane V12, upstream smalt).

  The documented `/{scope}/providers/microsoft.insights/diagnosticSettings/{name}`
  contract — PUT/GET/LIST/DELETE of export configurations that route a
  scope's platform logs and metrics to real destinations:

  - `workspaceId` — the Log Analytics workspace target (the portal's
    "export to Log Analytics" flow lands here; same shape the MTTW
    heartbeat consumes, per athena's customer1 monitoring receipt).
  - `storageAccountId` — archive target.
  - `eventHubAuthorizationRuleId` + `eventHubName` — stream target.
  - `logs` / `metrics` — per-category `{category, enabled}` lists.

  Records are stored PER SCOPE in heir'd ETS `:smalt_diag_settings`
  (`{:heir, Process.whereis(:init), []}` 3-tuple — the v26.10.19
  silent-disarm law; no GenServer: the table is created lazily and
  inherited by init on creator death). Key is
  `{downcased_scope, name}`: the same setting name at different scopes
  (subscription / resource group / resource) is a different diagnostic
  setting, and LIST at a scope never leaks another scope's rows.

  The store is scope-agnostic: the caller (router / portal / heartbeat)
  passes the scope path as it appears on the wire; ids render as
  `{scope}/providers/microsoft.insights/diagnosticSettings/{name}`.
  """

  @table :smalt_diag_settings

  @wire_type "Microsoft.Insights/diagnosticSettings"

  @typedoc """
  Validation failure: `:bad_body` (non-map body), `:no_destination` (real
  Azure refuses a diagnostic setting with no destination), `:bad_logs` /
  `:bad_metrics` (present but not a list of maps), `:bad_category_entry`
  (a category entry missing a binary "category").
  """
  @type validation_error() ::
          :bad_body | :no_destination | :bad_logs | :bad_metrics | :bad_category_entry

  # -- CRUD ----------------------------------------------------------------------

  @doc """
  PUT a diagnostic setting at `scope` (create or full replace). Returns
  `{:ok, wire}` or `{:error, validation_error()}`. PUT is replace-all:
  the stored properties are exactly the submitted ones (Azure PUT
  semantics — fields omitted are cleared, never merged).
  """
  @spec put(String.t(), String.t(), term()) :: {:ok, map()} | {:error, validation_error()}
  def put(scope, name, body) when is_binary(scope) and is_binary(name) and is_map(body) do
    with :ok <- validate(body) do
      key = {String.downcase(scope), name}
      now = System.system_time(:millisecond)

      record = %{
        key: key,
        scope: scope,
        name: name,
        properties: body,
        last_updated: now
      }

      ensure_table()
      :ets.insert(@table, {key, record})
      {:ok, wire(record)}
    end
  end

  def put(_scope, _name, _body), do: {:error, :bad_body}

  @doc "GET a diagnostic setting. `{:ok, wire}` | `{:error, :not_found}`."
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(scope, name) do
    ensure_table()

    case :ets.lookup(@table, {String.downcase(scope), name}) do
      [{_k, record}] -> {:ok, wire(record)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  LIST diagnostic settings AT one scope (never leaks another scope's
  rows), most-recently-updated last.
  """
  @spec list(String.t()) :: [map()]
  def list(scope) do
    ensure_table()

    @table
    |> rows()
    |> Enum.filter(fn {_k, r} -> elem(r.key, 0) == String.downcase(scope) end)
    |> Enum.sort_by(fn {_k, r} -> r.last_updated end)
    |> Enum.map(fn {_k, r} -> wire(r) end)
  end

  @doc "DELETE a diagnostic setting. `:ok` | `{:error, :not_found}`."
  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(scope, name) do
    ensure_table()

    case :ets.take(@table, {String.downcase(scope), name}) do
      [] -> {:error, :not_found}
      [_taken] -> :ok
    end
  end

  # -- validation ------------------------------------------------------------------

  # Real Azure law: a diagnostic setting must name at least one destination
  # (workspace / storage / eventhub / marketplace partner). Categories, when
  # present, are a list of entries each carrying a binary "category".
  defp validate(%{} = body) do
    dest? =
      is_binary(body["workspaceId"]) or is_binary(body["storageAccountId"]) or
        is_binary(body["eventHubAuthorizationRuleId"]) or is_binary(body["marketplacePartnerId"])

    cond do
      not dest? ->
        {:error, :no_destination}

      true ->
        with :ok <- categories(body["logs"], :bad_logs),
             :ok <- categories(body["metrics"], :bad_metrics) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp categories(nil, _err), do: :ok

  defp categories(entries, err) when is_list(entries) do
    if Enum.all?(entries, &(&1 |> is_map() and is_binary(&1["category"]))),
      do: :ok,
      else: {:error, err}
  end

  defp categories(_other, err), do: {:error, err}

  # -- wire face -------------------------------------------------------------------

  defp wire(record) do
    %{
      "id" =>
        "#{record.scope}/providers/microsoft.insights/diagnosticSettings/#{record.name}",
      "name" => record.name,
      "type" => @wire_type,
      "location" => "global",
      "properties" => record.properties
    }
  end

  # -- table -----------------------------------------------------------------------

  @spec ensure_table() :: :ok
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # 3-tuple :heir form (keyword form raises ArgumentError): table
        # survives the creating process — silent-disarm law.
        try do
          :ets.new(@table, [:set, :named_table, :public, {:heir, Process.whereis(:init), []}])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp rows(t) do
    try do
      :ets.tab2list(t)
    rescue
      ArgumentError -> []
    end
  end
end

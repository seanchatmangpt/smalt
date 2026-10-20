defmodule Smalt.DataPlane.AppConfigSnapshots do
  @moduledoc """
  Azure App Configuration snapshots (point-in-time frozen KV selections).

  Azure parity surface (Azure.AppConfiguration snapshots API):

    - `create/3` — PUT /snapshots/{name}: select KV records by key filter
      (prefix match, same semantics as the `/kv` list filter) and label
      filter (exact match), freeze a deep copy of the selection, and walk
      `provisioning -> ready` synchronously (the emulator has no async
      provisioning arm; itemCount is final at `ready`).
    - `get/1` — GET /snapshots/{name}: snapshot settings + `itemCount`.
    - `kv_view/1` — GET /snapshots/{name}/kv: read-only view of the FROZEN
      records. Snapshot semantics = point-in-time freeze: later mutations of
      the live `:smalt_appconfig` table never leak into an existing snapshot.
    - `archive/1` — POST /snapshots/{name}/archive: `ready -> archived`.
    - `purge/1` — delete an ARCHIVED snapshot. Purging a non-archived
      snapshot is a typed refusal, never a silent delete.

  Typed errors are `{:error, {code, message}}` tuples; the HTTP mapping
  (400/404/409) lives in the egress route fragment (egress-owned).

  Storage: module-owned ETS table `:smalt_appconfig_snapshots` (created
  lazily by `ensure_table/0`; NOT part of the generated Store registry —
  the registry is `mix smalt.gen`-generated and snapshot lifetime is
  bounded by the appconfig plane that owns `:smalt_appconfig`, so a
  registry edit is not required). Records are deep-copied into the
  snapshot at creation; the frozen copies are never written back.
  """

  @table :smalt_appconfig_snapshots

  alias Smalt.Store

  @typedoc "Typed refusal: {HTTP-mappable code, message}"
  @type typed_error :: {:error, {String.t(), String.t()}}

  @doc "Create (or lazily return) the module-owned snapshot table."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Freeze a snapshot of the KV selection named `name`.

  `filters` (JSON-shaped map):
    - `"filters"` — list of `{"key": <prefix>, "label": <exact label>}`
      selector maps (a bare `"key"`/`"label"` map is also accepted).
    - `"composition"` — `"key"` (default) or `"label"`: whether selection
      keys compose across selectors (OR within key, AND with label) — the
      Azure composition field. Any other value is a typed
      `InvalidComposition` refusal.

  Selection semantics mirror the live `/kv` list route: key filter is a
  prefix match, label filter is exact. An empty selection is legal (Azure
  allows itemCount 0) but `nil`/malformed filters are a typed refusal.
  The selected records are deep-copied at creation — this IS the freeze.
  Status walks `provisioning -> ready` before returning.
  """
  @spec create(String.t(), map(), [map()]) ::
          {:ok, map()} | typed_error()
  def create(name, filters, kv_records)
      when is_binary(name) and is_map(filters) and is_list(kv_records) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, _} ->
        {:error, {"SnapshotExists", "snapshot #{name} already exists"}}

      :error ->
        with {:ok, selectors} <- parse_selectors(filters),
             {:ok, composition} <- parse_composition(filters) do
          selected = select(kv_records, selectors, composition)

          record =
            %{
              "name" => name,
              "filters" => %{"filters" => selectors, "composition" => composition},
              "status" => "provisioning",
              "item_count" => length(selected),
              "items" => deep_copy(selected),
              "created" => System.system_time(:second)
            }
            # provisioning -> ready walks synchronously; itemCount final at ready
            |> Map.put("status", "ready")
            |> then(&Map.put(&1, "etag", snapshot_etag(&1)))

          :ets.insert(@table, {name, record})
          {:ok, record}
        end
    end
  end

  @doc "GET /snapshots/{name}: settings + itemCount, or a typed NotFound."
  @spec get(String.t()) :: {:ok, map()} | typed_error()
  def get(name) when is_binary(name) do
    ensure_table()

    case Store.get(@table, name) do
      {:ok, record} -> {:ok, public_record(record)}
      :error -> {:error, {"SnapshotNotFound", "snapshot #{name} does not exist"}}
    end
  end

  @doc """
  GET /snapshots/{name}/kv: the frozen KV view (read-only). Returns the
  deep-copied records as stored at creation; live-table mutations since
  then are invisible here by construction. Refuses unknown names and —
  because an archived snapshot's KV view is no longer servable per Azure
  parity posture pinned below — archived snapshots with `SnapshotArchived`.
  """
  @spec kv_view(String.t()) :: {:ok, [map()]} | typed_error()
  def kv_view(name) when is_binary(name) do
    ensure_table()

    case Store.get(@table, name) do
      :error ->
        {:error, {"SnapshotNotFound", "snapshot #{name} does not exist"}}

      {:ok, %{"status" => "archived"}} ->
        {:error,
         {"SnapshotArchived", "snapshot #{name} is archived; its kv view is no longer servable"}}

      {:ok, %{"items" => items}} ->
        {:ok, Enum.map(items, &public_kv/1)}
    end
  end

  @doc """
  POST /snapshots/{name}/archive: `ready -> archived`. Transition arm is
  typed: unknown name -> `SnapshotNotFound`; `provisioning` -> `Conflict`;
  already-archived -> `SnapshotAlreadyArchived`. The frozen items are kept
  (archive is a status flip, not a purge) but the kv view refuses.
  """
  @spec archive(String.t()) :: {:ok, map()} | typed_error()
  def archive(name) when is_binary(name) do
    ensure_table()
    transition(name, "ready", "archived", "SnapshotAlreadyArchived", "archive")
  end

  @doc """
  Delete an ARCHIVED snapshot. Unknown -> `SnapshotNotFound`; a snapshot in
  any other status -> `SnapshotNotArchived` (purge is the terminal arm;
  only `archived` is purgeable). Deletion is real (row removed).
  """
  @spec purge(String.t()) :: :ok | typed_error()
  def purge(name) when is_binary(name) do
    ensure_table()

    case Store.get(@table, name) do
      :error ->
        {:error, {"SnapshotNotFound", "snapshot #{name} does not exist"}}

      {:ok, %{"status" => "archived"}} ->
        :ets.delete(@table, name)
        :ok

      {:ok, %{"status" => other}} ->
        {:error,
         {"SnapshotNotArchived",
          "snapshot #{name} is #{other}; only archived snapshots can be purged"}}
    end
  end

  @doc "List all snapshots (settings, no frozen bodies), deterministic order."
  @spec list() :: [map()]
  def list do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {_, rec} -> public_record(rec) end)
  end

  # -- internals ------------------------------------------------------------

  defp transition(name, from, to, already_code, verb) do
    case Store.get(@table, name) do
      :error ->
        {:error, {"SnapshotNotFound", "snapshot #{name} does not exist"}}

      {:ok, %{"status" => ^from}} ->
        {:ok, record} = Store.get(@table, name)
        record = %{record | "status" => to, "etag" => snapshot_etag(record)}
        :ets.insert(@table, {name, record})
        {:ok, public_record(record)}

      {:ok, %{"status" => "provisioning"}} ->
        {:error,
         {"Conflict", "snapshot #{name} is provisioning; #{verb} requires status ready"}}

      {:ok, %{"status" => ^to}} ->
        {:error, {already_code, "snapshot #{name} is already #{to}"}}
    end
  end

  defp parse_selectors(%{"filters" => filters}) when is_list(filters) do
    selectors =
      Enum.map(filters, fn f ->
        %{"key" => Map.get(f, "key"), "label" => Map.get(f, "label")}
      end)

    if Enum.all?(selectors, fn s -> is_binary(s["key"]) or is_binary(s["label"]) end) do
      {:ok, selectors}
    else
      {:error,
       {"InvalidFilter", "each snapshot filter needs a string \"key\" and-or \"label\""}}
    end
  end

  defp parse_selectors(_) do
    {:error, {"InvalidFilter", "snapshot body requires a list \"filters\""}}
  end

  defp parse_composition(%{"composition" => c}) when c in ["key", "label"], do: {:ok, c}
  defp parse_composition(%{"composition" => other}) do
    {:error, {"InvalidComposition", "composition must be \"key\" or \"label\", got #{inspect(other)}"}}
  end
  defp parse_composition(_), do: {:ok, "key"}

  # Key composition: OR within selectors' key prefixes; label: AND-exact per
  # matched selector ("key" composition). "label" composition mirrors it
  # across labels. A record matches when some selector matches it on the
  # composition dimension and every selector match agrees on the other.
  defp select(records, selectors, "key") do
    Enum.filter(records, fn record ->
      Enum.any?(selectors, fn s ->
        key_match?(record, s["key"]) and label_match?(record, s["label"])
      end)
    end)
  end

  defp select(records, selectors, "label") do
    Enum.filter(records, fn record ->
      Enum.any?(selectors, fn s ->
        label_match?(record, s["label"]) and key_match?(record, s["key"])
      end)
    end)
  end

  defp key_match?(_record, nil), do: true
  defp key_match?(record, prefix), do: String.starts_with?(record["key"], prefix)

  defp label_match?(_record, nil), do: true
  defp label_match?(record, label), do: record["label"] == label

  # Structural deep copy: records are immutable maps, but the freeze is
  # explicit — copy each record map (and its string values) so no alias to
  # a live-table term survives the snapshot boundary.
  defp deep_copy(records) do
    Enum.map(records, fn record ->
      record
      |> :erlang.term_to_binary()
      |> :erlang.binary_to_term()
    end)
  end

  defp snapshot_etag(record) do
    hash =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({record["name"], record["status"], record["item_count"]})
      )
      |> Base.encode16()

    "\"" <> hash <> "\""
  end

  # Wire shape: settings + itemCount; the frozen bodies never render here.
  defp public_record(record), do: Map.drop(record, ["items"])

  defp public_kv(record), do: record
end

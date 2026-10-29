defmodule Smalt.Messaging.EhSchemaRegistry do
  @moduledoc """
  Azure Event Hubs Schema Registry emulation (capability wave-6, lane w6x).

    - `create_group/2` — PUT /schemas/$schemagroups/{group} (create-only,
      409 GroupExists on existing).
    - `register_schema/3` — POST /schemas/{group}/{name} with an Avro JSON
      body -> 201 + schema GUID. Byte-identical re-register is idempotent
      (same id); a different body adds a new version with a NEW id
      (Forward compatibility at byte level — full Avro resolution is a
      documented boundary, not implemented).
    - `get_by_id/1` — GET /schemas/ids/{id}: body echo, byte-exact.
    - `versions/2` / `get_version/3` — version history, newest first.

  Storage: ETS `:smalt_eh_schemas` with a `:heir` to :init (KD-117 heir
  class — the first creator may be a request task; without an heir the
  table dies with it).
  """

  @table :smalt_eh_schemas
  alias Smalt.Store

  @typedoc "Typed refusal: {HTTP-mappable code, message}"
  @type typed_error :: {:error, {String.t(), String.t()}}

  @doc "Create (or return) the module-owned schema table (KD-117 heir class)."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  PUT /schemas/$schemagroups/{group}: create-only. Existing group (any
  body) -> typed `GroupExists`.
  """
  @spec create_group(String.t(), map()) :: {:ok, map()} | typed_error()
  def create_group(name, body) when is_binary(name) and is_map(body) do
    ensure_table()

    case Store.get(@table, {:group, name}) do
      {:ok, _} ->
        {:error, {"GroupExists", "schema group #{name} already exists"}}

      :error ->
        compatibility = Map.get(body, "schemaCompatibility", "Forward")
        schema_type = Map.get(body, "schemaType", "Avro")

        record = %{
          "group" => name,
          "schemaCompatibility" => compatibility,
          "schemaType" => schema_type,
          "created" => System.system_time(:second)
        }

        :ets.insert(@table, {{:group, name}, record})
        {:ok, record}
    end
  end

  defp fetch_group(group) do
    case Store.get(@table, {:group, group}) do
      {:ok, rec} -> {:ok, rec}
      :error -> {:error, {"GroupNotFound", "schema group #{group} does not exist"}}
    end
  end

  @doc "GET /schemas/$schemagroups/{group}."
  @spec get_group(String.t()) :: {:ok, map()} | typed_error()
  def get_group(name) when is_binary(name) do
    ensure_table()
    fetch_group(name)
  end

  @doc "DELETE /schemas/$schemagroups/{group}: removes the group AND its member schemas (cascade)."
  @spec delete_group(String.t()) :: :ok | typed_error()
  def delete_group(name) when is_binary(name) do
    ensure_table()

    case Store.get(@table, {:group, name}) do
      :error ->
        {:error, {"GroupNotFound", "schema group #{name} does not exist"}}

      {:ok, _} ->
        for {{:schema, g, _n, _v}, _} <- :ets.tab2list(@table), g == name do
          :ets.match_delete(@table, {{:schema, g, :_, :_}, :_})
        end

        for {id, rec} <- :ets.tab2list(@table), is_binary(id), rec.group == name do
          :ets.delete(@table, id)
        end
        :ets.delete(@table, {:group, name})
        :ok
    end
  end

  @doc "List schema groups (deterministic order)."
  @spec list_groups() :: [map()]
  def list_groups do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {k, _} -> is_tuple(k) and elem(k, 0) == :group end)
    |> Enum.sort_by(fn {k, _} -> elem(k, 1) end)
    |> Enum.map(fn {_, rec} -> rec end)
  end

  @doc """
  POST /schemas/{group}/{name}: register a schema version. Byte-identical
  re-register is idempotent (same id). Different body, same name -> new
  version + NEW id. Malformed body -> typed 400 `InvalidSchema`.
  """
  @spec register_schema(String.t(), String.t(), binary()) ::
          {:ok, map()} | typed_error()
  def register_schema(group, name, body)
      when is_binary(group) and is_binary(name) and is_binary(body) and body != "" do
    ensure_table()

    with {:ok, _grp} <- fetch_group(group),
         {:ok, _parsed} <- avro_boundary_check(body) do
      versions =
        @table
        |> :ets.tab2list()
        |> Enum.filter(fn
          {{:schema, g, n, _v}, _} -> g == group and n == name
          _ -> false
        end)
        |> Enum.map(fn {{:schema, _g, _n, v}, rec} -> {v, rec} end)

      case Enum.find(versions, fn {_v, rec} -> rec.body == body end) do
        {_v, rec} ->
          {:ok, rec |> Map.drop([:body]) |> Map.put(:location, schema_location(rec))}

        nil ->
          version =
            case versions do
              [] -> 1
              _ -> Enum.max_by(versions, fn {v, _} -> v end) |> elem(0) |> Kernel.+(1)
            end

          id = schema_id()
          now = System.system_time(:second)

          rec = %{
            :id => id,
            :group => group,
            :name => name,
            :version => version,
            :body => body,
            :registered_at => now
          }

          :ets.insert(@table, {{:schema, group, name, version}, rec})
          :ets.insert(@table, {id, rec})
          {:ok, public_schema(rec)}
      end
    end
  end

  @doc "GET /schemas/ids/{id}: body echo, byte-exact as registered."
  @spec get_by_id(String.t()) :: {:ok, binary(), map()} | typed_error()
  def get_by_id(id) when is_binary(id) do
    ensure_table()

    case Store.get(@table, id) do
      :error ->
        {:error, {"SchemaNotFound", "schema id #{id} does not exist"}}

      {:ok, rec} ->
        {:ok, rec.body, rec}
    end
  end

  @doc "GET /schemas/{group}/{name}/versions: version history, newest first."
  @spec versions(String.t(), String.t()) :: {:ok, [map()]} | typed_error()
  def versions(group, name) do
    ensure_table()

    with {:ok, _grp} <- fetch_group(group) do
      vs =
        @table
        |> :ets.tab2list()
        |> Enum.filter(fn
          {{:schema, g, n, _v}, _} -> g == group and n == name
          _ -> false
        end)
        |> Enum.sort_by(fn {{:schema, _g, _n, v}, _} -> v end, :desc)
        |> Enum.map(fn {_, rec} -> public_schema(rec) end)

      if vs == [] do
        {:error, {"SchemaNotFound", "schema #{group}/#{name} has no versions"}}
      else
        {:ok, vs}
      end
    end
  end

  @doc "GET /schemas/{group}/{name}/versions/{v}: exact version read."
  @spec get_version(String.t(), String.t(), integer()) :: {:ok, map()} | typed_error()
  def get_version(group, name, version) do
    ensure_table()

    case Store.get(@table, {:schema, group, name, version}) do
      :error -> {:error, {"SchemaNotFound", "version #{version} of #{group}/#{name} does not exist"}}
      {:ok, rec} -> {:ok, public_schema(rec)}
    end
  end

  # -- internals ------------------------------------------------------------

  # Avro boundary check: valid JSON with a string "type" and a list
  # "fields". Full Avro reader/writer resolution is a documented boundary
  # (not implemented) — see the moduledoc and the lane receipt.
  defp avro_boundary_check(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => t, "fields" => fields}} when is_binary(t) and is_list(fields) ->
        {:ok, body}

      {:ok, _} ->
        {:error, {"InvalidSchema", "body must be an Avro schema JSON with string \"type\" and list \"fields\""}}

      {:error, _} ->
        {:error, {"InvalidSchema", "body must be valid JSON"}}
    end
  end

  defp public_schema(rec) do
    rec
    |> Map.drop([:body])
    |> Map.put(:location, schema_location(rec))
  end

  defp schema_location(rec) do
    "/schemas/#{rec.group}/#{rec.name}/versions/#{rec.version}"
  end

  defp schema_id do
    <<a0::32, b0::16, c0::16, d0::16, e0::48>> = :crypto.strong_rand_bytes(16)

    hex = fn n, w -> n |> Integer.to_string(16) |> String.pad_leading(w, "0") end

    hex.(a0, 8) <> "-" <> hex.(b0, 4) <> "-4" <> String.slice(hex.(c0, 3), -3, 3) <>
      "-" <> hex.(rem(d0, 4) + 8, 1) <> String.slice(hex.(d0, 3), -3, 3) <>
      "-" <> hex.(e0, 12)
  end

end

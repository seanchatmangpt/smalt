defmodule Smalt.DataPlane.TableStorage do
  @moduledoc """
  Azure Table Storage REST face — wave-6 lane w6p (Cosmos Table API parity).

  QueueStorage-style module: pure Store-backed, wire-agnostic, uniform
  `{:ok, status, headers, body}` / `{:error, status, code, msg}` tuples;
  the egress router owns the wire. Minimal odata envelope: queries answer a
  `value` array; `odata.metadata` tolerated absent.

  Shadow tables :smalt_tbl_tables / :smalt_tbl_entities, lazily created with
  the 3-tuple heir (shadow-table law).
  """

  alias Smalt.Store

  @tables_table :smalt_tbl_tables
  @entities_table :smalt_tbl_entities

  @type arm ::
          {:ok, pos_integer(), map(), map() | binary() | nil}
          | {:error, pos_integer(), String.t(), String.t()}

  @doc "True when both shadow tables exist (router readiness lens)."
  def store_ready? do
    Enum.all?([@tables_table, @entities_table], fn t -> :ets.info(t) != :undefined end)
  end

  # -- tables ---------------------------------------------------------------

  def create_table(name) when is_binary(name) and name != "" do
    ensure_tables()

    case Store.insert_new(@tables_table, String.downcase(name), %{name: name}) do
      :ok ->
        {:ok, 201, etag_headers(new_etag()), %{"TableName" => name}}

      {:error, :exists} ->
        {:error, 409, "TableAlreadyExists", "The table specified already exists."}
    end
  end

  def create_table(_), do: {:error, 400, "InvalidInput", "TableName required"}

  def list_tables do
    ensure_tables()

    rows =
      Store.list(@tables_table)
      |> Enum.map(fn rec -> %{"TableName" => rec.name} end)

    {:ok, 200, %{}, %{"value" => rows}}
  end

  def delete_table(name) do
    ensure_tables()
    key = String.downcase(name)

    case Store.get(@tables_table, key) do
      :error ->
        {:error, 404, "TableNotFound", "The table specified does not exist."}

      {:ok, _} ->
        for k <- Store.prefix_keys(@entities_table, key <> "/") do
          Store.delete(@entities_table, k)
        end

        Store.delete(@tables_table, key)
        {:ok, 204, %{}, ""}
    end
  end

  # -- entities -------------------------------------------------------------

  def insert_entity(table, props) do
    case normalize(props) do
      {:ok, pk, rk, rest} ->
        with :ok <- table_must_exist(table) do
          key = ekey(table, pk, rk)
        rec = new_rec(rest)

        case Store.insert_new(@entities_table, key, rec) do
          :ok -> {:ok, 201, etag_headers(rec.etag), render(rec)}
          {:error, :exists} -> {:error, 409, "EntityAlreadyExists", "The specified entity already exists."}
        end
        else
          err -> err
        end

      err ->
        err
    end
  end

  def upsert_entity(table, props) do
    case normalize(props) do
      {:ok, pk, rk, rest} ->
        with :ok <- table_must_exist(table) do
          key = ekey(table, pk, rk)
        rec = new_rec(rest)

        case Store.get(@entities_table, key) do
          :error ->
            Store.put(@entities_table, key, rec)
            {:ok, 201, etag_headers(rec.etag), render(rec)}

          {:ok, _} ->
            Store.put(@entities_table, key, rec)
            {:ok, 204, etag_headers(rec.etag), ""}
        end
        else
          err -> err
        end

      err ->
        err
    end
  end

  def merge_entity(table, props) do
    case normalize(props) do
      {:ok, pk, rk, rest} ->
        with :ok <- table_must_exist(table) do
          key = ekey(table, pk, rk)

        case Store.get(@entities_table, key) do
          :error ->
            rec = new_rec(rest)
            Store.put(@entities_table, key, rec)
            {:ok, 201, etag_headers(rec.etag), render(rec)}

          {:ok, old} ->
            rec = new_rec(Map.merge(old.props, rest))
            Store.put(@entities_table, key, rec)
            {:ok, 204, etag_headers(rec.etag), ""}
        end
        else
          err -> err
        end

      err ->
        err
    end
  end

  def replace_entity(table, pk, rk, if_match, props) do
    with {:ok, old} <- fetch(table, pk, rk),
         :ok <- if_match_ok(old, if_match) do
      rec = new_rec(Map.drop(props, ["PartitionKey", "RowKey"]))
      Store.put(@entities_table, ekey(table, pk, rk), rec)
      {:ok, 204, etag_headers(rec.etag), ""}
    end
  end

  def merge_at(table, pk, rk, if_match, props) do
    with {:ok, old} <- fetch(table, pk, rk),
         :ok <- if_match_ok(old, if_match) do
      rec = new_rec(Map.merge(old.props, Map.drop(props, ["PartitionKey", "RowKey"])))
      Store.put(@entities_table, ekey(table, pk, rk), rec)
      {:ok, 204, etag_headers(rec.etag), ""}
    end
  end

  def delete_entity(table, pk, rk, if_match) do
    with {:ok, old} <- fetch(table, pk, rk),
         :ok <- if_match_ok(old, if_match) do
      Store.delete(@entities_table, ekey(table, pk, rk))
      {:ok, 204, %{}, ""}
    end
  end

  def get_entity(table, pk, rk) do
    with {:ok, rec} <- fetch(table, pk, rk) do
      {:ok, 200, etag_headers(rec.etag), render(rec)}
    end
  end

  def query_entities(table) do
    with :ok <- table_must_exist(table) do
      rows =
      Store.prefix_keys(@entities_table, String.downcase(table) <> "/")
      |> Enum.sort()
      |> Enum.flat_map(fn k ->
        case :ets.lookup(@entities_table, k) do
          [{^k, rec}] -> [render(rec)]
          _ -> []
        end
      end)

      {:ok, 200, %{}, %{"value" => rows}}
    end
  end

  # -- internals ------------------------------------------------------------

  defp normalize(props) when is_map(props) do
    pk = props["PartitionKey"]
    rk = props["RowKey"]

    if is_binary(pk) and pk != "" and is_binary(rk) and rk != "" do
      {:ok, pk, rk, Map.drop(props, ["PartitionKey", "RowKey"])}
    else
      {:error, 400, "InvalidInput", "PartitionKey and RowKey are required."}
    end
  end

  defp normalize(_), do: {:error, 400, "InvalidInput", "JSON object body required."}

  defp table_must_exist(table) do
    ensure_tables()

    case Store.get(@tables_table, String.downcase(table)) do
      {:ok, _} -> :ok
      :error -> {:error, 404, "TableNotFound", "The table specified does not exist."}
    end
  end

  defp fetch(table, pk, rk) do
    table_must_exist(table)

    case Store.get(@entities_table, ekey(table, pk, rk)) do
      {:ok, rec} -> {:ok, rec}
      :error -> {:error, 404, "ResourceNotFound", "The specified entity does not exist."}
    end
  end

  defp if_match_ok(_rec, nil), do: :ok
  defp if_match_ok(_rec, "*"), do: :ok

  defp if_match_ok(rec, etag) when is_binary(etag) do
    if etag == rec.etag do
      :ok
    else
      {:error, 412, "UpdateConditionNotSatisfied", "Update condition not satisfied."}
    end
  end

  defp if_match_ok(_, _), do: {:error, 400, "InvalidInput", "If-Match must be a string."}

  defp new_rec(props) do
    ts = now_iso()
    %{etag: "W/\"datetime'" <> ts <> "'\"", props: props, ts: ts}
  end

  defp render(rec) do
    rec.props
    |> Map.put("Timestamp", rec.ts)
    |> Map.put("odata.etag", rec.etag)
  end

  defp ekey(table, pk, rk), do: String.downcase(table) <> "/" <> pk <> "/" <> rk

  defp etag_headers(etag), do: %{"ETag" => etag}

  defp new_etag, do: "W/\"datetime'" <> now_iso() <> "'\""

  defp now_iso do
    dt = DateTime.utc_now()
    base = String.slice(DateTime.to_iso8601(dt), 0, 26)
    base <> "Z"
  end

  defp ensure_tables do
    if :ets.info(@tables_table) == :undefined do
      try do
        :ets.new(@tables_table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    if :ets.info(@entities_table) == :undefined do
      try do
        :ets.new(@entities_table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end

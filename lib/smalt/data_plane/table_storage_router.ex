defmodule Smalt.DataPlane.TableStorageRouter do
  @moduledoc """
  Wire seam for the Table Storage face (lane w6p): parses Plug.Conn into
  TableStorage arm calls and renders responses. Additive literal /tables
  prefix, dispatched from EgressRouter.table_service_plane/2.
  """

  import Plug.Conn

  alias Smalt.DataPlane.TableStorage

  @entity_re ~r/^Entities\((PartitionKey|RowKey)='([^']*)',\s*(PartitionKey|RowKey)='([^']*)'\)$/i

  def route(conn) do
    segs = conn.path_info
    method = conn.method

    case {method, segs} do
      {"POST", ["tables"]} -> create_table_arm(conn)
      {"GET", ["tables"]} -> respond(conn, TableStorage.list_tables())
      {"DELETE", ["tables", name]} -> respond(conn, TableStorage.delete_table(name))
      {"GET", ["tables", t, "Entities()"]} when t != "tables" -> respond(conn, TableStorage.query_entities(t))
      {"GET", ["tables", t, "entities"]} when t != "tables" ->
        case {conn.query_params["PartitionKey"], conn.query_params["RowKey"]} do
          {pk, rk} when is_binary(pk) and is_binary(rk) ->
            respond(conn, TableStorage.get_entity(t, pk, rk))

          _ ->
            respond(conn, TableStorage.query_entities(t))
        end

      {"GET", ["tables", t]} when t != "tables" -> respond(conn, TableStorage.query_entities(t))
      {"GET", ["tables", t, spec]} when t != "tables" ->
        case parse_spec(spec) do
          {pk, rk} -> respond(conn, TableStorage.get_entity(t, pk, rk))
          :error -> nil
        end

      {"POST", ["tables", t, "entities"]} when t != "tables" -> entity_write(conn, t, :insert_entity)
      {"PUT", ["tables", t, "entities"]} when t != "tables" -> entity_write(conn, t, :upsert_entity)
      {"PATCH", ["tables", t, "entities"]} when t != "tables" -> entity_write(conn, t, :merge_entity)
      {"GET", ["tables", t, "entities"]} when t != "tables" -> respond(conn, TableStorage.query_entities(t))
      {"PUT", ["tables", t, spec]} when t != "tables" ->
        spec_arm(conn, t, spec, :replace_entity)

      {"PATCH", ["tables", t, spec]} when t != "tables" ->
        spec_arm(conn, t, spec, :merge_at_entity)

      {"MERGE", ["tables", t, spec]} when t != "tables" ->
        spec_arm(conn, t, spec, :merge_at_entity)

      {"DELETE", ["tables", t, spec]} when t != "tables" ->
        spec_arm(conn, t, spec, :delete_entity)

      _ ->
        nil
    end
  end

  # -- arms -------------------------------------------------------------------

  defp create_table_arm(conn) do
    body = read_body_once(conn)

    case Jason.decode(body) do
      {:ok, %{"TableName" => name}} when is_binary(name) and name != "" ->
        respond(conn, TableStorage.create_table(name))

      _ ->
        respond(conn, {:error, 400, "InvalidInput", "TableName required"})
    end
  end

  defp entity_write(conn, table, kind) do
    body = read_body_once(conn)

    case Jason.decode(body) do
      {:ok, props} when is_map(props) ->
        respond(conn, apply(TableStorage, kind, [table, props]))

      _ ->
        respond(conn, {:error, 400, "InvalidInput", "JSON object body required"})
    end
  end

  defp spec_arm(conn, table, spec, kind) do
    case parse_spec(spec) do
      {pk, rk} ->
        if kind in [:replace_entity, :merge_at_entity] do
          body = read_body_once(conn)

          case Jason.decode(body) do
            {:ok, props} when is_map(props) ->
              if_match = get_req_header(conn, "if-match") |> List.first()
              respond(conn, apply(TableStorage, kind, [table, pk, rk, if_match, props]))

            _ ->
              respond(conn, {:error, 400, "InvalidInput", "JSON object body required"})
          end
        else
          if_match = get_req_header(conn, "if-match") |> List.first()
          respond(conn, TableStorage.delete_entity(table, pk, rk, if_match))
        end

      :error ->
        # w6o unblock: a non-Entities(...) spec is NOT a table-storage request
        # (the face is the Entities() grammar only) — pass through so sibling
        # planes (Azure Files shares/dirs/files at the same /{a}/{b} shape)
        # see the request. Previously swallowed with a JSON 404 (witnessed:
        # Files directory create answered table-storage 404 ResourceNotFound).
        nil
    end
  end

  defp parse_spec(spec) do
    case Regex.run(@entity_re, spec) do
      [_, f1, v1, _f2, v2] ->
        if String.downcase(f1) == "partitionkey" do
          {v1, v2}
        else
          {v2, v1}
        end

      nil ->
        :error
    end
  end

  defp respond(_conn, {:error, :store_not_ready}), do: nil

  defp respond(conn, {:error, status, code, msg}) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => msg}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp respond(conn, {:ok, status, headers, body}) do
    conn2 =
      Enum.reduce(headers || %{}, conn, fn {k, v}, c ->
        put_resp_header(c, String.downcase(k), v)
      end)

    if body in ["", nil] do
      send_resp(conn2, status, "")
    else
      conn2
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  defp read_body_once(conn) do
    # An earlier pipeline plug (Plug.Parsers) may have already consumed the
    # raw body into conn.body_params; prefer that, else read the raw stream.
    case conn.body_params do
      %{} = m when map_size(m) > 0 and not is_struct(m) ->
        # Misparsed-as-form JSON: Plug.Parsers put the whole JSON doc under a
        # single string key with an empty value (no application/json header).
        case Enum.find(m, fn {k, _} -> is_binary(k) and String.contains?(k, "{") end) do
          {k, ""} -> k
          _ -> Jason.encode!(m)
        end

      _ ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        body
    end
  end
end

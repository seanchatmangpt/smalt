defmodule Smalt.CosmosAuthzPlug do
  @moduledoc false
  # Router seam for the Cosmos users/permissions/resource-token surface
  # (lane w6h, wave-6). Lives OUTSIDE the main EgressRouter match — that
  # match function is at a beam implementation limit (witnessed), so the
  # surface is its own small Plug in the egress pipeline, mounted AFTER
  # Smalt.Auth.Bearer and BEFORE :match. Matched paths respond + halt;
  # unmatched pass through unchanged.

  import Plug.Conn
  alias Smalt.DataPlane.CosmosAuthz

  @version "2025-04-15"

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.halted do
      conn
    else
      dispatch(conn)
    end
  end

  defp dispatch(conn) do
    case conn.path_info do
      ["dbs", db, "users"] ->
        on_collection(conn, db)

      ["dbs", db, "users", user] ->
        on_item(conn, db, user)

      ["dbs", db, "users", user, "permissions"] ->
        on_perm_feed(conn, db, user)

      ["dbs", db, "users", user, "permissions", perm] ->
        on_perm_item(conn, db, user, perm)

      _ ->
        conn
    end
  end

  defp on_collection(%{method: "POST"} = conn, db) do
    case ensure_parsed(conn) do
      {:ok, params, conn} ->
        case body_id(params) do
          {:ok, id} -> respond(conn, CosmosAuthz.create_user(db, id))
          :error -> json_error(conn, 400, "BadRequest", "Required property 'id' is missing")
        end

      :error ->
        json_error(conn, 400, "BadRequest", "Required property 'id' is missing")
    end
  end

  defp on_collection(conn, db), do: feed(conn, CosmosAuthz.list_users(db))

  defp on_item(%{method: "GET"} = conn, db, user) do
    respond(conn, CosmosAuthz.get_user(db, user))
  end

  defp on_item(%{method: "DELETE"} = conn, db, user) do
    case CosmosAuthz.delete_user(db, user) do
      :ok -> conn |> put_resp_header("x-ms-request-id", rid()) |> send_resp(204, "")
      other -> respond(conn, other)
    end
  end

  defp on_item(conn, _db, _user), do: method_not_allowed(conn)

  defp on_perm_feed(%{method: "POST"} = conn, db, user) do
    case ensure_parsed(conn) do
      {:ok, params, conn} ->
        respond(conn, CosmosAuthz.create_permission(db, user, params))

      :error ->
        json_error(conn, 400, "BadRequest", "Invalid JSON body")
    end
  end

  defp on_perm_feed(%{method: "GET"} = conn, db, user) do
    feed(conn, CosmosAuthz.list_permissions(db, user))
  end

  defp on_perm_feed(conn, _db, _user), do: method_not_allowed(conn)

  defp on_perm_item(%{method: m} = conn, db, user, perm) when m in ["GET", "POST"] do
    respond(conn, CosmosAuthz.get_permission(db, user, perm))
  end

  defp on_perm_item(%{method: "DELETE"} = conn, db, user, perm) do
    case CosmosAuthz.delete_permission(db, user, perm) do
      :ok -> conn |> put_resp_header("x-ms-request-id", rid()) |> send_resp(204, "")
      other -> respond(conn, other)
    end
  end

  defp on_perm_item(conn, _db, _user, _perm), do: method_not_allowed(conn)

  # -- response helpers -------------------------------------------------------

  defp respond(conn, {:ok, status, body}) do
    conn
    |> put_resp_header("x-ms-request-id", rid())
    |> put_resp_header("x-ms-version", @version)
    |> put_resp_header("x-ms-request-charge", "1.0")
    |> json_send(status, body)
  end

  defp respond(conn, {:error, status, body}) do
    conn
    |> put_resp_header("x-ms-request-id", rid())
    |> json_send(status, body)
  end

  defp feed(conn, {:ok, feed_map}) do
    respond(conn, {:ok, 200, feed_map})
  end

  defp json_send(conn, status, body) do
    case Jason.encode(body) do
      {:ok, json} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(status, json)

      {:error, _} ->
        send_resp(conn, 500, ~s({"code":"EncodeFailure"}))
    end
  end

  defp json_error(conn, status, code, msg) do
    respond(conn, {:error, status, %{"code" => code, "message" => msg}})
  end

  defp method_not_allowed(conn) do
    json_error(conn, 405, "MethodNotAllowed", "Method not supported on this resource")
  end

  defp ensure_parsed(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case read_body(conn) do
          {:ok, raw, conn} -> {:ok, Smalt.JsonCompat.decode!(raw), conn}
          _ -> :error
        end
      params when is_map(params) -> {:ok, params, conn}
      _ -> :error
    end
  end

  defp body_id(params) do
    case params do
      %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> :error
    end
  end

  defp rid do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

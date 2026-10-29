defmodule Smalt.AppConfigRevisionsPlug do
  @moduledoc """
  Wave-6 lane w6ao - wire face for the App Configuration revision history
  (w6h pattern: dedicated plug, ONE additive mount line in EgressRouter,
  staged in tmp/w6ao_router_patch.txt under the router hold).

  Faces (real App Config parity, read-mostly):
    GET /revisions                     - list (key=/label=/end-time filters)
    POST /revisions/:etag/restore      - restore a revision as current kv
  """
  use Plug.Router
  plug :match
  plug :dispatch

  get "/revisions" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      filters = [
        key: conn.query_params["key"],
        label: conn.query_params["label"],
        end_time: int_or_nil(conn.query_params["end-time"])
      ]

      items =
        Smalt.AppConfigRevisions.list(filters)
        |> Enum.map(&Smalt.AppConfigRevisions.revision_wire/1)

      send_json(conn, 200, %{"items" => items})
    end
  end

  post "/revisions/:etag/restore" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      etag = etag |> Enum.join("/") |> URI.decode()

      case Smalt.AppConfigRevisions.restore(etag) do
        {:ok, restored} ->
          send_json(conn, 200, Smalt.AppConfigRevisions.revision_wire(restored))

        {:error, :not_found} ->
          send_json(conn, 404, %{
            "error" => %{"code" => "RevisionNotFound", "message" => "revision #{etag} not found"}
          })

        {:error, :store_not_ready} ->
          route_not_ready(conn)
      end
    end
  end

  match _ do
    conn
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp route_not_ready(conn) do
    Plug.Conn.send_resp(conn, 503, "store not ready")
  end

  defp int_or_nil(nil), do: nil

  defp int_or_nil(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> n
      _ -> nil
    end
  end
end

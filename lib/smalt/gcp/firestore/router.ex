defmodule Smalt.GCP.Firestore.Router do
  @moduledoc """
  Firestore v1 REST routes. Mount with `forward "/v1", to: Smalt.GCP.Firestore.Router`.
  Paths: `/projects/:p/databases/:d/documents[/<path>][:verb]`.
  """
  use Plug.Router
  alias Smalt.GCP.Firestore, as: F

  plug :match
  plug :dispatch

  match "/projects/:project/databases/:_db/*rest" do
    {status, body} = route(conn.method, project, rest, conn)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  match _ do
    {s, b} = F.error(404, "NOT_FOUND", "unknown Firestore route")
    conn |> put_resp_content_type("application/json") |> send_resp(s, Jason.encode!(b))
  end

  # rest = ["documents", ...segments] ; last segment may carry ":verb"
  defp route(method, project, ["documents:" <> verb], conn), do: verb(method, project, verb, "", conn)
  defp route(method, project, ["documents" | segs], conn) do
    {segs, verb} = split_verb(segs)
    path = Enum.join(segs, "/")

    case verb do
      nil -> crud(method, project, segs, path, conn)
      v -> verb(method, project, v, path, conn)
    end
  end

  defp route(_, _, _, _), do: F.error(404, "NOT_FOUND", "unknown Firestore route")

  defp split_verb([]), do: {[], nil}

  defp split_verb(segs) do
    last = List.last(segs)

    case String.split(last, ":", parts: 2) do
      [base, v] -> {List.replace_at(segs, -1, base), v}
      _ -> {segs, nil}
    end
  end

  # database-level verbs arrive as /databases/(default)/documents:verb or /databases/(default):verb
  defp verb("POST", p, "runQuery", path, conn), do: F.run_query(p, path, body(conn))
  defp verb("POST", p, "commit", _path, conn), do: F.commit(p, body(conn))
  defp verb("POST", p, "batchWrite", _path, conn), do: F.batch_write(p, body(conn))
  defp verb("POST", p, "beginTransaction", _path, _conn), do: F.begin_transaction(p)
  defp verb("POST", p, "rollback", _path, conn), do: F.rollback(p, body(conn)["transaction"] || "")
  defp verb(_, _, v, _, _), do: F.error(404, "NOT_FOUND", "unsupported verb #{v}")

  defp crud("GET", p, segs, path, conn) do
    if rem(length(segs), 2) == 1, do: F.list(p, path), else: F.get(p, path, q1(conn, "transaction"))
  end

  defp crud("POST", p, [_ | _] = segs, path, conn) when rem(length(segs), 2) == 1 do
    F.create(p, path, q1(conn, "documentId"), body(conn))
  end

  defp crud("PATCH", p, segs, path, conn) when rem(length(segs), 2) == 0 and segs != [] do
    mask = qall(conn, "updateMask.fieldPaths")
    mask = if mask == [], do: nil, else: mask

    pre = %{
      update_time: q1(conn, "currentDocument.updateTime"),
      exists: parse_bool(q1(conn, "currentDocument.exists"))
    }

    F.patch(p, path, body(conn), mask, pre)
  end

  defp crud("DELETE", p, segs, path, conn) when rem(length(segs), 2) == 0 and segs != [] do
    F.delete(p, path, %{
      update_time: q1(conn, "currentDocument.updateTime"),
      exists: parse_bool(q1(conn, "currentDocument.exists"))
    })
  end

  defp crud(_, _, _, _, _), do: F.error(400, "INVALID_ARGUMENT", "unsupported method/path combination")

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp qall(conn, name), do: for({^name, v} <- URI.query_decoder(conn.query_string), do: v)
  defp q1(conn, name), do: List.first(qall(conn, name))

  defp body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    {:ok, raw, _} = Plug.Conn.read_body(conn)
    if raw == "", do: %{}, else: Jason.decode!(raw)
  end

  defp body(%Plug.Conn{body_params: bp}), do: bp
end

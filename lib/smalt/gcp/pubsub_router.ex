defmodule Smalt.Gcp.PubSubRouter do
  @moduledoc """
  Wire seam for the Cloud Pub/Sub REST v1 face (lane GS2). `route/1` takes a
  `Plug.Conn`, answers it when the path is `/v1/projects/{p}/(topics|
  subscriptions|snapshots)...` and returns `nil` otherwise so the caller's
  dispatcher can fall through. Bodies are read here (JSON), so it must run
  before any body parser consumes the conn.
  """

  import Plug.Conn

  alias Smalt.Gcp.PubSub

  def route(%Plug.Conn{path_info: ["v1", "projects", p, coll | rest]} = conn)
      when coll in ["topics", "subscriptions", "snapshots"] do
    dispatch(conn, conn.method, p, coll, rest)
  end

  def route(_), do: nil

  defp name(p, coll, id), do: "projects/#{p}/#{coll}/#{id}"

  # ---- topics
  defp dispatch(conn, "GET", p, "topics", []), do: reply(conn, PubSub.list_topics(p))
  defp dispatch(conn, "PUT", p, "topics", [id]), do: reply(conn, PubSub.create_topic(name(p, "topics", id)))
  defp dispatch(conn, "GET", p, "topics", [id]), do: reply(conn, PubSub.get_topic(name(p, "topics", id)))
  defp dispatch(conn, "DELETE", p, "topics", [id]), do: reply(conn, PubSub.delete_topic(name(p, "topics", id)))

  defp dispatch(conn, "POST", p, "topics", [seg]) do
    case String.split(seg, ":", parts: 2) do
      [id, "publish"] ->
        with_body(conn, fn body -> PubSub.publish(name(p, "topics", id), body["messages"] || []) end)

      _ ->
        nil
    end
  end

  # ---- subscriptions
  defp dispatch(conn, "GET", p, "subscriptions", []), do: reply(conn, PubSub.list_subscriptions(p))

  defp dispatch(conn, "PUT", p, "subscriptions", [id]),
    do: with_body(conn, &PubSub.create_subscription(name(p, "subscriptions", id), &1))

  defp dispatch(conn, "GET", p, "subscriptions", [id]),
    do: reply(conn, PubSub.get_subscription(name(p, "subscriptions", id)))

  defp dispatch(conn, "DELETE", p, "subscriptions", [id]),
    do: reply(conn, PubSub.delete_subscription(name(p, "subscriptions", id)))

  defp dispatch(conn, "POST", p, "subscriptions", [seg]) do
    case String.split(seg, ":", parts: 2) do
      [id, "pull"] ->
        with_body(conn, &PubSub.pull(name(p, "subscriptions", id), &1))

      [id, "acknowledge"] ->
        with_body(conn, &PubSub.acknowledge(name(p, "subscriptions", id), &1["ackIds"] || []))

      [id, "modifyAckDeadline"] ->
        with_body(conn, fn b ->
          PubSub.modify_ack_deadline(name(p, "subscriptions", id), b["ackIds"] || [], b["ackDeadlineSeconds"])
        end)

      [id, "seek"] ->
        with_body(conn, &PubSub.seek(name(p, "subscriptions", id), &1))

      _ ->
        nil
    end
  end

  # ---- snapshots
  defp dispatch(conn, "GET", p, "snapshots", []), do: reply(conn, PubSub.list_snapshots(p))

  defp dispatch(conn, "PUT", p, "snapshots", [id]),
    do: with_body(conn, &PubSub.create_snapshot(name(p, "snapshots", id), &1))

  defp dispatch(conn, "GET", p, "snapshots", [id]), do: reply(conn, PubSub.get_snapshot(name(p, "snapshots", id)))

  defp dispatch(conn, "DELETE", p, "snapshots", [id]),
    do: reply(conn, PubSub.delete_snapshot(name(p, "snapshots", id)))

  defp dispatch(_conn, _m, _p, _c, _r), do: nil

  # ---- plumbing
  defp with_body(conn, fun) do
    {:ok, raw, conn} = read_body(conn)

    case decode(raw) do
      {:ok, body} -> reply(conn, fun.(body))
      :error -> reply(conn, {:error, 400, "INVALID_ARGUMENT", "request body is not valid JSON"})
    end
  end

  defp decode(""), do: {:ok, %{}}

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> :error
    end
  end

  defp reply(conn, {:ok, body}), do: json(conn, 200, body)

  defp reply(conn, {:error, http, status, msg}),
    do: json(conn, http, %{"error" => %{"code" => http, "message" => msg, "status" => status}})

  defp json(conn, code, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(code, Jason.encode!(body))
    |> halt()
  end
end

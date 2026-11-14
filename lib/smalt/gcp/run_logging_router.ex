defmodule Smalt.GCP.RunLoggingRouter do
  @moduledoc """
  Wire seam for Cloud Run Admin v2 + Cloud Logging v2 (lane SW4).
  `route/1` takes a `Plug.Conn`, answers it and returns the halted conn when
  the path belongs to this face, else returns `nil` so the host dispatcher
  falls through. Reads the JSON body itself (run before any body parser).

  Run: `/v2/projects/{p}/locations/{l}/services[/{s}[/revisions[/{r}]]]`,
  `services/{s}:getIamPolicy|:setIamPolicy`, `operations/{id}`.
  Logging: `/v2/entries:write`, `/v2/entries:list`,
  `/v2/projects/{p}/sinks[/{id}]` (sinks stored as plain rows, no export).
  """

  import Plug.Conn

  alias Smalt.GCP.{CloudRun, Logging}
  alias Smalt.Store

  @table :smalt_resources

  def route(%Plug.Conn{path_info: ["v2", "projects", p, "locations", l | rest]} = conn),
    do: run(conn, conn.method, p, l, rest)

  def route(%Plug.Conn{path_info: ["v2", "entries:" <> verb]} = conn) when verb in ["write", "list"],
    do: entries(conn, conn.method, verb)

  def route(%Plug.Conn{path_info: ["v2", "projects", p, "sinks" | rest]} = conn),
    do: sinks(conn, conn.method, p, rest)

  def route(_), do: nil

  # ---- Cloud Run
  defp run(conn, "POST", p, l, ["services"]) do
    conn = fetch_query_params(conn)
    sid = conn.query_params["serviceId"] || ""
    with_body(conn, &CloudRun.create_service(p, l, sid, &1))
  end

  defp run(conn, "GET", p, l, ["services"]) do
    svcs = CloudRun.list_services(p, l) |> Enum.map(&public/1)
    reply(conn, {:ok, %{"services" => svcs}})
  end

  defp run(conn, "GET", p, l, ["services", s]) do
    reply(conn, with({:ok, svc} <- CloudRun.get_service(p, l, s), do: {:ok, public(svc)}))
  end

  defp run(conn, m, p, l, ["services", s]) when m in ["PATCH", "PUT"],
    do: with_body(conn, &CloudRun.replace_service(p, l, s, &1))

  defp run(conn, "DELETE", p, l, ["services", s]), do: reply(conn, CloudRun.delete_service(p, l, s))

  defp run(conn, "GET", p, l, ["services", s, "revisions"]),
    do: reply(conn, {:ok, %{"revisions" => CloudRun.list_revisions(p, l, s)}})

  defp run(conn, "GET", p, l, ["services", s, "revisions", r]),
    do: reply(conn, CloudRun.get_revision(p, l, s, r))

  defp run(conn, "GET", _p, _l, ["operations", id]), do: reply(conn, CloudRun.get_operation(id))

  defp run(conn, "POST", p, l, ["services", seg]) do
    case String.split(seg, ":", parts: 2) do
      [s, "getIamPolicy"] -> reply(conn, CloudRun.get_iam_policy(p, l, s))
      [s, "setIamPolicy"] -> with_body(conn, &CloudRun.set_iam_policy(p, l, s, &1["policy"] || %{}))
      _ -> nil
    end
  end

  defp run(_conn, _m, _p, _l, _rest), do: nil

  defp public(svc), do: Map.reject(svc, fn {k, _} -> String.starts_with?(k, "_") end)

  # ---- Logging entries
  defp entries(conn, "POST", "write"), do: with_body(conn, &Logging.write_entries/1)
  defp entries(conn, "POST", "list"), do: with_body(conn, &Logging.list_entries/1)
  defp entries(_conn, _m, _v), do: nil

  # ---- Logging sinks
  defp sinks(conn, "GET", p, []) do
    reply(conn, {:ok, %{"sinks" => Store.list_prefix(@table, "gcp:logsink:#{p}/")}})
  end

  defp sinks(conn, "POST", p, []) do
    with_body(conn, fn body ->
      id = body["name"]

      cond do
        not is_binary(id) or id == "" ->
          {:error, {400, "INVALID_ARGUMENT", "sink name required"}}

        match?({:ok, _}, Store.get(@table, skey(p, id))) ->
          {:error, {409, "ALREADY_EXISTS", "sink #{id} already exists"}}

        true ->
          sink = Map.put(body, "name", id) |> Map.put_new("destination", "") |> Map.put("writerIdentity", "serviceAccount:smalt-log@#{p}.iam.gserviceaccount.com")
          Store.put(@table, skey(p, id), sink)
          {:ok, sink}
      end
    end)
  end

  defp sinks(conn, "GET", p, [id]), do: reply(conn, fetch_sink(p, id))

  defp sinks(conn, m, p, [id]) when m in ["PUT", "PATCH"] do
    with_body(conn, fn body ->
      with {:ok, old} <- fetch_sink(p, id) do
        sink = old |> Map.merge(body) |> Map.put("name", id)
        Store.put(@table, skey(p, id), sink)
        {:ok, sink}
      end
    end)
  end

  defp sinks(conn, "DELETE", p, [id]) do
    case fetch_sink(p, id) do
      {:ok, _} ->
        Store.delete(@table, skey(p, id))
        reply(conn, {:ok, %{}})

      err ->
        reply(conn, err)
    end
  end

  defp sinks(_conn, _m, _p, _r), do: nil

  defp skey(p, id), do: "gcp:logsink:#{p}/#{id}"

  defp fetch_sink(p, id) do
    case Store.get(@table, skey(p, id)) do
      {:ok, s} -> {:ok, s}
      :error -> {:error, {404, "NOT_FOUND", "sink #{id} not found"}}
    end
  end

  # ---- plumbing
  defp with_body(conn, fun) do
    {:ok, raw, conn} = read_body(conn)

    case decode(raw) do
      {:ok, body} -> reply(conn, fun.(body))
      :error -> reply(conn, {:error, {400, "INVALID_ARGUMENT", "request body is not valid JSON"}})
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

  defp reply(conn, {:error, {http, status, msg}}),
    do: json(conn, http, %{"error" => %{"code" => http, "message" => msg, "status" => status}})

  defp json(conn, code, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(code, Jason.encode!(body))
    |> halt()
  end
end

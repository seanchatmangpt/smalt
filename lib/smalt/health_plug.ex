defmodule Smalt.HealthPlug do
  @moduledoc """
  Readiness + liveness endpoints for the adaptive-probe phase (v26.10.19).

  Mount as the FIRST plug in any Plug.Router chain (before `Plug.Parsers` and
  match-on-path routers) so probes answer without auth/body parsing:

      plug(Smalt.HealthPlug)

  Routes:
    * `GET /healthz`       — readiness: 200 ready / 503 degraded (structural
      failures only; scheduler load is reported, never fatal).
    * `GET /healthz/live`  — liveness: always 200 on a live beam, never fails
      on load.

  Responses are JSON, rendered without Jason dependency assumptions — if the
  host app has Jason available it is used; otherwise a minimal serializer.

  CORS: because this plug mounts BEFORE the egress `:egress_cors` plug, its
  answers would otherwise carry no `Access-Control-Allow-Origin` and a browser
  health probe is auto-blocked. When an `Origin` header is present, health
  responses echo the same origins config as the rest of the egress face
  (`:smalt, :egress_cors_origins`, default `["*"]`), and `OPTIONS` preflights
  answer `204` with allow-methods `GET, HEAD, OPTIONS`. Requests without an
  `Origin` are byte-identical to the pre-CORS behavior.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "OPTIONS", path_info: ["healthz" | _]} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> conn
      _origin -> preflight(conn)
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
    verdict = Smalt.Health.readiness()
    body = Jason.encode!(Map.merge(Smalt.Health.to_json_map(verdict), probe_identity()))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> put_cors_origin()
    |> Plug.Conn.send_resp(Smalt.Health.http_status(verdict), body)
    |> Plug.Conn.halt()
  end

  def call(%Plug.Conn{method: "GET", path_info: ["healthz", "live"]} = conn, _opts) do
    body = Jason.encode!(Map.merge(%{status: "alive"}, probe_identity()))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> put_cors_origin()
    |> Plug.Conn.send_resp(200, body)
    |> Plug.Conn.halt()
  end

  def call(conn, _opts), do: conn

  # W30-I adoption (Z4): vNext probe bodies carry app version + UTC timestamp.
  defp probe_identity do
    %{
      "version" => to_string(Application.spec(:smalt, :vsn)),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # w6ay/popcorn lane B2: mirror the egress face's origins config so the
  # first-mounted health plug answers browser probes on 8443.
  defp put_cors_origin(conn) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        conn

      [origin | _] ->
        origins = Application.get_env(:smalt, :egress_cors_origins, ["*"])

        if origin_allowed?(origins, origin) do
          Plug.Conn.put_resp_header(conn, "access-control-allow-origin", origin)
        else
          conn
        end
    end
  end

  defp origin_allowed?(origins, origin) do
    Enum.any?(origins, fn allowed -> allowed == "*" or allowed == origin end)
  end

  defp preflight(conn) do
    conn
    |> put_cors_origin()
    |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> Plug.Conn.send_resp(204, "")
    |> Plug.Conn.halt()
  end
end

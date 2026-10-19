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
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
    verdict = Smalt.Health.readiness()
    body = Jason.encode!(Smalt.Health.to_json_map(verdict))

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(Smalt.Health.http_status(verdict), body)
  end

  def call(%Plug.Conn{method: "GET", path_info: ["healthz", "live"]} = conn, _opts) do
    body = Jason.encode!(%{status: "alive"})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  def call(conn, _opts), do: conn
end

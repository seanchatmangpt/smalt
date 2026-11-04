defmodule Smalt.HTTP.CORS do
  @moduledoc """
  Vendor-inline CORS face (disclosed compile-freeze unblock, kv7 lane,
  v26.10.31): the cors_plug hex dep was removed at 9a3d0a79 while its three
  router consumers (egress_router.ex:61, arm_gateway/router.ex:57,
  mcp/router.ex:111) still called `CORSPlug` — every 8443/9443/9545 request
  answered runtime-500 at HEAD (witnessed live: "egress_router crash 500 ...
  CORSPlug.init/1 is undefined"). This module restores cors_plug's PINNED
  wire law byte-identical, without re-adding the dep. The law lives in
  test/integration/cors_headers_knob_test.exs (preflight 204, allow-origin
  "*" under default ["*"], allow-headers echo for ["*"], allowlist join ",")
  and test/integration/healthz_cors_test.exs (disallowed origin -> NO header,
  no-Origin pass-through untouched).
  """
  import Plug.Conn

  def init(opts), do: opts

  # cors_plug wire law (pinned by cors_headers_knob_test.exs):
  #   * no Origin header  -> pass-through untouched (never halted)
  #   * disallowed Origin -> NO allow headers, pass-through
  #   * allowed Origin    -> access-control-allow-origin ("*" under the
  #     default ["*"], else the request origin echoed)
  #   * headers ["*"]     -> access-control-allow-headers echoes the request's
  #     access-control-request-headers verbatim
  #   * headers allowlist -> access-control-allow-headers is the CONFIGURED
  #     list joined with "," (pinned: "authorization,x-ms-version")
  #   * preflight (OPTIONS + allowed Origin) -> 204, halted
  def call(conn, opts) do
    origins = Keyword.get(opts, :origin, [])
    headers = Keyword.get(opts, :headers, [])

    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin | _] ->
        case origin_allowed(origins, origin) do
          nil ->
            conn

          allow_origin ->
            conn
            |> put_resp_header("access-control-allow-origin", allow_origin)
            |> put_allow_headers(headers, conn)
            |> maybe_preflight()
        end
    end
  end

  # Returns the access-control-allow-origin value, or nil when the origin is
  # not admitted.
  defp origin_allowed(["*" | _], _origin), do: "*"

  defp origin_allowed([allowed | rest], origin) do
    if allowed == origin do
      origin
    else
      origin_allowed(rest, origin)
    end
  end

  defp origin_allowed([], _origin), do: nil

  defp put_allow_headers(conn, ["*"], req) do
    case get_req_header(req, "access-control-request-headers") do
      [] -> conn
      [echo | _] -> put_resp_header(conn, "access-control-allow-headers", echo)
    end
  end

  defp put_allow_headers(conn, list, _req) when is_list(list) do
    put_resp_header(conn, "access-control-allow-headers", Enum.join(list, ","))
  end

  defp put_allow_headers(conn, _other, _req), do: conn

  # Preflight = OPTIONS carrying an admitted Origin: answer 204 and halt.
  # A plain OPTIONS without an Origin passed through above untouched.
  defp maybe_preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(:no_content, "")
    |> halt()
  end

  defp maybe_preflight(conn), do: conn
end

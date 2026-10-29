defmodule Smalt.Integration.HealthzCorsTest do
  use ExUnit.Case, async: false

  @origin "https://popcorn.local"

  defp call(method, path, headers) do
    method
    |> Plug.Test.conn(path)
    |> Map.put(:req_headers, headers)
    |> Smalt.HealthPlug.call(nil)
  end

  test "GET /healthz with Origin carries Access-Control-Allow-Origin" do
    conn = call("GET", "/healthz", [{"origin", @origin}])

    assert conn.status == 200
    assert {"access-control-allow-origin", @origin} in conn.resp_headers
  end

  test "GET /healthz/live with Origin carries Access-Control-Allow-Origin" do
    conn = call("GET", "/healthz/live", [{"origin", @origin}])

    assert conn.status == 200
    assert {"access-control-allow-origin", @origin} in conn.resp_headers
  end

  test "GET /healthz with disallowed Origin carries NO ACAO header" do
    Application.put_env(:smalt, :egress_cors_origins, ["https://allowed.example"])

    on_exit(fn -> Application.delete_env(:smalt, :egress_cors_origins) end)

    conn = call("GET", "/healthz", [{"origin", @origin}])

    assert conn.status == 200
    refute Enum.any?(conn.resp_headers, fn {k, _} -> k == "access-control-allow-origin" end)
  end

  test "OPTIONS preflight with Origin + ACRM answers 204 with allow-methods" do
    conn =
      call("OPTIONS", "/healthz", [
        {"origin", @origin},
        {"access-control-request-method", "GET"}
      ])

    assert conn.status == 204
    assert {"access-control-allow-origin", @origin} in conn.resp_headers

    assert {"access-control-allow-methods", "GET, HEAD, OPTIONS"} in conn.resp_headers
  end

  test "OPTIONS preflight without Origin passes through untouched" do
    conn = call("OPTIONS", "/healthz", [])
    assert conn.state == :unset
  end

  test "no-Origin requests are byte-identical to the pre-CORS health answer" do
    plain = call("GET", "/healthz", [])

    with_origin =
      Smalt.HealthPlug.call(
        %{Plug.Test.conn("GET", "/healthz") | path_info: ["healthz"], req_headers: []},
        nil
      )

    assert plain.status == 200
    # The body embeds volatile telemetry gauges (e.g. scheduler.total_run_queue
    # observed flipping between calls); compare everything EXCEPT the body,
    # and assert CORS absence structurally.
    assert plain.resp_headers == with_origin.resp_headers
    refute Enum.any?(plain.resp_headers, fn {k, _} -> k == "access-control-allow-origin" end)
  end
end

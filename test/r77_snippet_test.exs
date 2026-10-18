defmodule R77SnippetTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.EgressRouter

  @opts EgressRouter.init([])

  setup do
    SmaltTest.Store.resilient_setup()
    :ok
  end

  defp call(method, path, headers) do
    conn(method, path, "")
    |> put_req_header("authorization", "Bearer test-token")
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end) end)
    |> EgressRouter.call(@opts)
  end

  test "create-time metadata lands on a fresh container (R77)" do
    call(:put, "/r77acct/cmeta", [{"x-ms-version", "2021-12-02"}, {"x-ms-meta-env", "prod"}])
    |> then(fn c -> assert c.status in [200, 201] end)

    conn = call(:get, "/r77acct/cmeta?restype=container", [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
    assert "prod" in get_resp_header(conn, "x-ms-meta-env")
  end
end

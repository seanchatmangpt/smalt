defmodule Smalt.Internal.Bk101G3SeamProbeTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  alias Plug.Adapters.Test.Conn, as: TestConn

  test "with_valid_body refuses Unfetched body with 400 InvalidBody" do
    conn = %Plug.Conn{} |> TestConn.conn("POST", "/app/transactions", "")
    c1 = Smalt.EgressRouter.with_valid_body(conn, fn c -> c end)
    assert c1.status == 400
    assert get_in(Jason.decode!(c1.resp_body), ["error", "code"]) == "InvalidBody"
  end

  @tag :capture_log
  test "safe_dispatch rescues FunctionClauseError to 400 and logs the site line" do
    conn = %Plug.Conn{} |> TestConn.conn("POST", "/app/transactions", "")
    import ExUnit.CaptureLog

    assert capture_log(fn ->
             c2 = Smalt.EgressRouter.safe_dispatch(conn, fn _ -> raise FunctionClauseError end)
             assert c2.status == 400
           end) =~ "egress invalid body on /app/transactions"
  end
end

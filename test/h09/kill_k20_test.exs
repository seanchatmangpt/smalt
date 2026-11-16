defmodule Smalt.H09.KillK20Test do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Smalt.EgressRouter

  describe "Key Vault unauthenticated request receives 401 challenge" do
    test "tokenless GET /keys/:name receives 401 challenge with WWW-Authenticate header" do
      conn =
        conn(:get, "/keys/target-key-01")
        |> EgressRouter.call([])

      assert conn.status == 401
      assert conn.halted

      [www_auth] = get_resp_header(conn, "www-authenticate")
      assert String.starts_with?(www_auth, "Bearer ")
      assert www_auth =~ "authorization="
      assert www_auth =~ "MissingBearerToken"

      expose_headers = get_resp_header(conn, "access-control-expose-headers")
      assert "www-authenticate" in expose_headers

      body = Jason.decode!(conn.resp_body)
      assert body == %{
               "error" => %{
                 "code" => "AuthenticationFailed",
                 "message" => "MissingBearerToken"
               }
             }
    end

    test "tokenless POST /keys/:name/create receives 401 challenge" do
      conn =
        conn(:post, "/keys/target-key-02/create", Jason.encode!(%{"kty" => "RSA"}))
        |> put_req_header("content-type", "application/json")
        |> EgressRouter.call([])

      assert conn.status == 401
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "AuthenticationFailed"
      assert body["error"]["message"] == "MissingBearerToken"
    end

    test "GET /keys with empty authorization header receives 401 challenge" do
      conn =
        conn(:get, "/keys")
        |> put_req_header("authorization", "")
        |> EgressRouter.call([])

      assert conn.status == 401
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "AuthenticationFailed"
      assert body["error"]["message"] == "MissingBearerToken"
    end

    test "OPTIONS /keys preflight is exempt from 401 challenge" do
      conn =
        conn(:options, "/keys/target-key-01")
        |> EgressRouter.call([])

      refute conn.status == 401
    end
  end

  describe "Confidential Ledger POST /app/transactions with top-level JSON array returns 400" do
    test "POST with non-empty JSON array returns 400 InvalidBody" do
      conn =
        conn(:post, "/app/transactions", Jason.encode!([1, 2, 3]))
        |> put_req_header("content-type", "application/json")
        |> EgressRouter.call([])

      assert conn.status == 400
      assert get_resp_header(conn, "x-ms-error-code") == ["InvalidBody"]

      body = Jason.decode!(conn.resp_body)
      assert body == %{"error" => %{"code" => "InvalidBody"}}
    end

    test "POST with empty JSON array returns 400 InvalidBody" do
      conn =
        conn(:post, "/app/transactions", Jason.encode!([]))
        |> put_req_header("content-type", "application/json")
        |> EgressRouter.call([])

      assert conn.status == 400
      assert get_resp_header(conn, "x-ms-error-code") == ["InvalidBody"]

      body = Jason.decode!(conn.resp_body)
      assert body == %{"error" => %{"code" => "InvalidBody"}}
    end

    test "POST with list of JSON objects returns 400 InvalidBody" do
      conn =
        conn(:post, "/app/transactions", Jason.encode!([%{"entry" => "v1"}, %{"entry" => "v2"}]))
        |> put_req_header("content-type", "application/json")
        |> EgressRouter.call([])

      assert conn.status == 400
      assert get_resp_header(conn, "x-ms-error-code") == ["InvalidBody"]

      body = Jason.decode!(conn.resp_body)
      assert body == %{"error" => %{"code" => "InvalidBody"}}
    end

    test "POST with list of strings returns 400 InvalidBody" do
      conn =
        conn(:post, "/app/transactions", Jason.encode!(["entry_a", "entry_b"]))
        |> put_req_header("content-type", "application/json")
        |> EgressRouter.call([])

      assert conn.status == 400
      assert get_resp_header(conn, "x-ms-error-code") == ["InvalidBody"]

      body = Jason.decode!(conn.resp_body)
      assert body == %{"error" => %{"code" => "InvalidBody"}}
    end

    test "POST with valid JSON map returns 201 Created (contrast boundary)" do
      payload = %{"action" => "test_k20", "nonce" => System.unique_integer([:positive])}

      conn =
        conn(:post, "/app/transactions", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> EgressRouter.call([])

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["subLedgerId"] == "default_ledger"
      assert is_binary(body["transactionId"])
      assert body["contents"] == payload
    end
  end
end

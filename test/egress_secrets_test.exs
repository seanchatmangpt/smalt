defmodule EgressSecretsTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.EgressRouter
  alias Smalt.Store

  @opts EgressRouter.init([])

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    :ok
  end

  defp call(method, path, opts \\ []) do
    body = opts[:body] || %{}

    conn =
      conn(method, path, if(is_map(body), do: Jason.encode!(body), else: body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer egress-secrets-harness")
      |> then(fn c ->
        Enum.reduce(opts[:headers] || [], c, fn {k, v}, c -> put_req_header(c, k, v) end)
      end)

    EgressRouter.call(conn, @opts)
  end

  defp jwt_headers(conn), do: get_resp_header(conn, "www-authenticate")

  describe "PUT /secrets/:name" do
    test "minimal body roundtrips via GET" do
      conn = call(:put, "/secrets/db-password", body: %{"value" => "s3cret!"})

      assert conn.status == 200
      put_body = Jason.decode!(conn.resp_body)
      assert put_body["value"] == "s3cret!"
      assert put_body["id"] =~ "/secrets/db-password/"
      assert put_body["attributes"]["enabled"] == true
      assert is_integer(put_body["attributes"]["created"])

      get_conn = call(:get, "/secrets/db-password")
      assert get_conn.status == 200
      got = Jason.decode!(get_conn.resp_body)
      assert got["value"] == "s3cret!"
      assert got["id"] == put_body["id"]
    end

    test "KV REST shape (attributes.expires, contentType)" do
      conn =
        call(:put, "/secrets/kv-shape", %{
          body: %{
            "value" => "v",
            "attributes" => %{"enabled" => false, "expires" => 1_900_000_000},
            "contentType" => "text/plain"
          }
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["attributes"]["enabled"] == false
      assert body["attributes"]["expires"] == 1_900_000_000
      assert body["contentType"] == "text/plain"
    end

    test "missing or non-string value -> typed 400" do
      for body <- [%{}, %{"value" => 5}, %{"attributes" => %{}}] do
        conn = call(:put, "/secrets/bad", body: body)
        assert conn.status == 400
        %{"error" => %{"code" => code}} = Jason.decode!(conn.resp_body)
        assert code in ["InvalidBody", "InvalidParameter"]
      end
    end
  end

  describe "GET /secrets (list)" do
    test "lists records without leaking values" do
      call(:put, "/secrets/s1", body: %{"value" => "one"})
      call(:put, "/secrets/s2", body: %{"value" => "two"})

      conn = call(:get, "/secrets")
      assert conn.status == 200
      %{"value" => items} = Jason.decode!(conn.resp_body)

      names =
        Enum.map(items, & &1["id"])
        |> Enum.map(fn id -> id |> String.split("/") |> Enum.at(4) end)

      assert MapSet.new(names) |> MapSet.equal?(MapSet.new(["s1", "s2"]))
      refute Enum.any?(items, &Map.has_key?(&1, "value"))
    end
  end

  describe "DELETE /secrets/:name" do
    test "existing -> 200 then GET is 404 SecretNotFound" do
      call(:put, "/secrets/gone", body: %{"value" => "x"})

      conn = call(:delete, "/secrets/gone")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] =~ "/secrets/gone/"

      conn = call(:get, "/secrets/gone")
      assert conn.status == 404
      assert %{"error" => %{"code" => "SecretNotFound"}} = Jason.decode!(conn.resp_body)
    end

    test "missing -> typed 404 SecretNotFound, nothing stored" do
      conn = call(:delete, "/secrets/never-existed")
      assert conn.status == 404
      assert %{"error" => %{"code" => "SecretNotFound"}} = Jason.decode!(conn.resp_body)
      assert :ets.info(:smalt_vault_secrets, :size) in [0, nil]
    end
  end

  describe "sub-verb refusals" do
    test "GET /secrets/:name/versions -> typed 501 NotImplemented" do
      conn = call(:get, "/secrets/s1/versions")
      assert conn.status == 501
      assert %{"error" => %{"code" => "NotImplemented"}} = Jason.decode!(conn.resp_body)
    end

    test "POST backup/restore -> typed 501" do
      for {m, p} <- [{:post, "/secrets/s1/backup"}, {:post, "/secrets/s1/restore"}] do
        conn = call(m, p)
        assert conn.status == 501
        assert %{"error" => %{"code" => "NotImplemented"}} = Jason.decode!(conn.resp_body)
      end
    end
  end

  test "tokenless request -> mode-blind 401 challenge (KD-15 pattern)" do
    conn =
      conn(:put, "/secrets/chal", Jason.encode!(%{"value" => "v"}))
      |> put_req_header("content-type", "application/json")
      |> EgressRouter.call(@opts)

    assert conn.status == 401
    assert jwt_headers(conn) != []
  end
end

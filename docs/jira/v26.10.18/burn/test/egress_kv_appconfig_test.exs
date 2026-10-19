defmodule EgressKvAppconfigTest do
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
      |> put_req_header("authorization", "Bearer egress-kv-harness")
      |> then(fn c ->
        Enum.reduce(opts[:headers] || [], c, fn {k, v}, c -> put_req_header(c, k, v) end)
      end)

    EgressRouter.call(conn, @opts)
  end

  describe "PUT /kv/:key" do
    test "create is 201 with etag + roundtrips via GET" do
      conn =
        call(:put, "/kv/myapp:feature",
          body: %{"value" => "{\"enabled\":true}", "contentType" => "application/json"}
        )

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["key"] == "myapp:feature"
      assert body["label"] == ""
      assert body["value"] == "{\"enabled\":true}"
      assert body["contentType"] == "application/json"
      assert body["etag"] =~ ~r/^"[0-9A-F]{64}"$/
      assert is_integer(body["last_modified"])

      get_conn = call(:get, "/kv/myapp:feature")
      assert get_conn.status == 200
      assert Jason.decode!(get_conn.resp_body)["value"] == "{\"enabled\":true}"
      assert get_resp_header(get_conn, "etag") == [body["etag"]]
    end

    test "unconditional overwrite of existing kv is 409" do
      call(:put, "/kv/k1", body: %{"value" => "v1"})
      conn = call(:put, "/kv/k1", body: %{"value" => "v2"})

      assert conn.status == 409
      %{"error" => %{"code" => "WriteConflict"}} = Jason.decode!(conn.resp_body)
    end

    test "If-Match CAS update is 200; stale etag is 412" do
      {:ok, etag} = put_kv("k1", "v1")

      good = call(:put, "/kv/k1", body: %{"value" => "v2"}, headers: [{"if-match", etag}])
      assert good.status == 200
      {:ok, etag2} = put_kv("k1", "v3")

      stale = call(:put, "/kv/k1", body: %{"value" => "v4"}, headers: [{"if-match", etag}])
      assert stale.status == 412

      assert Jason.decode!(call(:get, "/kv/k1").resp_body)["value"] == "v3"
      assert etag != etag2
    end

    test "create-only If-None-Match: * refuses duplicates with 412" do
      {:ok, _} = put_kv("dup", "v1")

      conn =
        call(:put, "/kv/dup", body: %{"value" => "v2"}, headers: [{"if-none-match", "*"}])

      assert conn.status == 412

      fresh =
        call(:put, "/kv/fresh", body: %{"value" => "v"}, headers: [{"if-none-match", "*"}])

      assert fresh.status == 201
    end

    test "If-Match on absent kv is 412" do
      conn =
        call(:put, "/kv/absent", body: %{"value" => "v"}, headers: [{"if-match", "*"}])

      assert conn.status == 412
    end
  end

  describe "GET /kv (list)" do
    test "lists all kvs; filters by key prefix and label" do
      {:ok, _} = put_kv("app:a", "1")
      {:ok, _} = put_kv("app:b", "2")
      {:ok, _} = put_kv("other:c", "3")
      put_kv("app:a", "dev-value", label: "dev")

      all = Jason.decode!(call(:get, "/kv").resp_body)["items"]
      assert length(all) == 4

      prefix = Jason.decode!(call(:get, "/kv?key=app:").resp_body)["items"]
      assert length(prefix) == 3
      assert Enum.all?(prefix, &String.starts_with?(&1["key"], "app:"))

      labeled = Jason.decode!(call(:get, "/kv?label=dev").resp_body)["items"]
      assert length(labeled) == 1
      assert hd(labeled)["label"] == "dev"

      both =
        Jason.decode!(call(:get, "/kv?key=app:&label=dev").resp_body)["items"]

      assert length(both) == 1
      assert hd(both)["value"] == "dev-value"
    end

    test "empty store is 200 with empty items and sync-token" do
      conn = call(:get, "/kv")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["items"] == []
      assert get_resp_header(conn, "sync-token") == ["smalt-0"]
    end
  end

  describe "GET /kv/:key" do
    test "label dimension isolates values" do
      {:ok, _} = put_kv("cfg", "default-value")
      {:ok, _} = put_kv("cfg", "prod-value", label: "prod")

      assert Jason.decode!(call(:get, "/kv/cfg").resp_body)["label"] == ""
      assert Jason.decode!(call(:get, "/kv/cfg").resp_body)["value"] == "default-value"
      assert Jason.decode!(call(:get, "/kv/cfg?label=prod").resp_body)["value"] == "prod-value"
      assert call(:get, "/kv/cfg?label=staging").status == 404
    end

    test "If-None-Match match is 304 with etag; mismatch is 200" do
      {:ok, etag} = put_kv("s", "v")

      not_mod = call(:get, "/kv/s", headers: [{"if-none-match", etag}])
      assert not_mod.status == 304
      assert get_resp_header(not_mod, "etag") == [etag]

      assert call(:get, "/kv/s", headers: [{"if-none-match", "\"dead\""}]).status == 200
    end

    test "absent kv is typed 404" do
      conn = call(:get, "/kv/nope")
      assert conn.status == 404
      %{"error" => %{"code" => "KvNotFound"}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "DELETE /kv/:key" do
    test "delete requires If-Match: missing header is 409; * is 204; repeat is idempotent 404" do
      {:ok, _} = put_kv("d1", "v")

      # Real App Configuration: delete without If-Match is a 409, not a delete.
      conn = call(:delete, "/kv/d1")
      assert conn.status == 409
      assert %{"code" => "MissingIfMatch", "message" => msg} = Jason.decode!(conn.resp_body)
      assert msg =~ "If-Match header must be specified"

      assert call(:delete, "/kv/d1", headers: [{"if-match", "*"}]).status == 204
      assert call(:get, "/kv/d1").status == 404
      assert call(:delete, "/kv/d1", headers: [{"if-match", "*"}]).status == 404
    end

    test "stale If-Match is 412; matching If-Match deletes" do
      {:ok, etag} = put_kv("d2", "v")

      assert call(:delete, "/kv/d2", headers: [{"if-match", "\"dead\""}]).status == 412
      assert call(:get, "/kv/d2").status == 200
      assert call(:delete, "/kv/d2", headers: [{"if-match", etag}]).status == 204
    end
  end

  describe "feature-flag content type" do
    test "rides as an opaque contentType passthrough" do
      flag_value =
        Jason.encode!(%{
          "id" => "Beta",
          "enabled" => true,
          "conditions" => %{"client_filters" => []}
        })

      conn =
        call(:put, "/kv/Beta",
          body: %{
            "value" => flag_value,
            "contentType" => "application/vnd.microsoft.appconfig.kv+json;ctype-feature"
          }
        )

      assert conn.status == 201

      got = Jason.decode!(call(:get, "/kv/Beta").resp_body)

      assert got["contentType"] ==
               "application/vnd.microsoft.appconfig.kv+json;ctype-feature"

      assert got["value"] == flag_value
    end
  end

  describe "tokenless challenge posture" do
    test "tokenless GET /kv is 401 challenge, same as /secrets" do
      plain = conn(:get, "/kv")
      refute plain.req_headers |> Enum.any?(fn {k, _} -> k == "authorization" end)

      challenged = EgressRouter.call(plain, @opts)

      assert challenged.status == 401
      assert get_resp_header(challenged, "www-authenticate") != []
    end
  end

  defp put_kv(key, value, opts \\ []) do
    label = opts[:label] || ""
    path = if label == "", do: "/kv/#{key}", else: "/kv/#{key}?label=#{label}"

    # Unconditional overwrite of an existing kv is a 409 by contract, so the
    # helper CASes through the current etag (absent kv -> plain create).
    case call(:get, path) do
      get = %Plug.Conn{status: 200} ->
        etag = Jason.decode!(get.resp_body)["etag"]

        conn =
          call(:put, path,
            body: %{"value" => value},
            headers: [{"if-match", etag}]
          )

        assert conn.status == 200
        {:ok, Jason.decode!(conn.resp_body)["etag"]}

      _ ->
        conn = call(:put, path, body: %{"value" => value})
        assert conn.status == 201
        {:ok, Jason.decode!(conn.resp_body)["etag"]}
    end
  end
end

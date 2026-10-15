defmodule EgressWiringTest do
  @moduledoc """
  Route-wiring tests for the newly mounted data-plane surfaces on the 8443
  `Smalt.EgressRouter`: `Smalt.DataPlane.KeyVaultActions` crypto actions
  (`POST /keys/:name/{encrypt,decrypt,sign,verify,wrapKey,unwrapKey}`,
  `GET /keys`, `GET /keys/:name/versions`) and `Smalt.DataPlane.BlobService`
  (`GET /{account}?comp=list`, container metadata
  `PUT/GET /{account}/{container}?comp=metadata`, container properties
  `GET ?restype=container`).

  Plug.Test pattern from test/route_negative_test.exs — real router dispatch,
  real Store, no mocks.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.EgressRouter
  alias Smalt.Store

  @opts EgressRouter.init([])

  setup do
    ensure_store()
    Store.clear()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Key Vault crypto actions
  # ---------------------------------------------------------------------------

  test "encrypt -> decrypt RSA-OAEP-256 round trip through the real router" do
    :ok = create_key("rsa-key")

    plain = :crypto.strong_rand_bytes(48)
    b64url = Base.url_encode64(plain, padding: false)

    conn = call(:post, "/keys/rsa-key/encrypt", body: %{"alg" => "RSA-OAEP-256", "value" => b64url})

    assert conn.status == 200
    ct = Jason.decode!(conn.resp_body)
    assert is_binary(ct["value"]) and ct["value"] != b64url
    assert ct["kid"] =~ "/keys/rsa-key"

    conn = call(:post, "/keys/rsa-key/decrypt", body: %{"alg" => "RSA-OAEP-256", "value" => ct["value"]})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["value"] == b64url
  end

  test "A256GCM (oct key) encrypt -> decrypt round trip carries iv and tag" do
    Store.put(:smalt_vault_keys, "oct-key", %{
      "kid" => "https://smalt/keys/oct-key",
      "key" => %{"kid" => "https://smalt/keys/oct-key", "kty" => "oct"}
    })

    plain = :crypto.strong_rand_bytes(32)
    b64url = Base.url_encode64(plain, padding: false)

    conn = call(:post, "/keys/oct-key/encrypt", body: %{"alg" => "A256GCM", "value" => b64url})

    assert conn.status == 200
    ct = Jason.decode!(conn.resp_body)
    assert is_binary(ct["iv"]) and is_binary(ct["tag"])

    conn =
      call(:post, "/keys/oct-key/decrypt",
        body: %{
        "alg" => "A256GCM",
        "value" => ct["value"],
        "iv" => ct["iv"],
        "tag" => ct["tag"]
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["value"] == b64url
    assert body["kid"] =~ "oct-key"
  end

  test "sign -> verify round trip (RS256), bad signature is 200 valid=false" do
    :ok = create_key("sig-key")

    b64url = Base.url_encode64("payload to sign", padding: false)

    conn = call(:post, "/keys/sig-key/sign", body: %{"alg" => "RS256", "value" => b64url})

    assert conn.status == 200
    sig = Jason.decode!(conn.resp_body)
    assert is_binary(sig["value"])

    conn =
      call(:post, "/keys/sig-key/verify",
        body: %{"alg" => "RS256", "value" => b64url, "signature" => sig["value"]}
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["valid"] == true

    conn =
      call(:post, "/keys/sig-key/verify",
        body: %{"alg" => "RS256", "value" => b64url, "signature" => Base.encode64("forged")}
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["valid"] == false
  end

  test "wrapKey -> unwrapKey round trip" do
    :ok = create_key("wrap-key")

    cek = :crypto.strong_rand_bytes(32)

    conn = call(:post, "/keys/wrap-key/wrapKey", body: %{"alg" => "RSA-OAEP-256", "value" => Base.url_encode64(cek, padding: false)})

    assert conn.status == 200
    wrapped = Jason.decode!(conn.resp_body)

    conn =
      call(:post, "/keys/wrap-key/unwrapKey", body: %{"alg" => "RSA-OAEP-256", "value" => wrapped["value"]})

    assert conn.status == 200
    assert Base.url_decode64!(Jason.decode!(conn.resp_body)["value"], padding: false) == cek
  end

  test "action suffix is case-insensitive and unknown action is 404 RouteNotFound" do
    :ok = create_key("case-key")

    conn = call(:post, "/keys/case-key/ENCRYPT", body: %{"alg" => "RSA-OAEP-256", "value" => Base.encode64("x")})
    assert conn.status == 200

    conn = call(:post, "/keys/case-key/notAnAction", body: %{"v" => 1})
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotFound"
  end

  test "GET /keys lists keys and GET /keys/:name/versions reports the version" do
    :ok = create_key("list-key")

    conn = call(:get, "/keys")
    assert conn.status == 200
    keys = Jason.decode!(conn.resp_body)["value"]
    assert Enum.any?(keys, &(&1["kid"] =~ "list-key"))

    conn = call(:get, "/keys/list-key/versions")
    assert conn.status == 200
    versions = Jason.decode!(conn.resp_body)["value"]
    assert [%{"key" => %{"kid" => kid}}] = versions
    assert kid =~ "list-key"

    conn = call(:get, "/keys/missing-key/versions")
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "KeyNotFound"
  end

  test "crypto action on unknown key -> 404 KeyNotFound" do
    conn = call(:post, "/keys/absent-key/encrypt", body: %{"alg" => "RSA-OAEP-256", "value" => Base.encode64("x")})
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "KeyNotFound"
  end

  test "existing /keys/:name/create and /keys/:name routes stay green" do
    :ok = create_key("legacy-key")

    conn = call(:get, "/keys/legacy-key")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["key"]["kid"] =~ "legacy-key"
  end

  # ---------------------------------------------------------------------------
  # BlobService
  # ---------------------------------------------------------------------------

  test "GET /{account}?comp=list lists containers as XML with pagination" do
    create_container("acct", "alpha")
    create_container("acct", "beta")
    create_container("acct", "gamma")

    conn = call(:get, "/acct?comp=list&maxresults=2", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> List.first() =~ "application/xml"

    xml = conn.resp_body
    assert xml =~ "<Name>alpha</Name>"
    assert xml =~ "<Name>beta</Name>"
    refute xml =~ "gamma"
    assert xml =~ "<NextMarker>beta</NextMarker>"

    conn = call(:get, "/acct?comp=list&marker=beta", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
    xml = conn.resp_body
    assert xml =~ "<Name>gamma</Name>"
    assert xml =~ "<NextMarker />"
  end

  test "metadata round trip: PUT ?comp=metadata then GET ?comp=metadata" do
    create_container("metaacct", "c01")

    conn =
      call(:put, "/metaacct/c01?comp=metadata",
        headers: [{"x-ms-version", "2021-12-02"}, {"x-ms-meta-owner", "smalt"}, {"x-ms-meta-tier", "hot"}]
      )

    assert conn.status == 200
    assert conn |> get_resp_header("etag") != []

    conn =
      call(:get, "/metaacct/c01?comp=metadata", headers: [{"x-ms-version", "2021-12-02"}])

    assert conn.status == 200
    assert "smalt" in get_resp_header(conn, "x-ms-meta-owner")
    assert "hot" in get_resp_header(conn, "x-ms-meta-tier")

    # metadata on a missing container -> 404 ContainerNotFound
    conn = call(:put, "/metaacct/nope?comp=metadata", headers: [{"x-ms-version", "2021-12-02"}, {"x-ms-meta-a", "b"}])
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ContainerNotFound"
  end

  test "container properties: GET ?restype=container returns etag and meta headers" do
    create_container("propacct", "c01")

    call(:put, "/propacct/c01?comp=metadata", headers: [{"x-ms-version", "2021-12-02"}, {"x-ms-meta-env", "prod"}])

    conn = call(:get, "/propacct/c01?restype=container", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
    assert conn |> get_resp_header("etag") != []
    assert "prod" in get_resp_header(conn, "x-ms-meta-env")
    assert conn |> get_resp_header("x-ms-has-legal-hold") == ["false"]

    conn = call(:get, "/propacct/missing?restype=container", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ContainerNotFound"
  end

  test "blob list and create routes stay green alongside the new branches" do
    create_container("greenacct", "c01")

    conn = call(:get, "/greenacct/c01", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
    assert conn.resp_body =~ "Blobs"

    conn = call(:get, "/greenacct", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotFound"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_store do
    if GenServer.whereis(Smalt.Store) == nil do
      {:ok, _} = Smalt.Store.start_link([])
    end

    :ok
  end

  defp call(method, path, opts \\ []) do
    body = opts[:body] || %{}
    raw = if body == %{}, do: "", else: Jason.encode!(body)

    conn = conn(method, path, raw)

    conn =
      if raw != "",
        do: put_req_header(conn, "content-type", "application/json"),
        else: conn

    conn =
      Enum.reduce(opts[:headers] || [], conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    EgressRouter.call(conn, @opts)
  end

  defp create_key(name) do
    conn(:post, "/keys/#{name}/create", Jason.encode!(%{"kty" => "RSA-HSM"}))
    |> put_req_header("content-type", "application/json")
    |> EgressRouter.call(@opts)
    |> then(fn c ->
      assert c.status == 200
      :ok
    end)
  end

  defp create_container(account, container) do
    conn(:put, "/#{account}/#{container}")
    |> put_req_header("x-ms-version", "2021-12-02")
    |> EgressRouter.call(@opts)
    |> then(fn c ->
      assert c.status in [200, 201]
      :ok
    end)
  end
end

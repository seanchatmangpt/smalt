defmodule Smalt.Test.Internal.KdConfCourtTest do
  @moduledoc """
  KD-CONF lane court — KD-147..152 wire conformance faces.

  Chicago-style: real HTTP through the self-booted egress router (ephemeral
  ports, no external substrate), asserting final wire state. Each test names
  the KD row it fences; a regression of any row exits 1.
  """

  use ExUnit.Case, async: false

  @tenant "00000000-0000-0000-0000-000000000000"
  @guid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  setup_all do
    {:ok, _} = Application.ensure_all_started(:smalt)

    arm = Application.fetch_env!(:smalt, :arm_port)
    url = "http://127.0.0.1:" <> Integer.to_string(arm) <> "/" <> @tenant <> "/oauth2/v2.0/token"

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:post,
        {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded",
         "grant_type=client_credentials&client_id=kdconf&client_secret=kdconf&scope=s"},
        [], []
      )

    %{"access_token" => token} = Jason.decode!(body)
    {:ok, token: token}
  end

  defp call(method, path, token, headers \\ [], body \\ "") do
    conn =
      method
      |> Plug.Test.conn(path, body)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    Smalt.EgressRouter.call(conn, [])
  end

  defp hdr(conn, name) do
    case Enum.find(conn.resp_headers, fn {k, _} -> k == name end) do
      {_, v} -> v
      nil -> flunk("header #{name} missing")
    end
  end

  # KD-149: first-create PUT answers 201, re-set (update) answers 200.
  test "KD-149: KV secret first-create 201, update 200", %{token: token} do
    name = "kdconf149-" <> Integer.to_string(System.unique_integer([:positive]))

    create =
      call(:put, "/secrets/#{name}?api-version=7.4", token,
        [{"content-type", "application/json"}],
        Jason.encode!(%{"value" => "v1"})
      )

    assert create.status == 201, "first create must be 201 per KV secrets 7.4"

    update =
      call(:put, "/secrets/#{name}?api-version=7.4", token,
        [{"content-type", "application/json"}],
        Jason.encode!(%{"value" => "v2"})
      )

    assert update.status == 200, "re-set must be 200"
  end

  # KD-150: secret id = https://{host}.vault.azure.net/secrets/{name}/{GUID}.
  test "KD-150: KV secret id vault-host + GUID version", %{token: token} do
    name = "kdconf150-" <> Integer.to_string(System.unique_integer([:positive]))

    conn =
      call(:put, "/secrets/#{name}?api-version=7.4", token,
        [{"content-type", "application/json"}],
        Jason.encode!(%{"value" => "v"})
      )

    assert conn.status in [200, 201]
    %{"id" => id} = Jason.decode!(conn.resp_body)

    assert String.starts_with?(id, "https://") and String.contains?(id, ".vault.azure.net/secrets/"),
           "id must be vault-host shape, got: " <> id

    assert id |> String.split("/") |> List.last() =~ @guid,
           "version segment must be GUID"
  end

  # KD-151: future api-version 400 InvalidApiVersion; 7.4 admitted.
  test "KD-151: future api-version refused 400, 7.4 admitted", %{token: token} do
    name = "kdconf151-" <> Integer.to_string(System.unique_integer([:positive]))

    call(:put, "/secrets/#{name}?api-version=7.4", token,
      [{"content-type", "application/json"}],
      Jason.encode!(%{"value" => "v"})
    )

    bad = call(:get, "/secrets/#{name}?api-version=2099-01-01", token)
    assert bad.status == 400, "future api-version must be refused"

    %{"error" => %{"code" => code}} = Jason.decode!(bad.resp_body)
    assert code == "InvalidApiVersion"

    assert call(:get, "/secrets/#{name}?api-version=7.4", token).status == 200
  end

  # KD-152: queue-plane x-ms-request-id dashed-36 RFC 4122 GUID.
  test "KD-152: queue x-ms-request-id dashed GUID", %{token: token} do
    acct = "kdconfacct"
    queue = "kdconfq" <> Integer.to_string(System.unique_integer([:positive]))

    create = call(:put, "/#{acct}/#{queue}?restype=queue", token)
    assert create.status == 201
    assert hdr(create, "x-ms-request-id") =~ @guid

    put =
      call(:post, "/#{acct}/#{queue}/messages", token,
        [{"content-type", "application/xml"}],
        "<QueueMessage><MessageText>aGk=</MessageText></QueueMessage>"
      )

    assert put.status == 201
    assert hdr(put, "x-ms-request-id") =~ @guid
  end

  # KD-147/148: cosmos doc body carries spec system props only; _etag quoted GUID;
  # CAS round-trip on the GUID etag.
  test "KD-147/148: cosmos doc system props + GUID etag + CAS", %{token: token} do
    db = "kdconfdb"
    coll = "kdconfcoll"

    call(:post, "/dbs/#{db}", token, [{"content-type", "application/json"}],
      Jason.encode!(%{"id" => db})
    )

    call(:post, "/dbs/#{db}/colls", token, [{"content-type", "application/json"}],
      Jason.encode!(%{"id" => coll})
    )

    conn =
      call(:post, "/dbs/#{db}/colls/#{coll}/docs", token, [{"content-type", "application/json"}],
        Jason.encode!(%{"id" => "d1", "payload" => 42})
      )

    assert conn.status == 201
    doc = Jason.decode!(conn.resp_body)

    refute Map.has_key?(doc, "_gen"), "_gen must never cross the wire"
    refute Map.has_key?(doc, "_v"), "_v must never cross the wire"
    assert Map.has_key?(doc, "_etag")
    assert Map.has_key?(doc, "_ts")
    assert Map.has_key?(doc, "_rid")

    assert doc["_etag"] =~ ~r/^"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$/,
           "_etag must be quoted GUID, got: #{doc["_etag"]}"

    assert call(:get, "/dbs/#{db}/colls/#{coll}/docs/d1", token, [
             {"if-match", doc["_etag"]}
           ]).status == 200, "echoed GUID etag must pass CAS"

    stale =
      call(:get, "/dbs/#{db}/colls/#{coll}/docs/d1", token, [
        {"if-match", "\"00000000-0000-0000-0000-000000000000\""}
      ])

    assert stale.status == 412, "mismatched etag must 412"
  end
end

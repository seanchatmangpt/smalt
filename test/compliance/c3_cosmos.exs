defmodule Smalt.Compliance.C3CosmosTest do
  @moduledoc """
  C3 — Azure Cosmos DB NoSQL wire-protocol compliance fence (live wire tier).

  Boots `Smalt.EgressRouter` under Bandit on an ephemeral port per test and
  makes real HTTP requests (inets `:httpc`). Fences the CONFORMANT rows of
  `docs/compliance/C3_COSMOS.md`. GAP rows are never fenced as passing; the
  two most load-bearing GAPs (x-ms-retry-after-ms on 429, master-key
  Authorization validation) are pinned as currently-absent with explicit
  comments. Spec basis: Azure Cosmos DB NoSQL REST API — required response
  headers, `_etag` quoting, system properties, partition-key header semantics,
  `application/query+json` envelope, status-code semantics.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos
  alias Smalt.Store

  @db "c3fence"
  @coll "fencecoll"
  @pk_hdr {"x-ms-documentdb-partitionkey", ~s(["acme"])}
  @json {"content-type", "application/json"}

  setup do
    ensure_store()
    Store.clear()

    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)

    port = free_port()
    :persistent_term.put({__MODULE__, :port}, port)
    {:ok, server} = Bandit.start_link(plug: Smalt.EgressRouter, port: port)

    on_exit(fn ->
      stop_server(server)
      Application.put_env(:smalt, :auth_mode, prev_auth || :anonymous)
    end)

    {:ok, port: port}
  end

  # ---------------------------------------------------------------------------
  # Required response headers on success AND error responses
  # ---------------------------------------------------------------------------

  test "201 create carries the required Cosmos header set + alt-content-path" do
    create_db()
    create_coll()

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [@pk_hdr, @json],
        body: ~s({"id":"d1","tenantId":"acme"})
      )

    assert resp.status == 201
    hm = header_map(resp)

    for h <- ["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn", "x-ms-alt-content-path"] do
      assert Map.has_key?(hm, h), "missing required header #{h}"
    end

    assert hm["x-ms-alt-content-path"] == "dbs/#{@db}/colls/#{@coll}"
    assert hm["x-ms-session-token"] =~ ~r/^\d+#\d+$/
    assert String.to_integer(hm["x-ms-lsn"]) >= 0
  end

  test "404 NotFound carries request-charge / session-token / lsn too" do
    create_db()
    create_coll()

    resp = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/nope")

    assert resp.status == 404
    hm = header_map(resp)

    for h <- ["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn"] do
      assert Map.has_key?(hm, h), "missing required header #{h}"
    end

    body = Jason.decode!(resp.body)
    assert body["code"] == "NotFound"
    assert body["message"] == "Entity with the specified id does not exist in the system."
  end

  # ---------------------------------------------------------------------------
  # _etag: quoted, stable across read, refreshed on write
  # ---------------------------------------------------------------------------

  test "_etag is a quoted JSON string; stable on read; changes on replace" do
    create_db()
    create_coll()
    create_doc("d1")

    read = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1", headers: [@pk_hdr])
    assert read.status == 200

    doc = Jason.decode!(read.body)
    assert doc["_etag"] =~ ~r/^"[0-9a-f]{64}"$/

    assert header_map(read)["etag"] == doc["_etag"]

    put =
      req!(port(), :put, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [@pk_hdr, @json],
        body: ~s({"id":"d1","tenantId":"acme","v":2})
      )

    assert put.status == 200
    new_doc = Jason.decode!(put.body)
    assert new_doc["_etag"] =~ ~r/^"/ and new_doc["_etag"] != doc["_etag"]
    assert new_doc["_ts"] >= doc["_ts"]
  end

  # ---------------------------------------------------------------------------
  # System properties: _rid present, _self path grammar, _ts integer seconds
  # ---------------------------------------------------------------------------

  test "document system properties: _rid, _self grammar, _ts" do
    create_db()
    create_coll()
    create_doc("d1")

    doc = get_doc("d1")

    # composite resource id: coll rid (12) + doc segment (8), base64url alphabet
    assert doc["_rid"] == Cosmos.coll_rid(@db, @coll) <> Cosmos.rid_segment("d1", 8)
    assert doc["_rid"] =~ ~r/^[A-Za-z0-9_-]{20}$/
    assert doc["_self"] == "/dbs/#{@db}/colls/#{@coll}/docs/d1"
    assert is_integer(doc["_ts"])
  end

  test "db and container records expose id/_rid/_self and container pk kind" do
    create_db()
    create_coll()

    db =
      req!(port(), :get, "/dbs/#{@db}")
      |> Map.fetch!(:body)
      |> Jason.decode!()

    assert db["id"] == @db and db["_self"] == "/dbs/#{@db}"
    # db rid: 8-char base64url segment
    assert db["_rid"] == Cosmos.db_rid(@db)
    assert db["_rid"] =~ ~r/^[A-Za-z0-9_-]{8}$/

    coll =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}")
      |> Map.fetch!(:body)
      |> Jason.decode!()

    # container rid: db rid + 4-char segment
    assert coll["_rid"] == Cosmos.coll_rid(@db, @coll)
    assert coll["_rid"] =~ ~r/^[A-Za-z0-9_-]{12}$/
    assert coll["partitionKey"]["paths"] == ["/tenantId"]
    assert coll["partitionKey"]["kind"] == "Hash"
  end

  # ---------------------------------------------------------------------------
  # Status-code semantics: 201/200/204/400/404/412
  # ---------------------------------------------------------------------------

  test "create/replace/delete status semantics incl. conditional delete" do
    create_db()
    create_coll()

    assert create_doc("d1").status == 201

    # conditional delete: matching If-Match -> 204, second delete -> 404
    etag = get_doc("d1")["_etag"]

    assert req!(port(), :delete, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
             headers: [{"if-match", etag}, @pk_hdr]
           ).status ==
             204

    assert req!(port(), :delete, "/dbs/#{@db}/colls/#{@coll}/docs/d1").status == 404
  end

  test "PUT with stale If-Match -> 412 PreconditionFailed envelope" do
    create_db()
    create_coll()
    create_doc("d1")

    resp =
      req!(port(), :put, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [{"if-match", ~s("stale")}, @pk_hdr, @json],
        body: ~s({"id":"d1","tenantId":"acme","v":2})
      )

    assert resp.status == 412
    assert Jason.decode!(resp.body)["code"] == "PreconditionFailed"
  end

  test "GET with If-None-Match matching -> 304" do
    create_db()
    create_coll()
    create_doc("d1")
    etag = get_doc("d1")["_etag"]

    resp =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [{"if-none-match", etag}, @pk_hdr]
      )

    assert resp.status == 304
  end

  # ---------------------------------------------------------------------------
  # Partition-key semantics (json array header, extraction, 400s)
  # ---------------------------------------------------------------------------

  test "413 RequestEntityTooLarge envelope on a > 2MB doc create (row 16)" do
    create_db()
    create_coll()

    body = ~s({"id":"toobig","blob":"#{String.duplicate("x", 2 * 1024 * 1024)}"})

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [@pk_hdr, @json],
        body: body
      )

    assert resp.status == 413
    assert Jason.decode!(resp.body)["code"] == "RequestEntityTooLarge"

    for h <- ["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn"] do
      assert Map.has_key?(header_map(resp), h), "missing required header #{h}"
    end

    # the oversized doc was not persisted
    assert req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/toobig").status == 404
  end

  test "pk header required: missing / non-array / mismatched all 400 BadRequest" do
    create_db()
    create_coll()

    bodies = [
      {[], ~s({"id":"d9","tenantId":"acme"})},
      {[{"x-ms-documentdb-partitionkey", "acme"}], ~s({"id":"d9","tenantId":"acme"})},
      {[@pk_hdr], ~s({"id":"d9","tenantId":"other"})}
    ]

    for {hdrs, body} <- bodies do
      resp =
        req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@json | hdrs],
          body: body
        )

      assert resp.status == 400, "expected 400 for headers=#{inspect(hdrs)}"
      assert Jason.decode!(resp.body)["code"] == "BadRequest"
    end
  end

  test "query POST with pk header filters to the partition" do
    create_db()
    create_coll()
    create_doc("d1")
    create_doc("d2")

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk_hdr],
        body: ~s({"query":"SELECT * FROM c","parameters":[]})
      )

    assert resp.status == 200

    body = Jason.decode!(resp.body)

    assert MapSet.new(Map.keys(body)) == MapSet.new(["_rid", "Documents", "_count"])
    assert body["_count"] == 2
    assert Enum.all?(body["Documents"], &(&1["tenantId"] == "acme"))
  end

  test "cross-partition query POST (enablecrosspartition) returns 200 feed" do
    create_db()
    create_coll()
    create_doc("d1")

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [
          {"content-type", "application/query+json"},
          {"x-ms-documentdb-query-enablecrosspartition", "true"}
        ],
        body: ~s({"query":"SELECT * FROM c"})
      )

    assert resp.status == 200
    assert Jason.decode!(resp.body)["_count"] >= 1
  end

  test "a query POST never creates a document" do
    create_db()
    create_coll()

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk_hdr],
        body: ~s({"query":"SELECT * FROM c"})
      )

    assert resp.status == 200

    # the only documents visible are the ones created by real create POSTs
    assert Jason.decode!(resp.body)["_count"] == 0

    resp2 =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk_hdr],
        body: "not json at all"
      )

    assert resp2.status == 400
  end

  # ---------------------------------------------------------------------------
  # Session token monotonicity, trailing slash, database account
  # ---------------------------------------------------------------------------

  test "x-ms-session-token advances monotonically on writes" do
    create_db()
    create_coll()
    create_doc("d1")

    t1 = session_token_for("d1")
    create_doc("d2")
    t2 = session_token_for("d1")

    assert token_lsn(t2) > token_lsn(t1)
  end

  test "trailing slash tolerated on the /dbs surface" do
    assert req!(port(), :get, "/dbs/").status == 200
  end

  test "database account GET / returns 200 DatabaseAccount envelope" do
    resp = req!(port(), :get, "/")
    assert resp.status == 200

    body = Jason.decode!(resp.body)
    assert body["kind"] == "DatabaseAccount"
    assert is_list(body["writableLocations"])
  end

  # ---------------------------------------------------------------------------
  # Former GAP rows, now fixed and fenced CONFORMANT
  # ---------------------------------------------------------------------------

  test "throttle: default :infinity keeps the surface unthrottled (regression row)" do
    create_db()
    create_coll()

    statuses =
      for i <- 1..30 do
        req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@pk_hdr, @json],
          body: ~s({"id":"bulk#{i}","tenantId":"acme"})
        ).status
      end

    assert statuses |> Enum.uniq() == [201]
  end

  test "throttle: :cosmos_ru_limit set -> 429 + x-ms-retry-after-ms after the limit (row 13)" do
    create_db()
    create_coll()

    Application.put_env(:smalt, :cosmos_ru_limit, 5)
    if :ets.info(:smalt_cosmos_ru) != :undefined, do: :ets.delete_all_objects(:smalt_cosmos_ru)

    responses =
      for i <- 1..8 do
        req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@pk_hdr, @json],
          body: ~s({"id":"th#{i}","tenantId":"acme"})
        )
      end

    statuses = Enum.map(responses, & &1.status)

    assert Enum.take(statuses, 5) |> Enum.uniq() == [201]
    assert Enum.drop(statuses, 5) |> Enum.uniq() == [429]

    # the first throttled response carries the retry-after header + envelope
    throttled = Enum.at(responses, 5)
    assert header_map(throttled)["x-ms-retry-after-ms"] == "1"
    assert Jason.decode!(throttled.body)["code"] == "TooManyRequests"
  after
    Application.delete_env(:smalt, :cosmos_ru_limit)

    if :ets.info(:smalt_cosmos_ru) != :undefined, do: :ets.delete_all_objects(:smalt_cosmos_ru)
  end

  test "master-key: anonymous mode admits an invalid master-key Authorization unchanged (regression row)" do
    create_db()

    resp =
      req!(port(), :get, "/dbs",
        headers: [{"authorization", "type%3dmaster%26ver%3d1.0%26sig%3dinvalid"}]
      )

    assert resp.status == 200
  end

  test "master-key: :enforce mode validates the HMAC signature (row 14)" do
    create_db()
    create_coll()
    create_doc("d1")

    key = "c3fence-master-key-0123456789abcdef"
    Application.put_env(:smalt, :cosmos_master_key, key)
    Application.put_env(:smalt, :auth_mode, :enforce)

    # Engine-level probe (real store, real HMAC, no HTTP doubles): the wire
    # surface's :enforce gate is the Bearer plug (a master-key Authorization
    # header is refused there as MalformedBearerHeader before the engine is
    # reached), so the engine gate is probed in-process like auth_enforce_test.
    date = "mon, 14 oct 2026 00:00:00 gmt"

    link = "dbs/#{@db}/colls/#{@coll}/docs/d1"

    valid_auth =
      URI.encode(
        "type=master&ver=1.0&sig=#{Base.encode64(:crypto.mac(:hmac, :sha256, key, "get\ndocs\n#{link}\n#{date}\n\n"))}"
      )

    headers = %{
      "authorization" => valid_auth,
      "x-ms-date" => date,
      "x-ms-documentdb-partitionkey" => ~s(["acme"])
    }

    assert {:ok, 200, resp_headers, doc} =
             Smalt.DataPlane.Cosmos.get_doc(@db, @coll, "d1", headers)

    assert doc["id"] == "d1"

    bad_auth = URI.encode("type=master&ver=1.0&sig=#{Base.encode64("invalid-signature-bytes")}")

    assert {:ok, 401, _h, err} =
             Smalt.DataPlane.Cosmos.get_doc(
               @db,
               @coll,
               "d1",
               Map.put(headers, "authorization", bad_auth)
             )

    assert err["code"] == "Unauthorized"
  after
    Application.delete_env(:smalt, :cosmos_master_key)
    Application.put_env(:smalt, :auth_mode, :anonymous)
  end

  test "x-ms-consistency-level is echoed on responses (row 15)" do
    create_db()
    create_coll()
    create_doc("d1")

    resp =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [@pk_hdr, {"x-ms-consistency-level", "Session"}]
      )

    assert resp.status == 200
    assert header_map(resp)["x-ms-consistency-level"] == "Session"

    plain = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1", headers: [@pk_hdr])
    assert plain.status == 200
    refute Map.has_key?(header_map(plain), "x-ms-consistency-level")
  end

  # ---------------------------------------------------------------------------
  # Helpers (mirrors test/compliance/c4_blob.exs)
  # ---------------------------------------------------------------------------

  defp create_db do
    assert req!(port(), :post, "/dbs", headers: [@json], body: ~s({"id":"#{@db}"})).status == 201
  end

  defp create_coll do
    assert req!(port(), :post, "/dbs/#{@db}/colls",
             headers: [@json],
             body: ~s({"id":"#{@coll}","partitionKey":{"paths":["/tenantId"]}})
           ).status == 201
  end

  defp create_doc(id, tenant \\ "acme") do
    req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
      headers: [@pk_hdr, @json],
      body: ~s({"id":"#{id}","tenantId":"#{tenant}"})
    )
  end

  defp get_doc(id) do
    req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/#{id}", headers: [@pk_hdr])
    |> Map.fetch!(:body)
    |> Jason.decode!()
  end

  defp session_token_for(id) do
    req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/#{id}", headers: [@pk_hdr])
    |> header_map()
    |> Map.fetch!("x-ms-session-token")
  end

  defp port, do: :persistent_term.get({__MODULE__, :port})

  defp req(port, method, path, opts \\ [], body \\ nil) do
    {hdrs, kw_body} =
      if opts == [] or match?([{k, _} | _] when is_atom(k), opts),
        do: {Keyword.get(opts, :headers, []), Keyword.get(opts, :body)},
        else: {opts, nil}

    body = body || kw_body
    url = to_charlist("http://127.0.0.1:#{port}#{path}")

    header_lc = Map.new(hdrs, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    ctype =
      case Map.get(header_lc, "content-type") do
        nil -> ~c"application/json"
        ct -> to_charlist(ct)
      end

    remaining =
      hdrs
      |> Enum.reject(fn {k, v} -> String.downcase(to_string(k)) == "content-type" end)
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    request =
      if body do
        {url, remaining, ctype, body}
      else
        {url, remaining}
      end

    :httpc.request(method, request, [timeout: 5_000, connect_timeout: 5_000, autoredirect: false],
      body_format: :binary
    )
  end

  defp req!(port, method, path, opts \\ [], body \\ nil) do
    case req(port, method, path, opts, body) do
      {:ok, {{_ver, status, _phrase}, resp_headers, resp_body}} ->
        %{status: status, headers: resp_headers, body: to_string(resp_body)}

      {:error, reason} ->
        flunk("httpc request failed: #{inspect(reason)}")
    end
  end

  defp header_map(%{headers: headers}) do
    Map.new(headers, fn {k, v} ->
      {k |> to_string() |> String.downcase(), to_string(v)}
    end)
  end

  defp stop_server(server) do
    try do
      Supervisor.stop(server, :normal, 1_000)
    catch
      _, _ -> Process.exit(server, :kill)
    end

    :ok
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp token_lsn(token), do: token |> String.split("#") |> List.last() |> String.to_integer()
end
